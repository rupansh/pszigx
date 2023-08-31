pub const Mapping = struct {
    start: comptime_int,
    len: comptime_int,
    pub fn begin(comptime self: *const Mapping) comptime_int {
        return self.start;
    }
    pub fn end(comptime self: *const Mapping) comptime_int {
        return self.start + self.len - 1;
    }
    pub fn offset(comptime self: *const Mapping, addr: u32) u32 {
        return addr - self.start;
    }
};

pub const BIOS = Mapping{
    .start = 0x1fc00000,
    .len = 512 * 1024,
};

pub const RAM = Mapping{
    .start = 0x00000000,
    .len = 2048 * 1024,
};

pub const EXP1 = Mapping{
    .start = 0x1f000000,
    .len = 8 * 1024 * 1024,
};

pub const EXP2 = Mapping{
    .start = 0x1f802000,
    .len = 66,
};

pub const MEMC = Mapping{
    .start = 0x1f801000,
    .len = 36,
};

pub const CACHEC = Mapping{
    .start = 0xfffe0130,
    .len = 4,
};

pub const SPU = Mapping{
    .start = 0x1f801c00,
    .len = 640,
};

pub const RAM_SZ = Mapping{
    .start = 0x1f801060,
    .len = 4,
};

pub const IRQ_CNT = Mapping{
    .start = 0x1f801070,
    .len = 8,
};

pub const TIMERS = Mapping{
    .start = 0x1f801100,
    .len = 0x30,
};

pub const DMA = Mapping{
    .start = 0x1f801080,
    .len = 0x80,
};

pub const GPU = Mapping{
    .start = 0x1f801810,
    .len = 0x8,
};

pub const HW_REG_LEN = 8 * 1024;

pub const SCRATCH = Mapping{
    .start = 0x1f800000,
    .len = 0x1024,
};
