pub const Direction = enum(u1) {
    ToRam = 0,
    FromRam = 1,
};

pub const Step = enum(u1) {
    Increment = 0,
    Decrement = 1,
};

pub const SyncMode = enum(u2) {
    Manual = 0,
    Request = 1,
    LinkedList = 2,
};

pub const Control = packed struct(u32) {
    /// ctr[0]
    direction: Direction,
    /// ctr[1]
    step: Step,
    /// ctr[2:7]
    _pad0: u6,
    /// ctr[8] choppy transfer, let cpu take over
    chop: bool,
    /// ctr[9:10]
    sync: SyncMode,
    /// ctr[11:15]
    _pad1: u5,
    /// ctr[16:18] DMA window size for choppy transfer
    chop_dma_sz: u3,
    /// ctr[19]
    _pad2: u1,
    /// ctr[20:22] CPU window size for choppy transfer
    chop_cpu_sz: u3,
    /// ctr[23]
    _pad3: u1,
    /// ctr[24]
    enable: bool,
    /// ctr[25:27]
    _pad4: u3,
    /// ctr[28] trigger transfer for manual sync
    trigger: bool,
    /// ctr[29:30] unknown rw bits
    dummy: u2,
    /// ctr[31]
    _pad5: u1,
    pub fn init() Control {
        return @bitCast(@as(u32, 0));
    }
    pub fn update(self: *Control, val: u32) void {
        self.* = @bitCast(val);
        self._pad0 = 0;
        self._pad1 = 0;
        self._pad2 = 0;
        self._pad3 = 0;
        self._pad4 = 0;
        self._pad5 = 0;
    }
};

pub const BlockControl = packed struct(u32) {
    /// ctr[0:15]
    block_size: u16,
    /// ctr[16:31]
    block_count: u16,
    pub fn init() BlockControl {
        return BlockControl{
            .block_size = 0,
            .block_count = 0,
        };
    }
};

pub const Channel = struct {
    /// Channel control register
    control: Control,
    /// Channel block control register
    block_control: BlockControl,
    /// Base address[0:23]
    base: u32,
    pub fn init() Channel {
        return Channel{ .control = Control.init(), .block_control = BlockControl.init(), .base = 0 };
    }
    /// Set the base address of the channel
    pub fn set_base(self: *Channel, base: u32) void {
        self.base = base & 0xffffff;
    }
    /// Check if channel is active
    pub fn active(self: *const Channel) bool {
        const trigger = if (self.control.sync == SyncMode.Manual) self.control.trigger else true;
        return trigger and self.control.enable;
    }
    /// transfer size of the channel
    pub fn transfer_size(self: *const Channel) ?u32 {
        return switch (self.control.sync) {
            SyncMode.Manual => self.block_control.block_size,
            SyncMode.Request => self.block_control.block_size * self.block_control.block_count,
            SyncMode.LinkedList => null,
        };
    }
    /// finish transfer
    pub fn finish(self: *Channel) void {
        self.control.enable = false;
        self.control.trigger = false;
        // TODO: set interrupts
    }
};
