const c = @cImport({
    @cInclude("libfdt.h");
    @cInclude("libfdt_env.h");
});
const print = @import("serial.zig").print;
const mmu = @import("mmu.zig");

const std = @import("std");

const Self = @This();

rds: [*c]volatile u8 = undefined,
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

    // Redistributor is the 2nd region, the 1st one is distributor
    const gicr_addr: u64 = c.fdt64_to_cpu(@as(*align(1) const u64, @ptrCast(@alignCast(data + 16))).*);
    const gicr_size: u64 = c.fdt64_to_cpu(@as(*align(1) const u64, @ptrCast(@alignCast(data + 24))).*);
    print("GICv3: redir: addr: {x}, size: {x}\n", .{ gicr_addr, gicr_size });
    self.rds = mmu.map_device(&pgd, gicr_addr, gicr_addr, gicr_size);

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

pub fn ack_irq(self: *const Self) u32 {
    var irq: u32 = 1023;
    var eisr: u64 = 0;
    asm volatile (
        \\ mrs %[irq], icc_iar1_el1
        \\ mrs %[eisr], ich_eisr_el2
        : [irq] "=r" (irq),
          [eisr] "=r" (eisr),
    );

    if (irq == self.maintenance_irq) {
        for (0..self.num_lrs) |i| {
            if ((eisr & (@as(u32, 1) << @truncate(i))) != 0) {
                irq = @truncate(read_lr(i));
                deactive(irq);
                write_lr(i, 0);
            }
        }
        eoi(self.maintenance_irq);
        deactive(self.maintenance_irq);

        return self.ack_irq();
    }

    return irq;
}

fn read_lr(i: usize) u64 {
    var v: u64 = undefined;
    switch (i) {
        0 => asm volatile ("mrs %[v], ich_lr0_el2"
            : [v] "=r" (v),
        ),
        1 => asm volatile ("mrs %[v], ich_lr1_el2"
            : [v] "=r" (v),
        ),
        2 => asm volatile ("mrs %[v], ich_lr2_el2"
            : [v] "=r" (v),
        ),
        3 => asm volatile ("mrs %[v], ich_lr3_el2"
            : [v] "=r" (v),
        ),
        4 => asm volatile ("mrs %[v], ich_lr4_el2"
            : [v] "=r" (v),
        ),
        5 => asm volatile ("mrs %[v], ich_lr5_el2"
            : [v] "=r" (v),
        ),
        6 => asm volatile ("mrs %[v], ich_lr6_el2"
            : [v] "=r" (v),
        ),
        7 => asm volatile ("mrs %[v], ich_lr7_el2"
            : [v] "=r" (v),
        ),
        8 => asm volatile ("mrs %[v], ich_lr8_el2"
            : [v] "=r" (v),
        ),
        9 => asm volatile ("mrs %[v], ich_lr9_el2"
            : [v] "=r" (v),
        ),
        10 => asm volatile ("mrs %[v], ich_lr10_el2"
            : [v] "=r" (v),
        ),
        11 => asm volatile ("mrs %[v], ich_lr11_el2"
            : [v] "=r" (v),
        ),
        12 => asm volatile ("mrs %[v], ich_lr12_el2"
            : [v] "=r" (v),
        ),
        13 => asm volatile ("mrs %[v], ich_lr13_el2"
            : [v] "=r" (v),
        ),
        14 => asm volatile ("mrs %[v], ich_lr14_el2"
            : [v] "=r" (v),
        ),
        15 => asm volatile ("mrs %[v], ich_lr15_el2"
            : [v] "=r" (v),
        ),
        else => unreachable,
    }

    return v;
}

fn write_lr(i: usize, v: u64) void {
    switch (i) {
        0 => asm volatile ("msr  ich_lr0_el2, %[v]"
            :
            : [v] "r" (v),
        ),
        1 => asm volatile ("msr  ich_lr1_el2, %[v]"
            :
            : [v] "r" (v),
        ),
        2 => asm volatile ("msr  ich_lr2_el2, %[v]"
            :
            : [v] "r" (v),
        ),
        3 => asm volatile ("msr  ich_lr3_el2, %[v]"
            :
            : [v] "r" (v),
        ),
        4 => asm volatile ("msr  ich_lr4_el2, %[v]"
            :
            : [v] "r" (v),
        ),
        5 => asm volatile ("msr  ich_lr5_el2, %[v]"
            :
            : [v] "r" (v),
        ),
        6 => asm volatile ("msr  ich_lr6_el2, %[v]"
            :
            : [v] "r" (v),
        ),
        7 => asm volatile ("msr  ich_lr7_el2, %[v]"
            :
            : [v] "r" (v),
        ),
        8 => asm volatile ("msr  ich_lr8_el2, %[v]"
            :
            : [v] "r" (v),
        ),
        9 => asm volatile ("msr  ich_lr9_el2, %[v]"
            :
            : [v] "r" (v),
        ),
        10 => asm volatile ("msr  ich_lr10_el2, %[v]"
            :
            : [v] "r" (v),
        ),
        11 => asm volatile ("msr  ich_lr11_el2, %[v]"
            :
            : [v] "r" (v),
        ),
        12 => asm volatile ("msr  ich_lr12_el2, %[v]"
            :
            : [v] "r" (v),
        ),
        13 => asm volatile ("msr  ich_lr13_el2, %[v]"
            :
            : [v] "r" (v),
        ),
        14 => asm volatile ("msr  ich_lr14_el2, %[v]"
            :
            : [v] "r" (v),
        ),
        15 => asm volatile ("msr  ich_lr15_el2, %[v]"
            :
            : [v] "r" (v),
        ),
        else => unreachable,
    }
}

fn eoi(irq: u32) void {
    asm volatile ("msr icc_eoir1_el1, %[irq]"
        :
        : [irq] "r" (irq),
    );
}

fn deactive(irq: u32) void {
    asm volatile ("msr icc_dir_el1, %[irq]"
        :
        : [irq] "r" (irq),
    );
}

fn enable_maintainance_irq(self: *const Self) void {
    const idx = self.maintenance_irq >> 5;
    const bit = self.maintenance_irq & 0x1f;
    const isenable0: *volatile u32 = @ptrCast(@alignCast(self.rds + (128 << 10) * @import("root.zig").cpu_idx() + (64 << 10) + 0x100));
    const ipriority6: *volatile u32 = @ptrCast(@alignCast(self.rds + (128 << 10) * @import("root.zig").cpu_idx() + (64 << 10) + 0x400 + 6 * 4));

    std.debug.assert(idx == 0);
    isenable0.* = @as(u32, 1) << @truncate(bit);
    ipriority6.* &= ~(@as(u32, 0xff) << 8);
}

pub fn inject_virq(self: *const Self, irq: u32) void {
    var elsr: u64 = 0;
    asm volatile (
        \\ mrs %[elsr], ich_elrsr_el2
        : [elsr] "=r" (elsr),
    );

    for (0..self.num_lrs) |i| {
        if ((elsr & (@as(u32, 1) << @truncate(i))) != 0) {
            if (irq > 15 and !(irq >= 1020 and irq <= 1023)) {
                write_lr(i, (1 << 62) | (1 << 61) | (1 << 60) | ((@as(u64, irq)) << 32) | irq);
            } else if (irq < 16) {
                write_lr(i, (1 << 62) | (1 << 60) | (1 << 41) | @as(u64, irq));
                self.enable_maintainance_irq();
            } else {
                print("Not support injecting irq {}\n", .{irq});
            }
            break;
        }
    } else {
        print("no room in LRs, skip irq {}\n", .{irq});
    }

    eoi(irq);
}
