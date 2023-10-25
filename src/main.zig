const std = @import("std");
const core = @import("mach-core");
const gpu = core.gpu;
const emu_thread = @import("emu_thread.zig");
const BlockingStore = @import("blocking_store.zig").BlockingStore;
const consts = @import("render/consts.zig");
const VertexBuf = @import("render/vertex_buf.zig").VertexBuf;
const GpuMsg = @import("render/message.zig").GpuMsg;

pub const App = @This();

triangle_pipeline: *gpu.RenderPipeline,
vertex_buf: VertexBuf,
offset_buf: *gpu.Buffer,
next_offset: ?@Vector(2, i32),
bind_group: *gpu.BindGroup,
gpu_rx: BlockingStore(GpuMsg),
ps_thread: std.Thread,
ps_thread_running: std.atomic.Atomic(bool),

pub fn init(app: *App) !void {
    try core.init(.{ .size = .{ .width = 1024, .height = 512 } });

    const shader_module = core.device.createShaderModuleWGSL("triangle.wgsl", @embedFile("shaders/triangle.wgsl"));
    defer shader_module.release();

    // Fragment state
    const blend = gpu.BlendState{};
    const color_target = gpu.ColorTargetState{
        .format = core.descriptor.format,
        .blend = &blend,
        .write_mask = gpu.ColorWriteMaskFlags.all,
    };
    const fragment = gpu.FragmentState.init(.{
        .module = shader_module,
        .entry_point = "frag_main",
        .targets = &.{color_target},
    });

    const bg0 = core.device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor.init(.{ .entries = &.{consts.BINDGROUP_LAYOUT_ENTRY} }));
    const pipeline_layout = core.device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
        .bind_group_layouts = &.{bg0},
    }));

    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .fragment = &fragment,
        .layout = pipeline_layout,
        .vertex = gpu.VertexState.init(.{ .module = shader_module, .entry_point = "vertex_main", .buffers = &consts.VERTEX_BUF_LAYOUT }),
    };
    app.triangle_pipeline = core.device.createRenderPipeline(&pipeline_descriptor);

    app.vertex_buf = VertexBuf.init(core.device);

    app.offset_buf = core.device.createBuffer(&.{
        .usage = .{ .copy_dst = true, .uniform = true },
        .size = @sizeOf(@Vector(2, i32)),
        .mapped_at_creation = .false,
    });
    app.bind_group = core.device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{ .layout = bg0, .entries = &.{gpu.BindGroup.Entry.buffer(0, app.offset_buf, 0, @sizeOf(@Vector(2, i32)))} }));

    // blocking channel
    app.gpu_rx = .{};
    app.ps_thread_running = std.atomic.Atomic(bool).init(true);
    app.ps_thread = try std.Thread.spawn(.{}, emu_thread.start, .{ &app.ps_thread_running, &app.gpu_rx });
}

pub fn deinit(app: *App) void {
    defer core.deinit();
    app.vertex_buf.deinit();
    app.offset_buf.release();
    app.bind_group.release();

    app.ps_thread_running.store(false, std.atomic.Ordering.SeqCst);
    // clear if gpu sent a message in previous cycle
    _ = app.gpu_rx.consumeOrNull();
    app.ps_thread.join();
}

pub fn update(app: *App) !bool {
    var iter = core.pollEvents();
    while (iter.next()) |event| {
        switch (event) {
            .close => return true,
            else => {},
        }
    }

    const msg = if (app.gpu_rx.consumeOrNull()) |m| m else return false;
    var offset: ?@Vector(2, i32) = null;
    switch (msg) {
        .triangle => |triangle| {
            try app.vertex_buf.pushTriangle(triangle);
            return false;
        },
        .quad => |quad| {
            try app.vertex_buf.pushQuad(quad);
            return false;
        },
        // we're forced to redraw previous offset :(
        .offset => |off| offset = off,
        .draw => {},
    }

    const queue = core.queue;
    const back_buffer_view = core.swap_chain.getCurrentTextureView().?;
    const color_attachment = gpu.RenderPassColorAttachment{
        .view = back_buffer_view,
        .clear_value = std.mem.zeroes(gpu.Color),
        .load_op = .clear,
        .store_op = .store,
    };

    const encoder = core.device.createCommandEncoder(null);
    const render_pass_info = gpu.RenderPassDescriptor.init(.{
        .color_attachments = &.{color_attachment},
    });

    const vertex_buf = app.vertex_buf.freeze(encoder);
    if (app.next_offset) |off| {
        encoder.writeBuffer(app.offset_buf, 0, &[_]@Vector(2, i32){off});
        app.next_offset = null;
    }
    if (offset) |off| app.next_offset = off;

    const pass = encoder.beginRenderPass(&render_pass_info);
    pass.setPipeline(app.triangle_pipeline);
    pass.setVertexBuffer(0, vertex_buf.buf, 0, vertex_buf.size());
    pass.setBindGroup(0, app.bind_group, &.{0});
    pass.draw(vertex_buf.nvertices, 1, 0, 0);
    pass.end();
    pass.release();

    var command = encoder.finish(null);
    encoder.release();

    queue.submit(&[_]*gpu.CommandBuffer{command});
    command.release();
    core.swap_chain.present();
    back_buffer_view.release();

    try app.vertex_buf.remapBlocking();

    return false;
}
