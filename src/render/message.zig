const Vertex = @import("attrs.zig").Vertex;

/// Messages passed from PSX Gpu thread
pub const GpuMsg = union(enum) {
    triangle: [3]Vertex,
    quad: [4]Vertex,
    offset: @Vector(2, i32),
    draw,
};
