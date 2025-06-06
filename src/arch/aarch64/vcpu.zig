const lib = @import("root.zig");
const std = @import("std");

const Self = @This();
const BoundedArray = std.BoundedArray(u32, 16);

pub const LR = 30;
pub const SP = 31;
pub const ELR = 32;
pub const SPSR = 33;

pub const NUM_REGS = SPSR + 1;

x: [NUM_REGS]u64 = .{0} ** NUM_REGS,

pub fn restore(self: *const Self) noreturn {
    asm volatile (
        \\ mov sp, %[generals]
        \\ ldp x21, x22, [sp, #8 * 31]
        \\ msr sp_el0, x21
        \\ msr elr_el2, x22
        \\ ldr x21, [sp, #8 * 33]
        \\ msr spsr_el2, x21
        \\ ldp x0, x1, [sp, #16 * 0]
        \\ ldp x2, x3, [sp, #16 * 1]
        \\ ldp x4, x5, [sp, #16 * 2]
        \\ ldp x6, x7, [sp, #16 * 3]
        \\ ldp x8, x9, [sp, #16 * 4]
        \\ ldp x10, x11, [sp, #16 * 5]
        \\ ldp x12, x13, [sp, #16 * 6]
        \\ ldp x14, x15, [sp, #16 * 7]
        \\ ldp x16, x17, [sp, #16 * 8]
        \\ ldp x18, x19, [sp, #16 * 9]
        \\ ldp x20, x21, [sp, #16 * 10]
        \\ ldp x22, x23, [sp, #16 * 11]
        \\ ldp x24, x25, [sp, #16 * 12]
        \\ ldp x26, x27, [sp, #16 * 13]
        \\ ldp x28, x29, [sp, #16 * 14]
        \\ ldr x30, [sp, #8 * 30]
        \\ eret
        :
        : [generals] "r" (&self.x),
        : "memory"
    );

    unreachable;
}

extern var vm_pgd: [512]u64 align(1 << 12);
extern var gic: *lib.GIC;
pub fn enable(_: *const Self) void {
    const hcr_vm = (1 << 0);
    const hcr_rw = (1 << 31);
    const hcr_amo = (1 << 5);
    const hcr_imo = (1 << 4);
    const hcr_fmo = (1 << 3);
    const hcr_tsc = (1 << 19);

    const vtcr_el2: u64 = (64 - 39) | (1 << 6) | (1 << 8) | (1 << 10) | (3 << 12) | (1 << 31) | (2 << 16); // 40-bit IPA
    const vm_pgd_pa: u64 = (vm_pgd[0] >> 12) << 12;
    const hcr: u64 = hcr_vm | hcr_rw | hcr_amo | hcr_imo | hcr_fmo | hcr_tsc;
    const cnthctl: u64 = 3; // don't trap access to physical timer registers
    asm volatile (
        \\ dsb sy
        \\ msr vttbr_el2, %[vm_pgd]
        \\ msr sctlr_el1, %[sctlr_el1]
        \\ msr vtcr_el2, %[vtcr]
        \\ msr cnthctl_el2, %[cnthctl]
        \\ isb sy
        \\ msr hcr_el2, %[hcr]
        \\ isb
        :
        : [hcr] "r" (hcr),
          [vm_pgd] "r" (vm_pgd_pa),
          [sctlr_el1] "r" (0x30d00800),
          [vtcr] "r" (vtcr_el2),
          [cnthctl] "r" (cnthctl),
    );

    gic.enable_vcpuif();
}

extern const vcpus: [*]Self;
extern var start_core_id: u64;
extern fn secondary_start() callconv(.Naked) noreturn;
extern fn va2pa(va: u64) u64;
var onlined_cpus: usize = 0;

pub fn handle_smc(self: *Self) void {
    const id: u32 = @truncate(self.x[0]);
    const function: u16 = @truncate(id);
    const service: u6 = @truncate(id >> 24);

    const psci_version = 0;
    const cpuon = 3;
    const shutdown = 8;

    lib.print("handle smc, sv: {x}, fn: {x}\n", .{ service, function });
    switch (service) {
        4 => switch (function) { // PSCI is part of Standard service(4)
            psci_version => self.x[0] = (1 << 16), // PSCI version 1.0
            cpuon => {
                const target_cpu_mpidr = self.x[1];
                const entry_addr = self.x[2];
                const context_id = self.x[3];
                onlined_cpus += 1;

                lib.print("Prepare to power on CPU{} (MPIDR: {x}), entry_addr: {x}, context_id: {x}\n", .{ onlined_cpus, target_cpu_mpidr, entry_addr, context_id });
                start_core_id = onlined_cpus;
                vcpus[onlined_cpus].x[0] = context_id;
                vcpus[onlined_cpus].x[ELR] = entry_addr;
                vcpus[onlined_cpus].x[SPSR] = (1 << 9) | (1 << 8) | (1 << 7) | (1 << 6) | 5; // EL1h
                const secondary_start_pa: u64 = va2pa(@intFromPtr(&secondary_start));
                psci_call(self.x[0], self.x[1], secondary_start_pa, self.x[3]);
                lib.print("Waiting\n", .{});
                while (start_core_id != 0) {}
                lib.print("Done\n", .{});

                self.x[0] = 0;
            },
            shutdown => {
                lib.print("shutdown vm\n", .{});
                self.callstack();
                lib.spin();
            },
            else => self.x[0] = 0xffff_ffff, // NOT SUPPORT
        },

        else => {
            @panic("TODO");
        },
    }

    // advance PC
    self.x[ELR] += 4;
}

fn psci_call(_: u64, _: u64, _: u64, _: u64) callconv(.C) void {
    asm volatile ("smc #0");
}

pub fn handle_irq(_: *Self) void {
    while (true) {
        const v = gic.ack_irq();
        const irq = v & 0x3ff;

        if (irq == 1023) { // no more pending irqs
            break;
        }

        //if (irq != 0x1b) lib.print("get irq {x} on CPU{}\n", .{ v, lib.cpu_idx() });

        gic.inject_virq(v);
    }
}

pub fn callstack(self: *const Self) void {
    const el = (self.x[SPSR] >> 2) & 3;

    var lr: u64 = undefined;
    var fp = self.x[ELR];

    asm volatile (
        \\ cmp xzr, %[el]
        \\ bne 998f
        \\ at S12E0R, %[fp]
        \\ b 999f
        \\ 998:
        \\ at S12E1R, %[fp]
        \\ 999:
        \\ mrs %[lr], par_el1
        : [lr] "=r" (lr),
        : [el] "r" (el),
          [fp] "r" (fp),
        : "memory"
    );
    lib.print("EL{}, ELR: {x}\n", .{ el, self.x[ELR] });
    if (lr & 1 == 0) {
        fp = (((lr >> 12) & 0xfffffffff) << 12) | (fp & 0xfff);
        const ptr = lib.emergency_map(fp);
        for (0..4) |i| {
            lib.print("{x:02}\n", .{ptr[i]});
        }
    }

    fp = self.x[29];

    while (fp > 0) {
        asm volatile (
            \\ cmp xzr, %[el]
            \\ bne 998f
            \\ at S12E0R, %[fp]
            \\ b 999f
            \\ 998:
            \\ at S12E1R, %[fp]
            \\ 999:
            \\ mrs %[lr], par_el1
            : [lr] "=r" (lr),
            : [el] "r" (el),
              [fp] "r" (fp),
            : "memory"
        );

        if (lr & 1 == 1) {
            lib.print("translate failure, par_el1: {x}\n", .{lr});
            break;
        }

        fp = (((lr >> 12) & 0xfffffffff) << 12) | (fp & 0xfff);
        const ptr: *const [2]u64 = @alignCast(@ptrCast(lib.emergency_map(fp)));
        asm volatile (
            \\ at S1E2R, %[fp]
            \\ mrs %[lr], par_el1
            : [lr] "=r" (lr),
            : [fp] "r" (fp),
        );
        if (lr & 1 == 1) {
            lib.print("hypervisor translate failure , fp: {x}, par_el1: {x}\n", .{ fp, lr });
            break;
        }

        if (ptr[1] != 0) {
            lib.print("{x}\n", .{ptr[1]});
        }
        fp = ptr[0];
    }
}
