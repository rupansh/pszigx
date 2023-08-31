const std = @import("std");
const Memory = @import("memory.zig").Memory;
const PsxError = @import("error.zig").PsxError;
const PsxExcept = @import("except.zig").PsxExcept;

/// Instruction helpers
const Instruction = struct {
    /// raw opcode
    opcode: u32,
    /// Function of the opcode[31:26]
    fn func(self: Instruction) u32 {
        return self.opcode >> 26;
    }
    /// Coprocessor opcode [25:21]
    fn copCode(self: Instruction) u32 {
        return self.rs();
    }
    /// Secondary function of opcode[5:0]
    fn sec(self: Instruction) u32 {
        return (self.opcode >> 0) & 0x3f;
    }
    /// register idx [15:11]
    fn rd(self: Instruction) u32 {
        return (self.opcode >> 11) & 0x1f;
    }
    /// register idx [20:16]
    fn rt(self: Instruction) u32 {
        return (self.opcode >> 16) & 0x1f;
    }
    /// register idx [25:21]
    fn rs(self: Instruction) u32 {
        return (self.opcode >> 21) & 0x1f;
    }
    /// immediate value [16:0]
    fn immu(self: Instruction) u32 {
        return self.opcode & 0xffff;
    }
    /// immediate value [16:0] sign extended
    fn immSext(self: Instruction) u32 {
        const res = @as(i16, @bitCast(@as(u16, @truncate(self.opcode & 0xffff))));
        return @as(u32, @bitCast(@as(i32, @intCast(res))));
    }
    /// Shift imm [10:6]
    fn shift(self: Instruction) u5 {
        return @as(u5, @truncate((self.opcode >> 6) & 0x1f));
    }
    /// jump target [25:0]
    fn immJp(self: Instruction) u32 {
        return self.opcode & 0x3ffffff;
    }
};

pub const Cpu = struct {
    /// Program counter
    pc: u32,
    /// Current instr's pc
    current_pc: u32,
    /// Next PC
    next_pc: u32,
    /// HI
    hi: u32,
    /// LO
    lo: u32,
    /// General purpose registers
    gpr: [32]u32,
    /// Output GPR for load delays
    out_gpr: [32]u32,
    mem: *Memory,
    /// Load delay slots
    load: [2]u32,
    /// Co-processor 0 status register
    sr: u32,
    /// Co-processor 0 cause register
    cause: u32,
    /// Co-processor 0 exception register
    epc: u32,
    /// branch flag
    bf: bool,
    /// delay slot
    delay: bool,
    /// Initialize the cpu
    pub fn init(memory: *Memory) Cpu {
        var gpr = std.mem.zeroes([32]u32);
        gpr[0] = 0;

        const pc = 0xbfc00000;

        return Cpu{
            .pc = pc,
            .next_pc = pc +% 4,
            .current_pc = pc,
            .hi = 0,
            .lo = 0,
            .sr = 0,
            .cause = 0,
            .epc = 0,
            .gpr = gpr,
            .out_gpr = gpr,
            .mem = memory,
            .bf = false,
            .delay = false,
            .load = [_]u32{ 0, 0 },
        };
    }
    /// Read a register
    fn reg(self: *const Cpu, idx: u32) u32 {
        return self.gpr[idx];
    }
    /// Write to a register
    fn wreg(self: *Cpu, idx: u32, v: u32) void {
        self.out_gpr[idx] = v;
        // write to R0 are ignored
        self.out_gpr[0] = 0;
    }
    /// Unimplimented instruction
    fn unimplimented(instr: Instruction) !void {
        std.debug.print("Unimplimented instr {x}\n", .{instr.opcode});
        return PsxError.Unimplimented;
    }
    /// Cpu exception
    fn exception(self: *Cpu, cause: PsxExcept) void {
        const handler: u32 = if (self.sr & (1 << 22) != 0) 0xbfc00180 else 0x80000080;
        const mode = self.sr & 0x3f;
        self.sr &= ~(@as(u32, 0x3f));
        self.sr |= (mode << 2) & 0x3f;

        self.cause = @as(u32, @intCast(@intFromEnum(cause))) << 2;
        self.epc = self.current_pc;

        if (self.delay) {
            self.epc -%= 4;
            self.cause |= 1 << 31;
        }

        self.pc = handler;
        self.next_pc = self.pc +% 4;
    }
    /// lui rt, imm
    fn lui(self: *Cpu, instr: Instruction) void {
        const i = instr.immu();
        const t = instr.rt();
        const v = i << 16;
        self.wreg(t, v);
    }
    /// ori rt, rs, imm
    fn ori(self: *Cpu, instr: Instruction) void {
        const i = instr.immu();
        const t = instr.rt();
        const s = instr.rs();
        const v = self.reg(s) | i;
        self.wreg(t, v);
    }
    /// sw rt, imm(rs)
    fn sw(self: *Cpu, instr: Instruction) !void {
        if (self.sr & 0x10000 != 0) {
            return;
        }

        const i = instr.immSext();
        const t = instr.rt();
        const s = instr.rs();
        const addr = self.reg(s) +% i;
        if (addr % 4 != 0) {
            return self.exception(PsxExcept.StoreAddr);
        }

        const v = self.reg(t);
        try self.mem.store32(addr, v);
    }
    /// sll rt, rd, imm5
    fn sll(self: *Cpu, instr: Instruction) void {
        const shiftv = instr.shift();
        const t = instr.rt();
        const d = instr.rd();
        const v = self.reg(t) << shiftv;
        self.wreg(d, v);
    }
    /// addiu rt, rs, imm
    fn addiu(self: *Cpu, instr: Instruction) void {
        const i = instr.immSext();
        const t = instr.rt();
        const s = instr.rs();
        const v = self.reg(s) +% i;
        self.wreg(t, v);
    }
    /// j imm5
    fn j(self: *Cpu, instr: Instruction) void {
        const i = instr.immJp();
        self.next_pc = (self.pc & 0xf0000000) | (i << 2);
        self.bf = true;
    }
    /// or rd, rs, rt
    fn bwor(self: *Cpu, instr: Instruction) void {
        const d = instr.rd();
        const s = instr.rs();
        const t = instr.rt();
        const v = self.reg(s) | self.reg(t);
        self.wreg(d, v);
    }
    fn branch(self: *Cpu, offset: u32, cond: bool) void {
        if (!cond) {
            return;
        }
        const soffset = offset << 2;
        self.next_pc = self.pc +% soffset;
        self.bf = true;
    }
    /// bne rs, rt, imm
    fn bne(self: *Cpu, instr: Instruction) void {
        const i = instr.immSext();
        const s = instr.rs();
        const t = instr.rt();
        self.branch(i, self.reg(s) != self.reg(t));
    }
    /// addi rt, rs, imm
    fn addi(self: *Cpu, instr: Instruction) !void {
        const i = @as(i32, @bitCast(instr.immSext()));
        const t = instr.rt();
        const s = instr.rs();

        const sv = @as(i32, @bitCast(self.reg(s)));
        const res = @addWithOverflow(sv, i);
        if (res[1] == 1) {
            return self.exception(PsxExcept.Overflow);
        }

        self.wreg(t, @as(u32, @bitCast(res[0])));
    }
    /// lw rt, imm(rs)
    fn lw(self: *Cpu, instr: Instruction) !void {
        if (self.sr & 0x10000 != 0) {
            return;
        }

        const i = instr.immSext();
        const t = instr.rt();
        const s = instr.rs();
        const addr = self.reg(s) +% i;
        if (addr % 4 != 0) {
            return self.exception(PsxExcept.LoadAddr);
        }

        const v = try self.mem.load32(addr);
        self.load = .{ t, v };
    }
    /// sltu rd, rs, rt
    fn sltu(self: *Cpu, instr: Instruction) void {
        const d = instr.rd();
        const s = instr.rs();
        const t = instr.rt();
        const v = self.reg(s) < self.reg(t);
        self.wreg(d, @intFromBool(v));
    }
    /// addu rd, rs, rt
    fn addu(self: *Cpu, instr: Instruction) void {
        const s = instr.rs();
        const t = instr.rt();
        const d = instr.rd();
        const v = self.reg(s) +% self.reg(t);
        self.wreg(d, v);
    }
    /// sh rt, imm(rs)
    fn sh(self: *Cpu, instr: Instruction) !void {
        if (self.sr & 0x10000 != 0) {
            return;
        }
        const i = instr.immSext();
        const t = instr.rt();
        const s = instr.rs();
        const addr = self.reg(s) +% i;
        if (addr % 2 != 0) {
            return self.exception(PsxExcept.StoreAddr);
        }

        const v = self.reg(t);
        try self.mem.store16(addr, @as(u16, @truncate(v)));
    }
    /// jal imm5
    fn jal(self: *Cpu, instr: Instruction) void {
        const pcv = self.next_pc;
        self.j(instr);
        self.wreg(31, pcv);
        self.bf = true;
    }
    /// andi rt, rs, imm
    fn andi(self: *Cpu, instr: Instruction) void {
        const i = instr.immu();
        const t = instr.rt();
        const s = instr.rs();
        const v = self.reg(s) & i;
        self.wreg(t, v);
    }
    /// sb rt, imm(rs)
    fn sb(self: *Cpu, instr: Instruction) !void {
        if (self.sr & 0x10000 != 0) {
            return;
        }

        const i = instr.immSext();
        const t = instr.rt();
        const s = instr.rs();
        const addr = self.reg(s) +% i;
        const v = self.reg(t);
        try self.mem.store8(addr, @as(u8, @truncate(v)));
    }
    /// jr rs
    fn jr(self: *Cpu, instr: Instruction) void {
        const s = instr.rs();
        self.next_pc = self.reg(s);
        self.bf = true;
    }
    /// lb rt, imm(rs)
    fn lb(self: *Cpu, instr: Instruction) !void {
        const i = instr.immSext();
        const t = instr.rt();
        const s = instr.rs();
        const addr = self.reg(s) +% i;
        const v = @as(i8, @bitCast(try self.mem.load8(addr)));
        self.load = .{ t, @as(u32, @bitCast(@as(i32, @intCast(v)))) };
    }
    /// beq rs, rt, imm
    fn beq(self: *Cpu, instr: Instruction) void {
        const i = instr.immSext();
        const s = instr.rs();
        const t = instr.rt();
        self.branch(i, self.reg(s) == self.reg(t));
    }
    /// and rd, rs, rt
    fn bwand(self: *Cpu, instr: Instruction) !void {
        const d = instr.rd();
        const s = instr.rs();
        const t = instr.rt();
        const v = self.reg(s) & self.reg(t);
        self.wreg(d, v);
    }
    /// add rt, rs, rd
    /// (psx-spx ref says imm instead of rd for some reason)
    fn add(self: *Cpu, instr: Instruction) !void {
        const s = instr.rs();
        const t = instr.rt();
        const d = instr.rd();

        const sv = @as(i32, @bitCast(self.reg(s)));
        const tv = @as(i32, @bitCast(self.reg(t)));
        const res = @addWithOverflow(sv, tv);
        if (res[1] == 1) {
            return self.exception(PsxExcept.Overflow);
        }

        self.wreg(d, @as(u32, @bitCast(res[0])));
    }
    /// bgtz rs, imm
    fn bgtz(self: *Cpu, instr: Instruction) void {
        const i = instr.immSext();
        const s = instr.rs();
        const v = @as(i32, @bitCast(self.reg(s)));
        self.branch(i, v > 0);
    }
    /// blez rs, imm
    fn blez(self: *Cpu, instr: Instruction) void {
        const i = instr.immSext();
        const s = instr.rs();
        const v = @as(i32, @bitCast(self.reg(s)));
        self.branch(i, v <= 0);
    }
    /// lbu rt, imm(rs)
    fn lbu(self: *Cpu, instr: Instruction) !void {
        const i = instr.immSext();
        const t = instr.rt();
        const s = instr.rs();
        const addr = self.reg(s) +% i;
        const v = try self.mem.load8(addr);
        self.load = .{ t, @as(u32, @intCast(v)) };
    }
    /// jalr rd, rs
    fn jalr(self: *Cpu, instr: Instruction) void {
        const d = instr.rd();
        const s = instr.rs();
        self.wreg(d, self.next_pc);
        self.next_pc = self.reg(s);
        self.bf = true;
    }
    /// bxx rs,imm
    fn bxx(self: *Cpu, instr: Instruction) void {
        const i = instr.immSext();
        const s = instr.rs();
        const v = @as(i32, @bitCast(self.reg(s)));
        const b_test = @intFromBool(v < 0) ^ ((instr.opcode >> 16) & 1);
        const is_link = (instr.opcode >> 17) & 0xf == 8;
        if (is_link) {
            self.wreg(31, self.next_pc);
        }
        self.branch(i, b_test != 0);
    }
    /// slti rt, rs, imm
    fn slti(self: *Cpu, instr: Instruction) void {
        const i = @as(i32, @bitCast(instr.immSext()));
        const t = instr.rt();
        const s = instr.rs();
        const sv = @as(i32, @bitCast(self.reg(s)));
        const v = @intFromBool(sv < i);
        self.wreg(t, v);
    }
    /// subu rd, rs, rt
    fn subu(self: *Cpu, instr: Instruction) void {
        const s = instr.rs();
        const t = instr.rt();
        const d = instr.rd();
        const v = self.reg(s) -% self.reg(t);
        self.wreg(d, @as(u32, @bitCast(v)));
    }
    /// sra rd, rt, imm5
    fn sra(self: *Cpu, instr: Instruction) void {
        const shiftv = instr.shift();
        const t = instr.rt();
        const d = instr.rd();
        const v = @as(i32, @bitCast(self.reg(t))) >> shiftv;
        self.wreg(d, @as(u32, @bitCast(v)));
    }
    /// div rs, rt
    fn div(self: *Cpu, instr: Instruction) void {
        const s = instr.rs();
        const t = instr.rt();
        const n = @as(i32, @bitCast(self.reg(s)));
        const d = @as(i32, @bitCast(self.reg(t)));

        if (d == 0) {
            self.hi = @as(u32, @bitCast(n));
            self.lo = if (n >= 0) 0xffffffff else 1;
            return;
        }

        if (@as(u32, @bitCast(n)) == 0x80000000 and d == -1) {
            self.hi = 0;
            self.lo = 0x80000000;
            return;
        }

        self.hi = @as(u32, @bitCast(@mod(n, d)));
        self.lo = @as(u32, @bitCast(@divFloor(n, d)));
    }
    /// mflo rd
    fn mflo(self: *Cpu, instr: Instruction) void {
        const d = instr.rd();
        self.wreg(d, self.lo);
    }
    /// srl rd, rt, imm5
    fn srl(self: *Cpu, instr: Instruction) void {
        const shiftv = instr.shift();
        const t = instr.rt();
        const d = instr.rd();
        const v = self.reg(t) >> shiftv;
        self.wreg(d, v);
    }
    /// sltiu rt, rs, imm
    fn sltiu(self: *Cpu, instr: Instruction) void {
        const i = instr.immSext();
        const s = instr.rs();
        const t = instr.rt();
        const v = @intFromBool(self.reg(s) < i);
        self.wreg(t, v);
    }
    /// divu rs, rt
    fn divu(self: *Cpu, instr: Instruction) void {
        const s = instr.rs();
        const t = instr.rt();

        const n = self.reg(s);
        const d = self.reg(t);

        if (d == 0) {
            self.hi = n;
            self.lo = 0xffffffff;
            return;
        }

        self.hi = n % d;
        self.lo = n / d;
    }
    /// mfhi rd
    fn mfhi(self: *Cpu, instr: Instruction) void {
        const d = instr.rd();
        self.wreg(d, self.hi);
    }
    /// slt rd, rs, rt
    fn slt(self: *Cpu, instr: Instruction) void {
        const d = instr.rd();
        const s = instr.rs();
        const t = instr.rt();

        const sv = @as(i32, @bitCast(self.reg(s)));
        const tv = @as(i32, @bitCast(self.reg(t)));

        self.wreg(d, @intFromBool(sv < tv));
    }
    /// syscall
    fn syscall(self: *Cpu) void {
        self.exception(PsxExcept.SysCall);
    }
    /// mtlo rs
    fn mtlo(self: *Cpu, instr: Instruction) void {
        const s = instr.rs();
        self.lo = self.reg(s);
    }
    /// mthi rs
    fn mthi(self: *Cpu, instr: Instruction) void {
        const s = instr.rs();
        self.hi = self.reg(s);
    }
    /// lhu rt, imm(rs)
    fn lhu(self: *Cpu, instr: Instruction) !void {
        const i = instr.immSext();
        const t = instr.rt();
        const s = instr.rs();

        const addr = self.reg(s) +% i;
        if (addr % 2 != 0) {
            return self.exception(PsxExcept.LoadAddr);
        }

        const v = try self.mem.load16(addr);
        self.load = .{ t, @as(u32, @intCast(v)) };
    }
    /// sllv rd, rt, rs
    fn sllv(self: *Cpu, instr: Instruction) void {
        const d = instr.rd();
        const t = instr.rt();
        const s = instr.rs();

        const v = self.reg(t) << @as(u5, @truncate((self.reg(s) & 0x1f)));
        self.wreg(d, v);
    }
    /// lh rt, imm(rs)
    fn lh(self: *Cpu, instr: Instruction) !void {
        const i = instr.immSext();
        const t = instr.rt();
        const s = instr.rs();

        const addr = self.reg(s) +% i;
        if (addr % 2 != 0) {
            return self.exception(PsxExcept.LoadAddr);
        }

        const v = @as(i16, @bitCast(try self.mem.load16(addr)));

        self.load = .{ t, @as(u32, @bitCast(@as(i32, @intCast(v)))) };
    }
    /// nor rd, rs, rt
    fn nor(self: *Cpu, instr: Instruction) void {
        const d = instr.rd();
        const s = instr.rs();
        const t = instr.rt();

        const v = ~(self.reg(s) | self.reg(t));
        self.wreg(d, v);
    }
    /// srav rd, rs, rt
    fn srav(self: *Cpu, instr: Instruction) void {
        const d = instr.rd();
        const s = instr.rs();
        const t = instr.rt();

        const tv = @as(i32, @bitCast(self.reg(t)));
        // tv >> self.reg(s) & 0x1f
        const v = tv >> @as(u5, @truncate((self.reg(s) & 0x1f)));
        self.wreg(d, @as(u32, @bitCast(v)));
    }
    /// srlv rd, rs, rt
    fn srlv(self: *Cpu, instr: Instruction) void {
        const d = instr.rd();
        const s = instr.rs();
        const t = instr.rt();

        const v = self.reg(t) >> @as(u5, @truncate((self.reg(s) & 0x1f)));
        self.wreg(d, v);
    }
    /// multu rs, rt
    fn multu(self: *Cpu, instr: Instruction) void {
        const s = instr.rs();
        const t = instr.rt();

        const sv = @as(u64, @intCast(self.reg(s)));
        const tv = @as(u64, @intCast(self.reg(t)));

        const v = sv * tv;
        self.hi = @as(u32, @truncate(v >> 32));
        self.lo = @as(u32, @truncate(v));
    }
    /// mult rs, rt
    fn mult(self: *Cpu, instr: Instruction) void {
        const s = instr.rs();
        const t = instr.rt();

        const sv = @as(i64, @intCast(@as(i32, @bitCast(self.reg(s)))));
        const tv = @as(i64, @intCast(@as(i32, @bitCast(self.reg(t)))));

        const v = @as(u64, @bitCast(sv * tv));
        self.hi = @as(u32, @truncate(v >> 32));
        self.lo = @as(u32, @truncate(v));
    }
    /// xor rd, rs, rt
    fn xor(self: *Cpu, instr: Instruction) void {
        const d = instr.rd();
        const s = instr.rs();
        const t = instr.rt();

        const v = self.reg(s) ^ self.reg(t);
        self.wreg(d, v);
    }
    /// break
    fn trapBreak(self: *Cpu) void {
        self.exception(PsxExcept.Break);
    }
    /// sub rd, rs, rt
    fn sub(self: *Cpu, instr: Instruction) void {
        const s = instr.rs();
        const t = instr.rt();
        _ = t;
        const d = instr.rd();

        const sv = @as(i32, @bitCast(self.reg(s)));
        const tv = @as(i32, @bitCast(self.reg(s)));

        const res = @subWithOverflow(sv, tv);
        if (res[1] == 1) {
            return self.exception(PsxExcept.Overflow);
        }

        self.wreg(d, @as(u32, @bitCast(res[0])));
    }
    /// xori rt, rs, imm
    fn xori(self: *Cpu, instr: Instruction) void {
        const i = instr.immu();
        const t = instr.rt();
        const s = instr.rs();

        const v = self.reg(s) ^ i;
        self.wreg(t, v);
    }
    /// lwl rt, imm(rs)
    fn lwl(self: *Cpu, instr: Instruction) !void {
        const i = instr.immSext();
        const t = instr.rt();
        const s = instr.rs();

        const addr = self.reg(s) +% i;
        const cur_v = self.out_gpr[t];

        const allign_addr = addr & ~@as(u32, 3);
        const allign_word = try self.mem.load32(allign_addr);

        // allignment
        const a: u5 = @truncate((addr & 3) * 8);
        // (cur_v & (0x00ffffff >> a)) | (allign_word << 24 - a))
        const v = (cur_v & (@as(u32, 0x00ffffff) >> a)) | (allign_word << 24 - a);
        self.load = .{ t, v };
    }
    /// lwr rt, imm(rs)
    fn lwr(self: *Cpu, instr: Instruction) !void {
        const i = instr.immSext();
        const t = instr.rt();
        const s = instr.rs();

        const addr = self.reg(s) +% i;
        const cur_v = self.out_gpr[t];

        const allign_addr = addr & ~@as(u32, 3);
        const allign_word = try self.mem.load32(allign_addr);

        const a: u5 = @truncate((addr & 3) * 8);
        const v = (cur_v & (~(@as(u32, 0xffffffff) >> a))) | (allign_word >> a);
        self.load = .{ t, v };
    }
    /// swl rt, imm(rs)
    fn swl(self: *Cpu, instr: Instruction) !void {
        const i = instr.immSext();
        const t = instr.rt();
        const s = instr.rs();

        const addr = self.reg(s) +% i;
        const v = self.reg(t);

        const allign_addr = addr & ~@as(u32, 3);
        const cur_mem = try self.mem.load32(allign_addr);

        // Too lazy to optimize this
        const mem = switch (addr & 3) {
            0 => (cur_mem & 0xffffff00) | (v >> 24),
            1 => (cur_mem & 0xffff0000) | (v >> 16),
            2 => (cur_mem & 0xff000000) | (v >> 8),
            3 => (cur_mem & 0x00000000) | (v >> 0),
            else => unreachable,
        };
        try self.mem.store32(allign_addr, mem);
    }
    /// swr rt, imm(rs)
    fn swr(self: *Cpu, instr: Instruction) !void {
        const i = instr.immSext();
        const t = instr.rt();
        const s = instr.rs();

        const addr = self.reg(s) +% i;
        const v = self.reg(t);

        const allign_addr = addr & ~@as(u32, 3);
        const cur_mem = try self.mem.load32(allign_addr);

        const mem = switch (addr & 3) {
            0 => (cur_mem & 0x00000000) | (v << 0),
            1 => (cur_mem & 0x000000ff) | (v << 8),
            2 => (cur_mem & 0x0000ffff) | (v << 16),
            3 => (cur_mem & 0x00ffffff) | (v << 24),
            else => unreachable,
        };
        try self.mem.store32(allign_addr, mem);
    }
    fn illegal(self: *Cpu, instr: Instruction) void {
        std.debug.print("Illegal instr {x}\n", .{instr.opcode});
        self.exception(PsxExcept.IllegalInstr);
    }
    fn execSecondary(self: *Cpu, instr: Instruction) !void {
        try switch (instr.sec()) {
            0b000000 => self.sll(instr),
            0b100101 => self.bwor(instr),
            0b101011 => self.sltu(instr),
            0b100001 => self.addu(instr),
            0b001000 => self.jr(instr),
            0b100100 => self.bwand(instr),
            0b100000 => self.add(instr),
            0b001001 => self.jalr(instr),
            0b100010 => self.sub(instr),
            0b100011 => self.subu(instr),
            0b000011 => self.sra(instr),
            0b011010 => self.div(instr),
            0b010010 => self.mflo(instr),
            0b000010 => self.srl(instr),
            0b011011 => self.divu(instr),
            0b010000 => self.mfhi(instr),
            0b101010 => self.slt(instr),
            0b001100 => self.syscall(),
            0b001101 => self.trapBreak(),
            0b010011 => self.mtlo(instr),
            0b010001 => self.mthi(instr),
            0b000100 => self.sllv(instr),
            0b100111 => self.nor(instr),
            0b000111 => self.srav(instr),
            0b000110 => self.srlv(instr),
            0b011000 => self.mult(instr),
            0b011001 => self.multu(instr),
            0b100110 => self.xor(instr),
            else => self.illegal(instr),
        };
    }
    /// mtc0 rt, rd
    fn mtc0(self: *Cpu, instr: Instruction) !void {
        const t = instr.rt();
        const d = instr.rd();
        const v = self.reg(t);
        try switch (d) {
            3, 5, 6, 7, 9, 11, 13 => {},
            12 => self.sr = v,
            else => Cpu.unimplimented(instr),
        };
    }
    /// mfc0 rt, rd
    fn mfc0(self: *Cpu, instr: Instruction) !void {
        const t = instr.rt();
        const d = instr.rd();
        const v = switch (d) {
            12 => self.sr,
            13 => self.cause,
            14 => self.epc,
            else => return Cpu.unimplimented(instr),
        };
        self.load = .{ t, v };
    }
    /// rfe
    fn rfe(self: *Cpu, instr: Instruction) void {
        _ = instr;
        const mode = self.sr & 0x3f;
        self.sr &= ~(@as(u32, 0x3f));
        self.sr |= mode >> 2;
    }
    fn execCop0(self: *Cpu, instr: Instruction) !void {
        try switch (instr.copCode()) {
            0b00100 => self.mtc0(instr),
            0b00000 => self.mfc0(instr),
            0b10000 => self.rfe(instr),
            else => Cpu.unimplimented(instr),
        };
    }
    fn execCop2(self: *Cpu, instr: Instruction) !void {
        _ = self;
        try Cpu.unimplimented(instr);
    }
    fn cop1(self: *Cpu) void {
        self.exception(PsxExcept.CopE);
    }
    fn cop3(self: *Cpu) void {
        self.exception(PsxExcept.CopE);
    }
    fn lwc0(self: *Cpu) void {
        self.exception(PsxExcept.CopE);
    }
    fn lwc1(self: *Cpu) void {
        self.exception(PsxExcept.CopE);
    }
    fn lwc2(self: *Cpu, instr: Instruction) !void {
        _ = self;
        try Cpu.unimplimented(instr);
    }
    fn lwc3(self: *Cpu) void {
        self.exception(PsxExcept.CopE);
    }
    fn swc0(self: *Cpu) void {
        self.exception(PsxExcept.CopE);
    }
    fn swc1(self: *Cpu) void {
        self.exception(PsxExcept.CopE);
    }
    fn swc2(self: *Cpu, instr: Instruction) !void {
        _ = self;
        try Cpu.unimplimented(instr);
    }
    fn swc3(self: *Cpu) void {
        self.exception(PsxExcept.CopE);
    }
    fn exec(self: *Cpu, instr: Instruction) !void {
        try switch (instr.func()) {
            0b001111 => self.lui(instr),
            0b001101 => self.ori(instr),
            0b001110 => self.xori(instr),
            0b101010 => self.swl(instr),
            0b101011 => self.sw(instr),
            0b001001 => self.addiu(instr),
            0b000010 => self.j(instr),
            0b010000 => self.execCop0(instr),
            0b010001 => self.cop1(),
            0b010010 => self.execCop2(instr),
            0b010011 => self.cop3(),
            0b000000 => self.execSecondary(instr),
            0b001000 => self.addi(instr),
            0b000101 => self.bne(instr),
            0b100010 => self.lwl(instr),
            0b100011 => self.lw(instr),
            0b101001 => self.sh(instr),
            0b000011 => self.jal(instr),
            0b001100 => self.andi(instr),
            0b101000 => self.sb(instr),
            0b100000 => self.lb(instr),
            0b000100 => self.beq(instr),
            0b000111 => self.bgtz(instr),
            0b000110 => self.blez(instr),
            0b100100 => self.lbu(instr),
            0b000001 => self.bxx(instr),
            0b001010 => self.slti(instr),
            0b001011 => self.sltiu(instr),
            0b100101 => self.lhu(instr),
            0b100110 => self.lwr(instr),
            0b100001 => self.lh(instr),
            0b101110 => self.swr(instr),
            0b110000 => self.lwc0(),
            0b110001 => self.lwc1(),
            0b110010 => self.lwc2(instr),
            0b110011 => self.lwc3(),
            0b111000 => self.swc0(),
            0b111001 => self.swc1(),
            0b111010 => self.swc2(instr),
            0b111011 => self.swc3(),
            else => self.illegal(instr),
        };
    }
    /// Execute the next instruction
    pub fn next(self: *Cpu) !void {
        self.current_pc = self.pc;
        if (self.current_pc % 4 != 0) {
            return self.exception(PsxExcept.LoadAddr);
        }

        const instr_raw = try self.mem.load32(self.pc);
        const instr = Instruction{ .opcode = instr_raw };

        self.pc = self.next_pc;
        self.next_pc +%= 4;

        self.wreg(self.load[0], self.load[1]);
        self.load[0] = 0;

        self.delay = self.bf;
        self.bf = false;

        try self.exec(instr);

        self.gpr = self.out_gpr;
    }
};
