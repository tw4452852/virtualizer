const Self = @This();

base: [*]volatile u8,

pub fn init(base: u64) Self {
    return .{
        .base = @ptrFromInt(base),
    };
}

pub fn putc(self: *const Self, c: u8) void {
    const FR_TXFF = 1 << 5;
    const FR = 0x18;
    const DR = 0;

    while ((self.base[FR] & FR_TXFF) != 0) {}
    self.base[DR] = c;
}
