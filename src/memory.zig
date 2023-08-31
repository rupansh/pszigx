const std = @import("std");
const maps = @import("maps.zig");
const PsxError = @import("error.zig").PsxError;
const dmaIm = @import("dma.zig");
const Dma = dmaIm.Dma;
const chan = @import("channel.zig");
const Gpu = @import("gpu/gpu.zig").Gpu;

const REGION_MASK = [8]u32{
    // KUSEG: 2048MB
    0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff,
    // KSEG0 : 512MB
    0x7fffffff,
    // KSEG1 : 512MB
    0x1fffffff,
    // KSEG2 : 1024MB
    0xffffffff, 0xffffffff,
};

fn translateAddr(addr: u32) u32 {
    const region = addr >> 29;
    return addr & REGION_MASK[region];
}

fn parseDmaOffset(offset: u32) struct { major: u32, minor: u32 } {
    const major = (offset & 0x70) >> 4;
    const minor = offset & 0xf;

    return .{ .major = major, .minor = minor };
}

fn sliceToU32(slice: []const u8) u32 {
    const b0 = @as(u32, @intCast(slice[0]));
    const b1 = @as(u32, @intCast(slice[1]));
    const b2 = @as(u32, @intCast(slice[2]));
    const b3 = @as(u32, @intCast(slice[3]));
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
}

fn sliceToU16(slice: []const u8) u16 {
    const b0 = @as(u16, @intCast(slice[0]));
    const b1 = @as(u16, @intCast(slice[1]));
    return b0 | (b1 << 8);
}

fn u32ToSlice(val: u32, slice: []u8) void {
    slice[0] = @as(u8, @truncate(val));
    slice[1] = @as(u8, @truncate(val >> 8));
    slice[2] = @as(u8, @truncate(val >> 16));
    slice[3] = @as(u8, @truncate(val >> 24));
}

fn u16ToSlice(val: u16, slice: []u8) void {
    slice[0] = @as(u8, @truncate(val));
    slice[1] = @as(u8, @truncate(val >> 8));
}

/// Iterator over a linked list of DMA headers
const LinkedListHeaderIter = struct {
    addr: u32,
    ram: []const u8,
    done: bool,
    fn init(init_addr: u32, ram: []const u8) LinkedListHeaderIter {
        return LinkedListHeaderIter{
            .addr = init_addr,
            .ram = ram,
            .done = false,
        };
    }
    fn next(self: *LinkedListHeaderIter) ?struct { addr: u32, transfer_sz: u32 } {
        if (self.done) {
            return null;
        }
        const prev_addr = self.addr;
        const header = sliceToU32(self.ram[prev_addr .. prev_addr + 4]);
        const transfer_sz = header >> 24;

        if (header & 0x800000 != 0) {
            self.done = true;
        }
        self.addr = header & 0x1ffffc;

        return .{ .addr = prev_addr, .transfer_sz = transfer_sz };
    }
};

pub const Memory = struct {
    ram: []u8,
    exp_1: []u8,
    scratch: []u8,
    dma: Dma,
    gpu: Gpu,
    bios: []u8,
    io: []u8,
    arena: std.heap.ArenaAllocator = undefined,
    /// Initialize the PSX memory mapping
    /// note that Bios must be loaded manually
    pub fn init(inner_alloc: std.mem.Allocator, gpu: Gpu) !Memory {
        var arena = std.heap.ArenaAllocator.init(inner_alloc);
        const allocator = arena.allocator();
        const ram = try allocator.alloc(u8, maps.RAM.len);
        const exp_1 = try allocator.alloc(u8, maps.EXP1.len);
        const scratch = try allocator.alloc(u8, maps.SCRATCH.len);
        const bios = try allocator.alloc(u8, maps.BIOS.len);
        const io = try allocator.alloc(u8, 512);

        return Memory{
            .ram = ram,
            .exp_1 = exp_1,
            .scratch = scratch,
            .dma = Dma.init(),
            .gpu = gpu,
            .bios = bios,
            .io = io,
            .arena = arena,
        };
    }
    /// Load 4 bytes from bios at offset
    fn load32LEBios(self: *const Memory, offset: u32) u32 {
        return sliceToU32(self.bios[offset .. offset + 4]);
    }
    /// Load 4 bytes from ram at offset
    fn load32LERam(self: *const Memory, offset: u32) u32 {
        return sliceToU32(self.ram[offset .. offset + 4]);
    }
    fn load16LERam(self: *const Memory, offset: u32) u16 {
        return sliceToU16(self.ram[offset .. offset + 2]);
    }
    fn load32LEGpu(self: *const Memory, offset: u32) !u32 {
        return switch (offset) {
            0 => self.gpu.read(),
            4 => @as(u32, @bitCast(self.gpu.stat)),
            else => PsxError.OutOfRange,
        };
    }
    fn loadDma(self: *const Memory, offset: u32) !u32 {
        const parsed = parseDmaOffset(offset);

        return switch (parsed.major) {
            0x7 => switch (parsed.minor) {
                0 => self.dma.control,
                4 => @as(u32, @bitCast(self.dma.interrupt)),
                else => PsxError.OutOfRange,
            },
            0...0x6 => {
                const channel = self.dma.channel_const(@as(dmaIm.Port, @enumFromInt(parsed.major)));
                return switch (parsed.minor) {
                    0 => channel.base,
                    4 => @as(u32, @bitCast(channel.block_control)),
                    8 => @as(u32, @bitCast(channel.control)),
                    else => PsxError.OutOfRange,
                };
            },
            else => PsxError.OutOfRange,
        };
    }
    /// Store 4 bytes to ram at offset
    fn store32LERam(self: *Memory, offset: u32, val: u32) void {
        u32ToSlice(val, self.ram[offset .. offset + 4]);
    }
    /// store 2 bytes to ram at offset
    fn store16LERam(self: *Memory, offset: u32, val: u16) void {
        u16ToSlice(val, self.ram[offset .. offset + 2]);
    }
    /// DMA Transfer
    fn storeDma(self: *Memory, offset: u32, val: u32) !void {
        const parsed = parseDmaOffset(offset);
        var active_port: ?dmaIm.Port = null;

        try switch (parsed.major) {
            0x7 => switch (parsed.minor) {
                0 => self.dma.control = val,
                4 => self.dma.interrupt.update(val),
                else => PsxError.OutOfRange,
            },
            0...0x6 => {
                const port: dmaIm.Port = @enumFromInt(parsed.major);
                const channel = self.dma.channel(port);
                try switch (parsed.minor) {
                    0 => channel.set_base(val),
                    4 => channel.block_control = @bitCast(val),
                    8 => channel.control.update(val),
                    else => PsxError.OutOfRange,
                };
                if (channel.active()) {
                    active_port = port;
                }
            },
            else => {
                std.debug.print("DMA unhandled store {x}\n", .{offset});
                return PsxError.OutOfRange;
            },
        };

        if (active_port) |port| {
            try self.performDma(port);
        }
    }
    /// Perform a DMA transfer on the given port
    fn performDma(self: *Memory, port: dmaIm.Port) !void {
        try switch (self.dma.channel_const(port).control.sync) {
            chan.SyncMode.LinkedList => self.performDmaLinkedList(port),
            else => self.performDmaBlock(port),
        };
    }
    /// Perform DMA transfer in Linked List mode
    fn performDmaLinkedList(self: *Memory, port: dmaIm.Port) !void {
        const channel = self.dma.channel(port);
        defer channel.finish();

        const init_addr = channel.base & 0x1ffffc;

        std.debug.assert(channel.control.direction == chan.Direction.FromRam);
        std.debug.assert(port == dmaIm.Port.Gpu);

        var headers = LinkedListHeaderIter.init(init_addr, self.ram);
        while (headers.next()) |header| {
            var transfer_sz = header.transfer_sz;
            var addr = header.addr;
            while (transfer_sz > 0) : (transfer_sz -= 1) {
                addr = (addr + 4) & 0x1ffffc;
                const cmd = self.load32LERam(addr);
                try self.gpu.gp0Exec(cmd);
            }
        }
    }
    /// Perform DMA transfer in block mode
    fn performDmaBlock(self: *Memory, port: dmaIm.Port) !void {
        const channel = self.dma.channel(port);
        defer channel.finish();

        const increment: u32 = if (channel.control.step == chan.Step.Increment)
            4
        else
            @bitCast(@as(i32, -4));

        var addr = channel.base;
        var transfer_sz = channel.transfer_size().?;

        while (transfer_sz > 0) : ({
            transfer_sz -= 1;
            addr +%= increment;
        }) {
            const cur_addr = addr & 0x1ffffc;
            try switch (channel.control.direction) {
                chan.Direction.FromRam => self.stepDmaFromRam(port, cur_addr),
                chan.Direction.ToRam => self.stepDmaToRam(port, transfer_sz, addr, cur_addr),
            };
        }
    }
    fn stepDmaFromRam(self: *Memory, port: dmaIm.Port, cur_addr: u32) !void {
        const src = self.load32LERam(cur_addr);
        try switch (port) {
            dmaIm.Port.Gpu => self.gpu.gp0Exec(src),
            else => PsxError.Unimplimented,
        };
    }
    fn stepDmaToRam(self: *Memory, port: dmaIm.Port, transfer_sz: u32, addr: u32, cur_addr: u32) !void {
        const src = try switch (port) {
            dmaIm.Port.Otc => if (transfer_sz == 1) 0xffffff else (addr -% 4) & 0x1fffff,
            else => PsxError.Unimplimented,
        };
        self.store32LERam(cur_addr, src);
    }
    /// Load 4 bytes from mapped memory at address
    pub fn load32(self: *const Memory, vaddr: u32) !u32 {
        const addr = translateAddr(vaddr);
        return switch (addr) {
            maps.BIOS.begin()...maps.BIOS.end() => self.load32LEBios(maps.BIOS.offset(addr)),
            maps.RAM.begin()...maps.RAM.end() => self.load32LERam(maps.RAM.offset(addr)),
            maps.IRQ_CNT.begin()...maps.IRQ_CNT.end() => {
                std.debug.print("IRQ CNT R {x}\n", .{addr});
                return 0;
            },
            maps.DMA.begin()...maps.DMA.end() => self.loadDma(maps.DMA.offset(addr)),
            maps.GPU.begin()...maps.GPU.end() => {
                return self.load32LEGpu(maps.GPU.offset(addr));
            },
            maps.TIMERS.begin()...maps.TIMERS.end() => {
                std.debug.print("TIMERS R {x}\n", .{addr});
                return 0;
            },
            else => {
                std.debug.print("unhandled load {x}\n", .{addr});
                return PsxError.OutOfRange;
            },
        };
    }
    /// Load a byte from
    pub fn load8(self: *const Memory, vaddr: u32) !u8 {
        const addr = translateAddr(vaddr);
        return switch (addr) {
            maps.BIOS.begin()...maps.BIOS.end() => self.bios[maps.BIOS.offset(addr)],
            maps.EXP1.begin()...maps.EXP1.end() => 0xff,
            maps.RAM.begin()...maps.RAM.end() => self.ram[maps.RAM.offset(addr)],
            else => {
                std.debug.print("unhandled load8 {x}\n", .{addr});
                return PsxError.OutOfRange;
            },
        };
    }
    pub fn load16(self: *const Memory, vaddr: u32) !u16 {
        const addr = translateAddr(vaddr);
        return switch (addr) {
            maps.SPU.begin()...maps.SPU.end() => 0,
            maps.RAM.begin()...maps.RAM.end() => self.load16LERam(maps.RAM.offset(addr)),
            maps.IRQ_CNT.begin()...maps.IRQ_CNT.end() => {
                std.debug.print("IRQ CNT R {x}\n", .{addr});
                return 0;
            },
            else => {
                std.debug.print("unhandled load16 {x}\n", .{addr});
                return PsxError.OutOfRange;
            },
        };
    }
    pub fn store32(self: *Memory, vaddr: u32, val: u32) !void {
        const addr = translateAddr(vaddr);
        try switch (addr) {
            // Mem control
            maps.MEMC.begin()...maps.MEMC.end() => {},
            // Ram Size
            maps.RAM_SZ.begin()...maps.RAM_SZ.end() => {},
            // Cache control
            maps.CACHEC.begin()...maps.CACHEC.end() => {
                std.debug.print("Cache control {x}\n", .{val});
            },
            maps.RAM.begin()...maps.RAM.end() => self.store32LERam(maps.RAM.offset(addr), val),
            maps.IRQ_CNT.begin()...maps.IRQ_CNT.end() => {
                std.debug.print("IRQ CNT {x}\n", .{val});
                return;
            },
            maps.DMA.begin()...maps.DMA.end() => self.storeDma(maps.DMA.offset(addr), val),
            maps.GPU.begin()...maps.GPU.end() => switch (maps.GPU.offset(addr)) {
                0 => self.gpu.gp0Exec(val),
                4 => self.gpu.gp1_exec(val),
                else => PsxError.Unimplimented,
            },
            maps.TIMERS.begin()...maps.TIMERS.end() => {
                std.debug.print("TIMERS W {x}\n", .{val});
                return;
            },
            else => {
                std.debug.print("unhandled store {x} va {x}\n", .{ addr, vaddr });
                return PsxError.OutOfRange;
            },
        };
    }
    pub fn store16(self: *Memory, vaddr: u32, val: u16) !void {
        const addr = translateAddr(vaddr);
        return switch (addr) {
            maps.SPU.begin()...maps.SPU.end() => {},
            maps.TIMERS.begin()...maps.TIMERS.end() => {
                std.debug.print("TIMERS W {x}\n", .{val});
                return;
            },
            maps.RAM.begin()...maps.RAM.end() => self.store16LERam(maps.RAM.offset(addr), val),
            maps.IRQ_CNT.begin()...maps.IRQ_CNT.end() => {
                std.debug.print("IRQ CNT W {x}\n", .{val});
                return;
            },
            else => {
                std.debug.print("unhandled store16 {x} va {x}\n", .{ addr, vaddr });
                return PsxError.OutOfRange;
            },
        };
    }
    pub fn store8(self: *Memory, vaddr: u32, val: u8) !void {
        const addr = translateAddr(vaddr);
        return switch (addr) {
            // exp_2
            maps.EXP2.begin()...maps.EXP2.end() => {},
            maps.RAM.begin()...maps.RAM.end() => self.ram[maps.RAM.offset(addr)] = val,
            else => {
                std.debug.print("unhandled store8 {x}\n", .{addr});
                return PsxError.OutOfRange;
            },
        };
    }
    /// Load a bios file into memory
    /// the `path` passed must be an absolute path
    pub fn loadBiosAbsolute(self: *Memory, path: []const u8) !void {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        const stat = try file.stat();
        if (stat.size != self.bios.len) {
            return PsxError.InvalidBios;
        }

        _ = try file.readAll(self.bios);
    }
    /// Deinitialize the memory mapping
    pub fn deinit(self: *Memory) void {
        self.arena.deinit();
    }
};
