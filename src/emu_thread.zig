const std = @import("std");
const Cpu = @import("cpu.zig").Cpu;
const Memory = @import("memory.zig").Memory;
const Gpu = @import("gpu/gpu.zig").Gpu;
const GpuMsg = @import("render/message.zig").GpuMsg;
const BlockingStore = @import("blocking_store.zig").BlockingStore;

pub fn start(running: *std.atomic.Atomic(bool), gpu_tx: *BlockingStore(GpuMsg)) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status != .ok) {
            std.debug.print("gpa.deinit() failed: {}\n", .{deinit_status});
        }
    }
    const allocator = gpa.allocator();

    const gpu = Gpu.init(gpu_tx);

    var memory = try Memory.init(allocator, gpu);
    defer memory.deinit();

    var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const path = try std.fs.realpath("../../assets/scph1001.bin", &path_buf);
    try memory.loadBiosAbsolute(path);

    var cpu = Cpu.init(&memory);

    while (running.load(std.atomic.Ordering.SeqCst)) {
        try cpu.next();
    }
}
