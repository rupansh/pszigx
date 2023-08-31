/// Color depth of texture
pub const TexDepth = enum(u2) {
    T4Bit = 0,
    T8Bit = 1,
    T15Bit = 2,
};

/// Interlaced frame field
const Field = enum(u1) {
    Top = 1,
    Bottom = 0,
};

pub const HorizontalRes2 = enum(u1) {
    R368 = 1,
    /// 256/320/512/640
    Other = 0,
};

pub const HorizontalRes = enum(u2) {
    R256 = 0,
    R320 = 1,
    R512 = 2,
    R640 = 3,
};

pub const VerticalRes = enum(u1) {
    R240 = 0,
    /// stat[22] = 1
    R480 = 1,
};

pub const VideoMode = enum(u1) {
    NTSC = 0,
    PAL = 1,
};

pub const DisplayDepth = enum(u1) {
    D15Bit = 0,
    D24Bit = 1,
};

pub const DMADirection = enum(u2) {
    Off = 0,
    Fifo = 1,
    CPUToGP0 = 2,
    VRAMToCPU = 3,
};

pub const GpuState = packed struct(u32) {
    /// stat[0:3] Texture Page X Co-ord (64 byte units)
    page_base_x: u4,
    /// stat[4] Texture Page Y Co-ord (256 line units)
    page_base_y: u1,
    /// stat[5:6] Semi-transparency
    semi_transparency: u2,
    /// stat[7:8] Texture Page Colors
    colors: TexDepth,
    /// stat[9] Dithering
    dither: bool,
    /// stat[10] allow drawing to display area
    draw_to_display: bool,
    /// stat[11] force mask bit when writing to VRAM
    force_mask: bool,
    /// stat[12] bit=1 -> skip masked pixels
    skip_masked: bool,
    /// stat[13] current field
    field: Field,
    /// stat[14] reverse flag
    reverse: bool,
    /// stat[15] texture disable
    texture_disable: bool,
    /// stat[16] horizontal res 2
    hres2: HorizontalRes2,
    /// stat[17:18] horizontal res
    hres: HorizontalRes,
    /// stat[19] vertical res
    vres: VerticalRes,
    /// stat[20] video mode
    vmode: VideoMode,
    /// stat[21] display depth
    display_depth: DisplayDepth,
    /// stat[22]
    interlaced: bool,
    /// stat[23] Disable the display
    display_disable: bool,
    /// stat[24]
    irq: bool,
    /// stat[25] DMA request
    dma_request: bool,
    /// stat[26] Ready to receive Cmd Word
    cmd_ready: bool,
    /// stat[27] Ready to send VRAM to CPU
    vram_ready: bool,
    /// stat[28] Ready to receive DMA
    dma_ready: bool,
    /// stat[29:30] DMA direction
    dma_direction: DMADirection,
    /// stat[31] line status, 0=Even/VBlank, 1=Odd
    line_status: bool,
    pub fn init() GpuState {
        return GpuState{
            .page_base_x = 0,
            .page_base_y = 0,
            .semi_transparency = 0,
            .colors = TexDepth.T4Bit,
            .dither = false,
            .draw_to_display = false,
            .force_mask = false,
            .skip_masked = false,
            .field = Field.Top,
            .reverse = false,
            .texture_disable = false,
            .hres2 = HorizontalRes2.Other,
            .hres = HorizontalRes.R256,
            .vres = VerticalRes.R240,
            .vmode = VideoMode.NTSC,
            .display_depth = DisplayDepth.D15Bit,
            .interlaced = false,
            .display_disable = true,
            .irq = false,
            .dma_request = false,
            .cmd_ready = true,
            .vram_ready = true,
            .dma_ready = true,
            .dma_direction = DMADirection.Off,
            .line_status = false,
        };
    }
    pub fn setDmaDirection(self: *GpuState, direction: DMADirection) void {
        self.dma_direction = direction;
        self.dma_request = switch (direction) {
            DMADirection.Off => false,
            DMADirection.Fifo => true,
            DMADirection.CPUToGP0 => self.dma_ready,
            DMADirection.VRAMToCPU => self.vram_ready,
        };
    }
    pub fn setVres(self: *GpuState, val: VerticalRes) void {
        _ = val;
        // TODO: proper impl
        self.vres = VerticalRes.R240;
    }
    pub fn update(self: *GpuState, val: u32) void {
        self.* = @bitCast(val);
        self.vres = VerticalRes.R240;
        self.cmd_ready = true;
        self.vram_ready = true;
        self.dma_ready = true;
    }
};

pub const TexWindow = struct {
    /// Texture Window Mask X (8 pixel units)
    mask_x: u5,
    /// Texture Window Mask Y (8 pixel units)
    mask_y: u5,
    /// Texture Window Offset X (8 pixel units)
    offset_x: u5,
    /// Texture Window Offset Y (8 pixel units)
    offset_y: u5,
    pub fn init() TexWindow {
        return TexWindow{
            .mask_x = 0,
            .mask_y = 0,
            .offset_x = 0,
            .offset_y = 0,
        };
    }
};

pub const DrawArea = struct {
    /// Left most column of drawing area
    left: u16,
    top: u16,
    right: u16,
    bottom: u16,
    /// Horizontal drawing offset
    offset_x: i16,
    offset_y: i16,
    pub fn init() DrawArea {
        return DrawArea{
            .left = 0,
            .top = 0,
            .right = 0,
            .bottom = 0,
            .offset_x = 0,
            .offset_y = 0,
        };
    }
};

pub const DisplayAttr = struct {
    /// First column of display area in VRAM
    vram_start_x: u10,
    /// First row of display area in VRAM
    vram_start_y: u9,
    horiz_start: u12,
    horiz_end: u12,
    vert_start: u10,
    vert_end: u10,
    pub fn init() DisplayAttr {
        return DisplayAttr{
            .vram_start_x = 0,
            .vram_start_y = 0,
            .horiz_start = 0,
            .horiz_end = 0,
            .vert_start = 0,
            .vert_end = 0,
        };
    }
};
