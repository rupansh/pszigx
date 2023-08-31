struct VertIn {
    @location(0) pos: vec2<i32>,
    @location(1) color: vec3<u32>,
};

@group(0) @binding(0)
var<uniform> offset: vec2<i32>;

struct VertOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) color: vec3<f32>,
}

@vertex fn vertex_main(vert: VertIn) -> VertOut {
    let pos = vert.pos - offset;

    var out: VertOut;

    // vram to gsl co-ordinates
    let xpos = (f32(pos.x) / 512.0) - 1.0;
    let ypos = 1.0 - (f32(pos.y) / 256.0);

    out.pos = vec4f(xpos, ypos, 0.0, 1.0);
    out.color = vec3f(
        f32(vert.color.r) / 255,
        f32(vert.color.g) / 255,
        f32(vert.color.b) / 255,
    );

    return out;
}

@fragment fn frag_main(@location(0) color: vec3f) -> @location(0) vec4f {
    return vec4f(color, 1.0);
}