const state = @import("state.zig");

pub const Vertex = packed struct(u32) {
    // [0:10]
    x: i11,
    _pad0: u5,
    // [16:26]
    y: i11,
    _pad1: u5,
};

pub const Color = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    cmd: u8,
};

pub const Texpage = packed struct(u32) {
    /// page[0:3] Texture Page X Co-ord (64 byte units)
    base_x: u4,
    /// page[4] Texture Page Y Co-ord (256 line units)
    base_y: u1,
    /// page[5:6] Semi-transparency
    semi_transparency: u2,
    /// page[7:8] Texture Page Colors
    colors: state.TexDepth,
    /// page[9] Dithering
    dither: bool,
    /// page[10] allow drawing to display area
    draw_to_display: bool,
    /// page[11] texture disable
    texture_disable: bool,
    /// page[12] horizontal flip
    tex_rect_x_flip: bool,
    /// page[13] vertical flip
    tex_rect_y_flip: bool,
    /// page[14:23]
    _pad0: u10,
    /// page[24:31] command
    command: u8,
};

pub const DisplayMode = packed struct(u32) {
    /// mode[0:1] horizontal resolution
    hres: state.HorizontalRes,
    /// mode[2] vertical resolution
    vres: state.VerticalRes,
    /// mode[3] video mode
    vmode: state.VideoMode,
    /// mode[4] display color depth
    display_depth: state.DisplayDepth,
    /// mode[5] vertocal interlace
    interlaced: bool,
    /// mode[6] horizontal resolution 2
    hres2: state.HorizontalRes2,
    /// mode[7] reverse flag
    reverse: bool,
    _pad0: u24,
};

pub const TexWindowSet = packed struct(u32) {
    /// set[0:4] Texture Window X Mask
    mask_x: u5,
    /// set[5:9] Texture Window Y Mask
    mask_y: u5,
    /// set[10:14] Texture Window X Offset
    offset_x: u5,
    /// set[15:19] Texture Window Y Offset
    offset_y: u5,
    _pad0: u4,
    /// set[21:31] command
    cmd: u8,
};
