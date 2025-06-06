const c = @cImport({
    @cInclude("libfdt.h");
    @cInclude("libfdt_env.h");
});
const print = @import("serial.zig").print;
const mmu = @import("mmu.zig");

const std = @import("std");

const DIST = extern struct {
    enable: u32,
    ic_type: u32,
    dist_ident: u32,
    res1: [29]u32,
    security: [32]u32,
    enable_set: [32]u32,
    enable_clr: [32]u32,
    pending_set: [32]u32,
    pending_clr: [32]u32,
    active: [32]u32,
    res2: [32]u32,
    priority: [255]u32,
    res3: u32,
    targets: [255]u32,
    res4: u32,
    config: [64]u32,
    spi: [32]u32,
    res5: [20]u32,
    res6: u32,
    lagacy_int: u32,
    res7: [2]u32,
    match_d: u32,
    enable_d: u32,
    res8: [70]u32,
    sgi_control: u32,
    res9: [3]u32,
    sgi_pending_clr: [4]u32,
    res10: [40]u32,
    periph_id: [12]u32,
    component_id: [4]u32,
};

const Self = @This();

dist: *volatile DIST = undefined,
num_lrs: usize = 0,
maintenance_irq: u32 = 25, // TODO: retrieve from dtb

extern var pgd: [512]u64 align(1 << 12);

pub fn init(dtb: ?[*]u8) ?Self {
    var self: Self = .{};
    const root_node_offset = c.fdt_path_offset(dtb, "/");
    if (root_node_offset < 0) {
        print("GICv3: failed to find root node: {}\n", .{root_node_offset});
        return null;
    }
    var gic_node_offset = c.fdt_first_subnode(dtb, root_node_offset);
    while (gic_node_offset >= 0) : (gic_node_offset = c.fdt_next_subnode(dtb, gic_node_offset)) {
        if (c.fdt_getprop(dtb, gic_node_offset, "interrupt-controller", null) != null) {
            const comp: *const ["arm,gic-v3".len:0]u8 = @ptrCast(c.fdt_getprop(dtb, gic_node_offset, "compatible", null).?);
            if (std.mem.eql(u8, comp, "arm,gic-v3")) break;
        }
    } else {
        print("GICv3: failed to find interrupt controller\n", .{});
        return null;
    }

    // Map distributor as we need to enable matainence irq
    const data: [*c]const u8 = @ptrCast(c.fdt_getprop(dtb, gic_node_offset, "reg", null).?);

    const gicd_addr: u64 = c.fdt64_to_cpu(@as(*align(1) const u64, @alignCast(@ptrCast(data))).*);
    const gicd_size: u64 = c.fdt64_to_cpu(@as(*align(1) const u64, @alignCast(@ptrCast(data + 8))).*);
    print("GICv3: dist: addr: {x}, size: {x}\n", .{ gicd_addr, gicd_size });
    self.dist = @alignCast(@ptrCast(mmu.map_device(&pgd, gicd_addr, gicd_addr, gicd_size)));

    var vtr: u64 = undefined;
    asm volatile ("mrs %[vtr], ich_vtr_el2"
        : [vtr] "=r" (vtr),
    );
    self.num_lrs = (vtr & 0x1f) + 1;
    print("GICv3: {} LRs\n", .{self.num_lrs});

    return self;
}

pub fn enable_vcpuif(_: *Self) void {
    const icc_sre_el2 = (1 << 0) | (1 << 3); // Enable EL2 to use system register interface and don't trap EL1's access to icc_sre_el1
    const ich_hcr = 1; // enable vcpuif
    const icc_ctl = (1 << 1); // EOImode = 1 for physical interrupt handling
    const icc_igrp = 1; // enable
    const icc_pmr = 0xf0;

    asm volatile (
        \\ msr icc_sre_el2, %[icc_sre_el2]
        \\ msr icc_ctlr_el1, %[icc_ctl]
        \\ msr icc_igrpen1_el1, %[icc_igrp]
        \\ msr icc_pmr_el1, %[icc_pmr]
        \\ msr ich_hcr_el2, %[ich_hcr]
        :
        : [ich_hcr] "r" (ich_hcr),
          [icc_ctl] "r" (icc_ctl),
          [icc_igrp] "r" (icc_igrp),
          [icc_pmr] "r" (icc_pmr),
          [icc_sre_el2] "r" (icc_sre_el2),
    );
}

pub fn ack_irq(_: *const Self) u32 {
    var v: u32 = 1023;
    asm volatile ("mrs %[v], icc_iar1_el1"
        : [v] "=r" (v),
    );

    return v;
}

fn enable_maintainance_irq(self: *const Self) void {
    const idx = self.maintenance_irq >> 5;
    const bit = self.maintenance_irq & 0x1f;

    self.dist.enable_set[idx] = @as(u32, 1) << @truncate(bit);
}

pub fn inject_virq(_: *const Self, _: u32) void {}

fn eoi(_: *const Self, _: u32) void {}
