const arch = @import("arch");
const std = @import("std");

export fn main() noreturn {
    arch.print("hello world \n", .{});

    arch.start_vm(@embedFile("kernel"));

    arch.print("Exit, spin...\n", .{});
    while (true) {}
}
