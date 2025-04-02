const std = @import("std");
const serial = @import("serial.zig");
const lib = @import("root.zig");
const mmu = @import("mmu.zig");
const VCPU = @import("vcpu.zig");
const GIC2 = @import("gic2.zig");

const start_va = (2 << 20); // match with the definition of _start in linker.ld

const max_cpus = 32;
export var stack_bytes: [max_cpus][4 * 1024]u8 align(1 << 12) linksection(".bss") = undefined;
export var pgd: [512]u64 align(1 << 12) = .{0} ** 512;
export var vm_pgd: [512]u64 align(1 << 12) = .{0} ** 512;
var _vcpus: [max_cpus]VCPU = .{VCPU{}} ** max_cpus;
export const vcpus: *[max_cpus]VCPU = &_vcpus;
export var start_pa: u64 = 0;
export var end_pa: u64 = 0;
var _gicv2: GIC2 = .{};
export var gic2: *GIC2 = &_gicv2;

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    const first_trace_addr = ret_addr orelse @returnAddress();
    lib.print("Panic: {s}, ret_addr: {x}\n", .{ msg, first_trace_addr });
    while (true) {}
}

export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ adr x1, vector_table
        \\ msr vbar_el2, x1
        \\ adrp x1, stack_bytes
        \\ add x1, x1, #0x1000
        \\ msr tpidr_el2, x1
        \\ mov sp, x1
        \\ adr x1, dtb_pa
        \\ str x0, [x1]
        \\ mov x0, #0
        \\ b arch_init
        \\ b . // unreachable
        \\
        \\ .global dtb_pa
        \\ dtb_pa:
        \\ .quad 0
        \\
        \\ .align 7
        \\ .global vector_table
        \\ vector_table:
        \\ b exception_0 // Synchronous EL2t
        \\ .align 7
        \\ b exception_1 // IRQ EL2t
        \\ .align 7
        \\ b exception_2 // FIQ EL2t
        \\ .align 7
        \\ b exception_3 // SError EL2t
        \\ .align 7
        \\ b exception_4 // Synchronous EL2h
        \\ .align 7
        \\ b exception_5 // IRQ EL2h
        \\ .align 7
        \\ b exception_6 // FIQ EL2h
        \\ .align 7
        \\ b exception_7 // SError EL2h
        \\ .align 7
        \\ b exception_8 // Synchronous 64bit lower EL
        \\ .align 7
        \\ b exception_9 // IRQ 64bit lower EL
        \\ .align 7
        \\ b exception_10 // FIQ 64bit lower EL
        \\ .align 7
        \\ b exception_11 // SError 64bit lower EL
        \\ .align 7
        \\ b exception_12 // Synchronous 32bit lower EL
        \\ .align 7
        \\ b exception_13 // IRQ 32bit lower EL
        \\ .align 7
        \\ b exception_14 // FIQ 32bit lower EL
        \\ .align 7
        \\ b exception_15 // SError 32bit lower EL
    );
}

export fn secondary_start() callconv(.Naked) noreturn {
    asm volatile (
        \\ msr spsel, #1
        \\ adr x1, vector_table
        \\ msr vbar_el2, x1
        \\ adr x0, start_core_id
        \\ ldr x0, [x0]
        \\ adrp x1, stack_bytes
        \\ add x1, x1, x0, lsl #12
        \\ add x1, x1, #0x1000
        \\ mov sp, x1
        \\ add x1, x1, x0
        \\ msr tpidr_el2, x1
        \\ b secondary_init
        \\ b . // unreachable
        \\
        \\ .align 3
        \\ .global start_core_id
        \\ start_core_id:
        \\ .quad 0
    );
}

export fn secondary_init(cpu: u64) noreturn {
    lib.print("CPU{} up\n", .{cpu});

    arch_init(cpu);
}

comptime {
    for (0..16) |i| {
        const S = struct {
            fn exception_handler_begin() callconv(.Naked) noreturn {
                asm volatile (
                    \\ stp x0,  x1,  [sp, #16 * 0]
                    \\ stp x2,  x3,  [sp, #16 * 1]
                    \\ stp x4,  x5,  [sp, #16 * 2]
                    \\ stp x6,  x7,  [sp, #16 * 3]
                    \\ stp x8,  x9,  [sp, #16 * 4]
                    \\ stp x10, x11, [sp, #16 * 5]
                    \\ stp x12, x13, [sp, #16 * 6]
                    \\ stp x14, x15, [sp, #16 * 7]
                    \\ stp x16, x17, [sp, #16 * 8]
                    \\ stp x18, x19, [sp, #16 * 9]
                    \\ stp x20, x21, [sp, #16 * 10]
                    \\ stp x22, x23, [sp, #16 * 11]
                    \\ stp x24, x25, [sp, #16 * 12]
                    \\ stp x26, x27, [sp, #16 * 13]
                    \\ stp x28, x29, [sp, #16 * 14]
                    \\ mrs x21, sp_el0
                    \\ stp x30, x21, [sp, #16 * 15]
                    \\ mrs x22, elr_el2
                    \\ mrs x23, spsr_el2
                    \\ stp x22, x23, [sp, #16 * 16]
                    \\ mrs x0, tpidr_el2
                    \\ bic x0, x0, #0xfff
                    \\ mov sp, x0
                    \\ mov x0, %[i]
                    \\ b exception_handler
                    :
                    : [i] "i" (i),
                );

                while (true) {}
            }
        };

        @export(&S.exception_handler_begin, .{ .name = std.fmt.comptimePrint("exception_{}", .{i}), .linkage = .strong });
    }
}

export fn exception_handler(n: usize) noreturn {
    var esr: u64 = undefined;
    var far: u64 = undefined;
    var pc: u64 = undefined;
    var hpfar: u64 = undefined;
    var spsr: u64 = undefined;

    asm volatile (
        \\ mrs %[esr], esr_el2
        \\ mrs %[far], far_el2
        \\ mrs %[pc], elr_el2
        \\ mrs %[hpfar], hpfar_el2
        \\ mrs %[spsr], spsr_el2
        : [esr] "=r" (esr),
          [far] "=r" (far),
          [pc] "=r" (pc),
          [hpfar] "=r" (hpfar),
          [spsr] "=r" (spsr),
    );
    hpfar >>= 4;
    hpfar <<= 12;

    const el = (spsr >> 2) & 3;
    const cpu = lib.cpu_idx();
    //lib.print("exception {} taken from EL{} on CPU{}, esr: {x}, far: {x}, pc: {x}, hpfar: {x}\n", .{ n, el, cpu, esr, far, pc, hpfar });
    const ec = (esr >> 26) & 0x3f;
    const isv = (esr >> 24) & 1;
    if (el < 2) {
        if (n == 8 and ec == 0x24 and isv == 1) { // data abort
            mmu.map_normal_s2(&vm_pgd, hpfar, hpfar, (1 << 12));
            _vcpus[cpu].restore();
        } else if (n == 8 and ec == 0x17) { // SMC
            _vcpus[cpu].handle_smc();
            _vcpus[cpu].restore();
        } else if (n == 9) {
            _vcpus[cpu].handle_irq();
            _vcpus[cpu].restore();
        }
    }

    lib.spin();
}

export fn arch_init(cpu: u64) noreturn {
    lib.print("CPU{} enter arch init\n", .{cpu});
    defer lib.print("Exit arch exit\n", .{});

    ensure_current_in_el2();

    enable_mmu(cpu);

    asm volatile (
        \\ mov x0, %[cpu]
        \\ ldr x8, =stack_bytes
        \\ add x8, x8, x0, lsl #12
        \\ add x8, x8, #0x1000
        \\ mov sp, x8
        \\ ldr x8, =vector_table
        \\ msr vbar_el2, x8
        \\ ldr x8, =mmu_enabled
        \\ br x8
        :
        : [cpu] "r" (cpu),
    );

    lib.spin();
}

extern var start_core_id: u64;
export fn mmu_enabled(cpu: u64) noreturn {
    if (cpu == 0) {
        asm volatile ("b main");
    } else {
        start_core_id = 0;
        _vcpus[cpu].enable();
        _vcpus[cpu].restore();
    }
    lib.spin();
}

fn ensure_current_in_el2() void {
    var v: u64 = undefined;

    asm volatile (
        \\ mrs %[ret], CurrentEL
        : [ret] "={x0}" (v),
    );

    const cur_el = (v >> 2) & 0x3;
    if (cur_el != 2) {
        lib.print("Not in EL2, current EL: {x}\n", .{cur_el});
        while (true) {}
    }
}

var va_offset: i64 = 0;

export fn va2pa(va: u64) u64 {
    return @bitCast(@as(i64, @bitCast(va)) + va_offset);
}

export fn pa2va(pa: u64) u64 {
    return @bitCast(@as(i64, @bitCast(pa)) - va_offset);
}

fn enable_mmu(cpu: u64) void {
    lib.mmu.disable();

    if (cpu == 0) {
        asm volatile (
            \\ adr %[start], _start
            \\ adrp %[end], _end
            \\ add %[end], %[end], #:lo12:_end
            : [start] "=r" (start_pa),
              [end] "=r" (end_pa),
        );

        lib.print("real load range: {x}, end: {x}\n", .{ start_pa, end_pa });
        const len = std.mem.alignForward(u64, end_pa - start_pa, std.heap.page_size_min);
        add_identical_mapping();
        _ = lib.mmu.map_normal(&pgd, start_pa, start_va, len);
        _ = lib.mmu.map_device(&pgd, serial.base, serial.base, 0x1000);
        // must be put after mmu.map because it relies on va_offset
        va_offset = @as(i64, @bitCast(start_pa)) - start_va;

        asm volatile ("msr tpidr_el2, %[va]"
            :
            : [va] "r" (pa2va(@intFromPtr(&stack_bytes[0]) + 0x1000)),
        );
    }

    lib.mmu.enable();

    lib.print("MMU enabled\n", .{});
}

fn add_identical_mapping() void {
    const len = std.mem.alignForward(u64, end_pa - start_pa, std.heap.page_size_min);
    _ = lib.mmu.map_normal(&pgd, start_pa, start_pa, len); // temporary identical mapping, will be unmapped after MMU enable
}

fn remove_identical_mapping() void {
    if (va_offset == 0) {
        return;
    }

    const len = std.mem.alignForward(u64, end_pa - start_pa, std.mem.page_size);
    lib.mmu.unmap(&pgd, va2pa(start_va), len);
}
