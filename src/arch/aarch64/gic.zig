const c = @cImport({
    @cInclude("libfdt.h");
    @cInclude("libfdt_env.h");
});
const print = @import("serial.zig").print;
const GIC2 = @import("gic2.zig");
const GIC3 = @import("gic3.zig");

const Self = @This();

const Kind = enum {
    v2,
    v3,
    none,
};

impl: union(Kind) {
    v2: GIC2,
    v3: GIC3,
    none: void,
} = .{ .none = {} },

pub fn init(self: *Self, dtb: ?[*]u8) bool {
    const root_node_offset = c.fdt_path_offset(dtb, "/");
    if (root_node_offset < 0) {
        print("failed to find root node: {}\n", .{root_node_offset});
        return false;
    }
    var gic_node_offset = c.fdt_first_subnode(dtb, root_node_offset);
    while (gic_node_offset >= 0) : (gic_node_offset = c.fdt_next_subnode(dtb, gic_node_offset)) {
        if (c.fdt_getprop(dtb, gic_node_offset, "interrupt-controller", null) != null) break;
    } else {
        print("failed to find interrupt controller\n", .{});
        return false;
    }

    if (GIC3.init(dtb)) |gic3| {
        self.impl = .{ .v3 = gic3 };
        return true;
    }

    if (GIC2.init(dtb)) |gic2| {
        self.impl = .{ .v2 = gic2 };
        return true;
    }

    return false;
}

pub fn enable_vcpuif(self: *Self) void {
    switch (self.impl) {
        .v2 => |*gic2| gic2.enable_vcpuif(),
        .v3 => |*gic3| gic3.enable_vcpuif(),
        .none => {},
    }
}

pub fn ack_irq(self: *const Self) u32 {
    return switch (self.impl) {
        .v2 => |*gic2| gic2.ack_irq(),
        .v3 => |*gic3| gic3.ack_irq(),
        .none => 1023,
    };
}

pub fn inject_virq(self: *const Self, v: u32) void {
    switch (self.impl) {
        .v2 => |*gic2| gic2.inject_virq(v),
        .v3 => |*gic3| gic3.inject_virq(v),
        .none => {},
    }
}
