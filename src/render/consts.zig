const gpu = @import("core").gpu;
const attrs = @import("attrs.zig");

const Vertex = attrs.Vertex;

const VERTEX_ATTR = [_]gpu.VertexAttribute{
    .{ .format = gpu.VertexFormat.sint32x2, .offset = @offsetOf(Vertex, "pos"), .shader_location = 0 },
    .{ .format = gpu.VertexFormat.uint32x4, .offset = @offsetOf(Vertex, "col"), .shader_location = 1 },
};

pub const VERTEX_BUF_LAYOUT = [_]gpu.VertexBufferLayout{.{ .array_stride = @sizeOf(Vertex), .attributes = &VERTEX_ATTR, .attribute_count = 2, .step_mode = .vertex }};

pub const BINDGROUP_LAYOUT_ENTRY = gpu.BindGroupLayout.Entry.buffer(0, .{ .vertex = true }, .uniform, true, 0);
