const Driver = @import("pl011.zig");
const std = @import("std");

pub const base = 0x9000000;

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
    const driver = Driver.init(base);

    for (bytes) |c| driver.putc(c);
}
