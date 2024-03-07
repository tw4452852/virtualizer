const Self = @This();

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

    while (true) {}
}

pub fn enable() void {
    const hcr_twi = (0 << 13);
    const hcr_twe = (0 << 14);
    const hcr_vm = (1 << 0);
    const hcr_rw = (1 << 31);
    const hcr_amo = (0 << 5); // TODO
    const hcr_imo = (0 << 4); // TODO
    const hcr_fmo = (0 << 3); // TODO
    const hcr_tsc = (0 << 19); // TODO

    const hcr: u64 = hcr_twi | hcr_twe | hcr_vm | hcr_rw | hcr_amo | hcr_imo | hcr_fmo | hcr_tsc;
    asm volatile (
        \\ msr hcr_el2, %[hcr]
        \\ isb
        :
        : [hcr] "r" (hcr),
    );
}
