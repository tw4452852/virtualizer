const Self = @This();

base: [*]volatile u32,

pub fn init(base: u64) Self {
    return .{
        .base = @ptrFromInt(base),
    };
}

pub fn putc(self: *const Self, c: u8) void {
    const LSR_THRE = 1 << 5;
    const LSR = 0x5;
    const THR = 0;

    while ((self.base[LSR] & LSR_THRE) == 0) {}
    self.base[THR] = c;
}
