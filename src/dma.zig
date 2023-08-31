const std = @import("std");
const Channel = @import("channel.zig").Channel;

pub const Interrupt = packed struct(u32) {
    /// irq[0:5]
    irq_dummy: u6,
    _pad0: u9,
    /// irq[15]
    force_irq: bool,
    /// irq[16:22]
    channel_irq_enable: u7,
    /// irq[23]
    irq_enable: bool,
    /// irq[24:30]
    channel_irq_flags: u7,
    /// irq[31]
    irq_signal: bool,
    pub fn init() Interrupt {
        return @as(Interrupt, @bitCast(@as(u32, 0)));
    }
    /// Update the interrupt register
    pub fn update(self: *Interrupt, val: u32) void {
        var irq_flags = self.channel_irq_flags;
        const ack = @as(u7, @truncate((val >> 24) & 0x3f));
        irq_flags &= ~ack;

        self.* = @as(Interrupt, @bitCast(val));
        self._pad0 = 0;
        self.channel_irq_flags = irq_flags;

        const channel_irq = self.channel_irq_enable & self.channel_irq_flags;
        self.irq_signal = self.force_irq or (self.irq_enable and channel_irq != 0);
    }
};

/// DMA controller
pub const Dma = struct {
    /// Control register
    control: u32,
    /// Interrupt register
    interrupt: Interrupt,
    /// channels
    channels: [7]Channel,
    pub fn init() Dma {
        return Dma{ .control = 0x07654321, .interrupt = Interrupt.init(), .channels = [_]Channel{Channel.init()} ** 7 };
    }
    pub fn channel(self: *Dma, port: Port) *Channel {
        return &self.channels[@intFromEnum(port)];
    }
    pub fn channel_const(self: *const Dma, port: Port) *const Channel {
        return &self.channels[@intFromEnum(port)];
    }
};

pub const Port = enum(u8) {
    /// Macroblock decoder input
    MDecIn = 0,
    /// Macroblock decoder output
    MDecOut = 1,
    Gpu = 2,
    CdRom = 3,
    /// Sound
    Spu = 4,
    /// Extension ports
    Pio = 5,
    /// Ordering table clear
    Otc = 6,
};

// Test interrupt against a known implementation
test "interrupt" {
    const EasyInter = struct {
        /// irq[23]
        irq_enable: bool,
        /// irq[22:16]
        channel_irq_enable: u8,
        /// irq[24:30]
        channel_irq_flags: u8,
        /// irq[15]
        force_irq: bool,
        /// irq[0:5]
        irq_dummy: u8,
        fn irq(self: *const @This()) bool {
            const channel_irq = self.channel_irq_enable & self.channel_irq_flags;
            return self.force_irq or (self.irq_enable and channel_irq != 0);
        }
        pub fn interrupt(self: *const @This()) u32 {
            var res: u32 = 0;

            res |= @intCast(self.irq_dummy);
            res |= @as(u32, @intCast(@intFromBool(self.force_irq))) << 15;
            res |= @as(u32, @intCast(self.channel_irq_enable)) << 16;
            res |= @as(u32, @intCast(@intFromBool(self.irq_enable))) << 23;
            res |= @as(u32, @intCast(self.channel_irq_flags)) << 24;
            res |= @as(u32, @intCast(@intFromBool(self.irq()))) << 31;

            return res;
        }
        pub fn set_interrupt(self: *@This(), val: u32) void {
            self.irq_dummy = @as(u8, @truncate((val & 0x3f)));
            self.force_irq = (val >> 15) & 1 != 0;
            self.channel_irq_enable = @as(u8, @truncate((val >> 16) & 0x7f));
            self.irq_enable = (val >> 23) & 1 != 0;

            const ack = @as(u8, @truncate((val >> 24) & 0x3f));
            self.channel_irq_flags &= ~ack;
        }
    };

    var test_inter = EasyInter{
        .irq_enable = false,
        .channel_irq_enable = 0,
        .channel_irq_flags = 0,
        .force_irq = false,
        .irq_dummy = 0,
    };
    var inter = Interrupt.init();

    var irq: u32 = 0;
    test_inter.set_interrupt(irq);
    inter.update(irq);
    try std.testing.expectEqual(test_inter.interrupt(), @bitCast(inter));

    irq = 0x12345678;
    test_inter.set_interrupt(irq);
    inter.update(irq);
    try std.testing.expectEqual(test_inter.interrupt(), @bitCast(inter));

    irq = 0xFFFFFFFF;
    test_inter.set_interrupt(irq);
    inter.update(irq);
    try std.testing.expectEqual(test_inter.interrupt(), @bitCast(inter));
}
