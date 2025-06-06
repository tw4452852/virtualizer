const Self = @This();

pub fn init(_: ?[*]u8) ?Self {
	return null;
}

pub fn enable_vcpuif(_: *Self) void {
}

pub fn ack_irq(_: *const Self) u32 {
	return 1023;
}

pub fn inject_virq(_: *const Self, _: u32) void {
}

pub fn eoi(_: *const Self, _: u32) void {
}