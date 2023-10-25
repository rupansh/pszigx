const Vertex = @import("attrs.zig").Vertex;
const core = @import("mach-core");
const gpu = core.gpu;
const std = @import("std");

const VERT_BUF_LEN = 64 * 1024;

pub const FrozenVertexBuf = struct {
    buf: *gpu.Buffer,
    nvertices: u32,
    pub fn size(self: *const FrozenVertexBuf) u64 {
        return self.nvertices * @sizeOf(Vertex);
    }
};

/// Mutable Vertex Buffer
pub const VertexBuf = struct {
    buf: *gpu.Buffer,
    vertex_buf: FrozenVertexBuf,
    nvertices: u32,
    pub fn init(device: *gpu.Device) VertexBuf {
        var self: VertexBuf = undefined;
        self.buf = device.createBuffer(&.{
            .size = VERT_BUF_LEN * @sizeOf(Vertex),
            .usage = .{ .map_write = true, .copy_src = true },
            .mapped_at_creation = .true,
        });
        self.nvertices = 0;

        const vertex_buf = device.createBuffer(&.{
            .size = VERT_BUF_LEN * @sizeOf(Vertex),
            .usage = .{ .copy_dst = true, .vertex = true },
            .mapped_at_creation = .false,
        });
        self.vertex_buf = .{
            .buf = vertex_buf,
            .nvertices = 0,
        };

        return self;
    }
    pub fn deinit(self: *VertexBuf) void {
        self.buf.release();
        self.vertex_buf.buf.release();
    }
    fn size(self: *const VertexBuf) u64 {
        return self.nvertices * @sizeOf(Vertex);
    }
    /// Push a triangle into the buffer
    pub fn pushTriangle(self: *VertexBuf, triangle: [3]Vertex) !void {
        if (self.nvertices + 3 >= VERT_BUF_LEN) {
            std.debug.print("WARN: VertexBuf out of memory, clearing", .{});
            self.nvertices = 0;
        }
        @memcpy(self.buf.getMappedRange(Vertex, self.size(), 3).?, &triangle);
        self.nvertices += 3;
    }
    /// Push a quadrilateral to the buffer
    pub fn pushQuad(self: *VertexBuf, quad: [4]Vertex) !void {
        if (self.nvertices + 6 >= VERT_BUF_LEN) {
            std.debug.print("WARN: VertexBuf out of memory, clearing", .{});
            self.nvertices = 0;
        }
        @memcpy(self.buf.getMappedRange(Vertex, self.size(), 3).?, quad[0..3]);
        self.nvertices += 3;
        @memcpy(self.buf.getMappedRange(Vertex, self.size(), 3).?, quad[1..4]);
        self.nvertices += 3;
    }
    /// Copy current contents into a vertex buffer
    pub fn freeze(self: *VertexBuf, encoder: *gpu.CommandEncoder) FrozenVertexBuf {
        // reuse old buffer if not updated
        if (self.nvertices == 0) {
            return self.vertex_buf;
        }
        self.buf.unmap();
        encoder.copyBufferToBuffer(self.buf, 0, self.vertex_buf.buf, 0, self.size());
        self.vertex_buf.nvertices = self.nvertices;
        self.nvertices = 0;

        return self.vertex_buf;
    }
    /// Remap the vertex buffer
    /// must be called everytime after freezing!
    pub fn remapBlocking(self: *VertexBuf) !void {
        if (self.buf.getMapState() == .mapped) {
            return;
        }
        var response: gpu.Buffer.MapAsyncStatus = undefined;
        const callback = (struct {
            pub inline fn callback(ctx: *gpu.Buffer.MapAsyncStatus, status: gpu.Buffer.MapAsyncStatus) void {
                ctx.* = status;
            }
        }).callback;
        self.buf.mapAsync(.{ .write = true }, 0, VERT_BUF_LEN, &response, callback);
        while (response != gpu.Buffer.MapAsyncStatus.success) {
            core.device.tick();
        }
    }
};
