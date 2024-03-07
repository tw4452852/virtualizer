const arch = @import("arch");
const std = @import("std");

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    const first_trace_addr = ret_addr orelse @returnAddress();
    arch.print("Panic: {s}, ret_addr: {x}\n", .{ msg, first_trace_addr });
    while (true) {}
}

export fn main() noreturn {
    arch.print("hello world\n", .{});

    arch.start_vm(@embedFile("kernel"));

    arch.print("Exit, spin...\n", .{});
    while (true) {}
}
