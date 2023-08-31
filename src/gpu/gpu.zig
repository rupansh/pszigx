const PsxError = @import("../error.zig").PsxError;
const std = @import("std");
const cmd = @import("cmd.zig");
const state = @import("state.zig");
const BlockingStore = @import("../blocking_store.zig").BlockingStore;
const Vertex = @import("../render/attrs.zig").Vertex;
const GpuMsg = @import("../render/message.zig").GpuMsg;

const CmdBuf = struct {
    buff: [12]u32,
    len: u8,
    fn init() CmdBuf {
        return CmdBuf{
            .buff = std.mem.zeroes([12]u32),
            .len = 0,
        };
    }
    fn clear(self: *CmdBuf) void {
        self.len = 0;
    }
    fn push(self: *CmdBuf, val: u32) void {
        self.buff[self.len] = val;
        self.len += 1;
    }
};

const CmdHandler = struct {
    len: u8,
    method: *const fn (*Gpu) void,
    fn init(arg_len: u8, method: *const fn (*Gpu) void) CmdHandler {
        return CmdHandler{
            .len = arg_len,
            .method = method,
        };
    }
};

const Gp0Mode = enum {
    Command,
    ImageLoad,
};

fn toVert(pos_raw: u32, cl_raw: u32) Vertex {
    const pos: cmd.Vertex = @bitCast(pos_raw);
    const cl: cmd.Color = @bitCast(cl_raw);
    return Vertex{ .pos = .{ @as(i32, pos.x), @as(i32, pos.y) }, .col = .{ @as(u32, cl.r), @as(u32, cl.g), @as(u32, cl.b) } };
}

pub const Gpu = struct {
    stat: state.GpuState,
    /// Texture window attributes
    tex_window: state.TexWindow,
    /// Draw Area
    draw_area: state.DrawArea,
    /// Display Start/End
    draw_attr: state.DisplayAttr,
    /// Textured rectangle x flip
    tex_rect_x_flip: bool,
    /// Textured rectangle y flip
    tex_rect_y_flip: bool,
    /// Command buffer for gp0
    gp0_cmd: CmdBuf,
    /// args remaining for gp0 cmd
    gp0_arg_remaining: u32,
    /// Method to call when gp0_cmd_remaining == 0
    gp0_cmd_method: *const fn (*Gpu) void,
    gp0_mode: Gp0Mode,
    gpu_tx: *BlockingStore(GpuMsg),
    pub fn init(gpu_tx: *BlockingStore(GpuMsg)) Gpu {
        return Gpu{
            .stat = state.GpuState.init(),
            .tex_window = state.TexWindow.init(),
            .draw_area = state.DrawArea.init(),
            .draw_attr = state.DisplayAttr.init(),
            .tex_rect_x_flip = false,
            .tex_rect_y_flip = false,
            .gp0_cmd = CmdBuf.init(),
            .gp0_arg_remaining = 0,
            .gp0_cmd_method = &Gpu.gp0Nop,
            .gp0_mode = Gp0Mode.Command,
            .gpu_tx = gpu_tx,
        };
    }
    pub fn read(self: *const Gpu) u32 {
        _ = self;
        std.debug.print("GPUREAD\n", .{});
        // dummy value
        return @as(u32, 0);
    }
    /// Unimplimented instruction
    fn unimplimented(instr: u32) PsxError {
        std.debug.print("GPU Unimplimented instr {x}\n", .{instr});
        return PsxError.Unimplimented;
    }
    fn gp0Nop(self: *Gpu) void {
        _ = self;
    }
    /// GP0(0xE1) - Draw Mode
    fn gp0DrawMode(self: *Gpu) void {
        const texpage = @as(cmd.Texpage, @bitCast(self.gp0_cmd.buff[0]));
        self.stat.page_base_x = texpage.base_x;
        self.stat.page_base_y = texpage.base_y;
        self.stat.semi_transparency = texpage.semi_transparency;
        self.stat.colors = texpage.colors;
        self.stat.dither = texpage.dither;
        self.stat.draw_to_display = texpage.draw_to_display;
        self.stat.texture_disable = texpage.texture_disable;
        self.tex_rect_x_flip = texpage.tex_rect_x_flip;
        self.tex_rect_y_flip = texpage.tex_rect_y_flip;
    }
    fn gp0DrawAreaXY(self: *Gpu, x: *u16, y: *u16) void {
        const val = self.gp0_cmd.buff[0];
        // too lazy to add packed struct for 2 fields :p
        x.* = @as(u16, @truncate((val >> 10) & 0x3FF));
        y.* = @as(u16, @truncate(val & 0x3FF));
    }
    /// GP0(0xE3) - Draw Area Top Left
    fn gp0DrawAreaTl(self: *Gpu) void {
        self.gp0DrawAreaXY(&self.draw_area.top, &self.draw_area.left);
    }
    /// GP0(0xE4) - Draw Area Bottom Right
    fn gp0DrawAreaBr(self: *Gpu) void {
        self.gp0DrawAreaXY(&self.draw_area.bottom, &self.draw_area.right);
    }
    /// GP0(0xE5) - Draw Offset
    fn gp0DrawingOffset(self: *Gpu) void {
        const val = self.gp0_cmd.buff[0];
        const x: u16 = @truncate(val & 0x7ff);
        const y: u16 = @truncate((val >> 11) & 0x7ff);

        self.draw_area.offset_x = @as(i16, @bitCast(x << 5)) >> 5;
        self.draw_area.offset_y = @as(i16, @bitCast(y << 5)) >> 5;
        self.gpu_tx.put(.{ .offset = .{ @as(i32, self.draw_area.offset_x), @as(i32, self.draw_area.offset_y) } });

        // HACK: Force draw
        self.gpu_tx.put(.draw);
    }
    /// GP0(0xE2) - Texture Window Setting
    fn gp0TexWindow(self: *Gpu) void {
        const val = self.gp0_cmd.buff[0];
        const tex_window = @as(cmd.TexWindowSet, @bitCast(val));
        self.tex_window.mask_x = tex_window.mask_x;
        self.tex_window.mask_y = tex_window.mask_y;
        self.tex_window.offset_x = tex_window.offset_x;
        self.tex_window.offset_y = tex_window.offset_y;
    }
    /// GP0(0xE6) - Mask Bit Setting
    fn gp0MaskBit(self: *Gpu) void {
        const val = self.gp0_cmd.buff[0];
        self.stat.force_mask = val & 1 != 0;
        self.stat.skip_masked = val & 2 != 0;
    }
    /// GP0(0x28) - Monochrome Opaque Quadrilateral
    fn gp0QuadMono(self: *Gpu) void {
        const arg_buf = &self.gp0_cmd.buff;
        self.gpu_tx.put(.{ .quad = [_]Vertex{
            toVert(arg_buf[1], arg_buf[0]),
            toVert(arg_buf[2], arg_buf[0]),
            toVert(arg_buf[3], arg_buf[0]),
            toVert(arg_buf[4], arg_buf[0]),
        } });
        std.debug.print("GP0(0x28) - Quad Mono Opaque\n", .{});
    }
    /// GP0(0x01) - Clear Tex Cache
    fn gp0ClearCache(self: *Gpu) void {
        _ = self;
    }
    /// GP0(0xA0) - Image Load
    fn gp0ImgLoad(self: *Gpu) void {
        const img_res = self.gp0_cmd.buff[2];
        const width = img_res & 0xffff;
        const height = img_res >> 16;
        var img_size = width * height;
        // round up odd pixels
        img_size = (img_size + 1) & ~@as(u32, 1);

        self.gp0_arg_remaining = img_size / 2;
        self.gp0_mode = Gp0Mode.ImageLoad;
    }
    /// GP0(0xC0) - Image Store
    fn gp0ImgStore(self: *Gpu) void {
        const img_res = self.gp0_cmd.buff[2];
        const width = img_res & 0xffff;
        const height = img_res >> 16;

        std.debug.print("GP0 unhandled img store {}x{}\n", .{ width, height });
    }
    /// GP0(0x38) - Shaded Opaque Quadrilateral
    fn gp0QuadShadedOpaque(self: *Gpu) void {
        const arg_buf = &self.gp0_cmd.buff;
        self.gpu_tx.put(.{ .quad = [_]Vertex{ toVert(arg_buf[1], arg_buf[0]), toVert(arg_buf[3], arg_buf[2]), toVert(arg_buf[5], arg_buf[4]), toVert(arg_buf[7], arg_buf[6]) } });
        std.debug.print("GP0(0x38) - Quad Shaded Opaque\n", .{});
    }
    /// GP0(0x30) - Shaded Opaque Triangle
    fn gp0TriShadedOpaque(self: *Gpu) void {
        const arg_buf = &self.gp0_cmd.buff;
        self.gpu_tx.put(.{ .triangle = [_]Vertex{
            toVert(arg_buf[1], arg_buf[0]),
            toVert(arg_buf[3], arg_buf[2]),
            toVert(arg_buf[5], arg_buf[4]),
        } });
        std.debug.print("GP0(0x30) - Shaded Opaque\n", .{});
    }
    /// GP0(0x2c) - Textured Opaque Quadrilateral
    fn gp0QuadTextOpaque(self: *Gpu) void {
        const arg_buf = &self.gp0_cmd.buff;
        // HACK: use solid color instead of a texture
        const color: u32 = @bitCast(cmd.Color{ .r = 0x80, .g = 0, .b = 0, .cmd = 0 });
        self.gpu_tx.put(.{ .quad = [_]Vertex{
            toVert(arg_buf[1], color),
            toVert(arg_buf[3], color),
            toVert(arg_buf[5], color),
            toVert(arg_buf[7], color),
        } });
        std.debug.print("GP0(0x2c) - Quad Textured Opaque\n", .{});
    }
    fn gp0Handler(self: *const Gpu, val: u32) !?CmdHandler {
        if (self.gp0_arg_remaining != 0) {
            return null;
        }

        const opcode = (val >> 24) & 0xFF;
        return switch (opcode) {
            0x00 => CmdHandler.init(1, &Gpu.gp0Nop),
            0x01 => CmdHandler.init(1, &Gpu.gp0ClearCache),
            0x28 => CmdHandler.init(5, &Gpu.gp0QuadMono),
            0x2c => CmdHandler.init(9, &Gpu.gp0QuadTextOpaque),
            0x38 => CmdHandler.init(8, &Gpu.gp0QuadShadedOpaque),
            0x30 => CmdHandler.init(6, &Gpu.gp0TriShadedOpaque),
            0xa0 => CmdHandler.init(3, &Gpu.gp0ImgLoad),
            0xc0 => CmdHandler.init(3, &Gpu.gp0ImgStore),
            0xe1 => CmdHandler.init(1, &Gpu.gp0DrawMode),
            0xe2 => CmdHandler.init(1, &Gpu.gp0TexWindow),
            0xe3 => CmdHandler.init(1, &Gpu.gp0DrawAreaTl),
            0xe4 => CmdHandler.init(1, &Gpu.gp0DrawAreaBr),
            0xe5 => CmdHandler.init(1, &Gpu.gp0DrawingOffset),
            0xe6 => CmdHandler.init(1, &Gpu.gp0MaskBit),
            else => return Gpu.unimplimented(val),
        };
    }
    pub fn gp0Exec(self: *Gpu, val: u32) !void {
        if (try self.gp0Handler(val)) |handler| {
            self.gp0_arg_remaining = handler.len;
            self.gp0_cmd_method = handler.method;
            self.gp0_cmd.clear();
        }

        self.gp0_arg_remaining -= 1;

        switch (self.gp0_mode) {
            Gp0Mode.Command => {
                self.gp0_cmd.push(val);
                if (self.gp0_arg_remaining == 0) {
                    self.gp0_cmd_method(self);
                }
            },
            Gp0Mode.ImageLoad => {
                // TODO: copy to vram
                if (self.gp0_arg_remaining == 0) {
                    self.gp0_mode = Gp0Mode.Command;
                }
            },
        }
    }
    /// GP1(0x00) - Reset
    fn gp1Reset(self: *Gpu) void {
        self.stat.update(0x14802000);
        self.tex_window.mask_x = 0;
        self.tex_window.mask_y = 0;
        self.tex_window.offset_x = 0;
        self.tex_window.offset_y = 0;
        self.tex_rect_x_flip = false;
        self.tex_rect_y_flip = false;
        self.draw_area.top = 0;
        self.draw_area.left = 0;
        self.draw_area.bottom = 0;
        self.draw_area.right = 0;
        self.draw_attr.vram_start_x = 0;
        self.draw_attr.vram_start_y = 0;
        self.draw_attr.horiz_start = 0x200;
        self.draw_attr.horiz_end = 0xc00;
        self.draw_attr.vert_start = 0x10;
        self.draw_attr.vert_end = 0x100;
        self.gp1ResetCmd();
        // TODO: clear GPU cache
    }
    /// GP1(0x08) - Display Mode
    fn gp1DisplayMode(self: *Gpu, val: u32) void {
        const display_mode = @as(cmd.DisplayMode, @bitCast(val));
        self.stat.hres = display_mode.hres;
        self.stat.setVres(display_mode.vres);
        self.stat.vmode = display_mode.vmode;
        self.stat.display_depth = display_mode.display_depth;
        self.stat.interlaced = display_mode.interlaced;
        self.stat.hres2 = display_mode.hres2;
        self.stat.reverse = display_mode.reverse;
    }
    /// GP1(0x04) - DMA Direction
    fn gp1DmaDir(self: *Gpu, val: u32) void {
        self.stat.setDmaDirection(@as(state.DMADirection, @enumFromInt(val & 0x3)));
    }
    /// GP1(0x05) - Display VRAM start
    fn gp1DispVramStart(self: *Gpu, val: u32) void {
        self.draw_attr.vram_start_x = @truncate(val & 0x3fe);
        self.draw_attr.vram_start_y = @truncate((val >> 10) & 0x1ff);
    }
    /// GP1(0x06) - Display Horizontal Start/End
    fn gp1DispHoriz(self: *Gpu, val: u32) void {
        self.draw_attr.horiz_start = @as(u12, @truncate(val & 0xfff));
        self.draw_attr.horiz_end = @as(u12, @truncate((val >> 12) & 0xfff));
    }
    /// GP1(0x07) - Display Vertical Start/End
    fn gp1DispVert(self: *Gpu, val: u32) void {
        self.draw_attr.vert_start = @as(u10, @truncate(val & 0x3ff));
        self.draw_attr.vert_end = @as(u10, @truncate((val >> 10) & 0x3ff));
    }
    /// GP1(0x03) - Display Enable/Disable
    fn gp1DispDisabled(self: *Gpu, val: u32) void {
        self.stat.display_disable = val & 1 != 0;
    }
    /// GP1(0x2) - Acknowledge Interrupt
    fn gp1AckIrq(self: *Gpu) void {
        self.stat.irq = false;
    }
    /// GP1(0x01) - Reset Command Buffer
    fn gp1ResetCmd(self: *Gpu) void {
        self.gp0_cmd.clear();
        self.gp0_arg_remaining = 0;
        self.gp0_mode = Gp0Mode.Command;
        // TODO: Clear FIFO
    }
    pub fn gp1_exec(self: *Gpu, val: u32) !void {
        const opcode = (val >> 24) & 0xFF;

        try switch (opcode) {
            0x0 => self.gp1Reset(),
            0x1 => self.gp1ResetCmd(),
            0x2 => self.gp1AckIrq(),
            0x3 => self.gp1DispDisabled(val),
            0x4 => self.gp1DmaDir(val),
            0x5 => self.gp1DispVramStart(val),
            0x6 => self.gp1DispHoriz(val),
            0x7 => self.gp1DispVert(val),
            0x8 => self.gp1DisplayMode(val),
            else => Gpu.unimplimented(val),
        };
    }
};
