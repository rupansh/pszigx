/// Psx Exceptions
pub const PsxExcept = enum(u8) { SysCall = 0x8, Overflow = 0xc, LoadAddr = 0x4, StoreAddr = 0x5, Break = 0x9, CopE = 0xb, IllegalInstr = 0xa };
