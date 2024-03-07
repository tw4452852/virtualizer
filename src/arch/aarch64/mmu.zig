const std = @import("std");
const root = @import("root.zig");
const testing = std.testing;
const is_test = @import("builtin").is_test;

const pgd_bits = 9;
const pud_bits = 9;
const pmd_bits = 9;
const page_bits = 12;
const pgd_shift = (pgd_bits + pud_bits + pmd_bits + page_bits);
const pgd_size = 1 << pgd_shift;
const pgd_mask = (1 << pgd_bits) - 1;
const pud_shift = (pud_bits + pmd_bits + page_bits);
const pud_size = 1 << pud_shift;
const pud_mask = (1 << pud_bits) - 1;
const pmd_shift = (pmd_bits + page_bits);
const pmd_size = 1 << pmd_shift;
const pmd_mask = (1 << pmd_bits) - 1;
const page_shift = (page_bits);
const page_size = 1 << page_shift;
const page_mask = (1 << page_bits) - 1;

const num_pages = 64;
var pages: [num_pages * page_size]u8 align(page_size) = undefined;
var freed = std.StaticBitSet(num_pages).initFull();

// DEVICE_nGnRnE      000     0b00000000
// DEVICE_nGnRE       001     0b00000100
// DEVICE_GRE         010     0b00001100
// NORMAL_NC          011     0b01000100
// NORMAL             100     0b11111111
const MT_DEVICE_nGnRnE = 0;
const MT_DEVICE_nGnRE = 1;
const MT_DEVICE_GRE = 2;
const MT_NORMAL_NC = 3;
const MT_NORMAL = 4;
const mair: u64 = (0b00000000 << (MT_DEVICE_nGnRnE * 8)) |
    (0b00000100 << (MT_DEVICE_nGnRE * 8)) |
    (0b00001100 << (MT_DEVICE_GRE * 8)) |
    (0b01000100 << (MT_NORMAL_NC * 8)) |
    (0b11111111 << (MT_NORMAL * 8));

const TCR_T0SZ48 = (64 - 48);
const TCR_IRGN0_WBWC = (1 << 8);
const TCR_ORGN0_WBWC = (1 << 10);
const TCR_SH0_ISH = (3 << 12);
const TCR_TG0_4K = (0 << 14);
const TCR_EL2_RES1 = (1 << 23) | (1 << 31);
const TCR_PS_40BIT = (2 << 16);

const tcr: u64 = TCR_T0SZ48 | TCR_IRGN0_WBWC | TCR_ORGN0_WBWC | TCR_SH0_ISH | TCR_TG0_4K | TCR_EL2_RES1 | TCR_PS_40BIT;

fn print(comptime fmt: []const u8, args: anytype) void {
    if (is_test) std.debug.print(fmt, args) else root.print(fmt, args);
}

pub fn enable() void {
    asm volatile (
        \\ msr mair_el2, %[mair]
        \\ msr tcr_el2, %[tcr]
        \\ isb
        \\ adrp x11, pgd
        \\ msr ttbr0_el2, x11
        \\ isb
        \\ dsb sy
        \\ tlbi alle2
        \\ tlbi vmalls12e1
        \\ dsb sy
        \\ tlbi vmalle1is
        \\ dsb ish
        \\ isb
        \\ ic ialluis
        \\ dsb sy
        \\ isb
        \\ mrs x11, sctlr_el2
        \\ orr x11, x11, #(1 << 0) // SCTLR_EL2_M
        \\ orr x11, x11, #(1 << 2) // SCTLR_EL2_C
        \\ orr x11, x11, #(1 << 12) // SCTLR_EL2_I
        \\ msr sctlr_el2, x11
        \\ isb
        :
        : [mair] "{x10}" (mair),
          [tcr] "{x11}" (tcr),
        : "memory"
    );
}

pub fn disable() void {
    asm volatile (
        \\ dsb sy
        \\ isb
        \\ mrs x1, sctlr_el2
        \\ bic x1, x1, #(1 << 0) // SCTLR_EL2_M
        \\ bic x1, x1, #(1 << 2) // SCTLR_EL2_C
        \\ bic x1, x1, #(1 << 12) // SCTLR_EL2_I
        \\ msr sctlr_el2, x1
        \\ isb
        ::: "memory", "x1");
}

inline fn pte_is_valid(pte: u64) bool {
    return pte & 1 == 1;
}

inline fn ptrFromPte(T: type, pte: u64) T {
    var v: u64 = pte & ~@as(u64, page_mask);
    if (!is_test) {
        v = pa2va(v);
    }
    return @ptrFromInt(v);
}

inline fn pteFromPtr(ptr: *anyopaque) u64 {
    var v: u64 = @intFromPtr(ptr) & ~@as(u64, page_mask);
    if (!is_test) {
        v = va2pa(v);
    }
    return v;
}

const pte_access = (1 << 10);
const pte_innser_sharable = (3 << 8);
const pte_execute_never = (3 << 53);
pub fn map_normal(pgd: *[512]u64, pa: u64, va: u64, len: u64) ?[*]u8 {
    return map(pgd, pa, va, len, pte_innser_sharable | pte_access | (MT_NORMAL << 2));
}

pub fn map_device(pgd: *[512]u64, pa: u64, va: u64, len: u64) ?[*]u8 {
    return map(pgd, pa, va, len, pte_execute_never | pte_innser_sharable | pte_access | (MT_NORMAL_NC << 2));
}

pub fn map_normal_s2(pgd: *[512]u64, pa: u64, va: u64, len: u64) void {
    _ = map(pgd, pa, va, len, pte_innser_sharable | pte_access | (MT_NORMAL << 2) | (3 << 6)); // mapped as RW
}

extern fn va2pa(va: u64) u64;
extern fn pa2va(pa: u64) u64;

fn map(pgd: *[512]u64, pa: u64, va: u64, len: u64, mem_attr: u64) ?[*]u8 {
    var unmapped_va = va;
    var unmapped_pa = pa;
    var unmapped_len = len;

    print("map pgd: {x}, va: {x}, pa: {x}, len: {x}\n", .{ @intFromPtr(pgd), va, pa, len });
    if (!std.mem.isAligned(pa, page_size) or !std.mem.isAligned(va, page_size) or !std.mem.isAligned(len, page_size)) {
        print("invalid alignment, skip\n", .{});
        return null;
    }

    defer if (!is_test) asm volatile ("dsb sy" ::: "memory");
    for ((unmapped_va >> pgd_shift) & pgd_mask..512) |pgd_idx| {
        if (!pte_is_valid(pgd[pgd_idx])) {
            if (freed.toggleFirstSet()) |i| {
                const page: *[page_size]u8 = @ptrCast(&pages[i * page_size]);
                @memset(page, 0);
                pgd[pgd_idx] = pteFromPtr(page) | (1 << 0) | (1 << 1);
            } else {
                print("not enough freed pages to make up pgd table entry\n", .{});
                root.spin();
            }
        }

        const pud = ptrFromPte(*[512]u64, pgd[pgd_idx]);
        print("pud: {x} at {} of pgd\n", .{ va2pa(@intFromPtr(pud)), pgd_idx });
        for ((unmapped_va >> pud_shift) & pud_mask..512) |pud_idx| {
            if (!pte_is_valid(pud[pud_idx])) {
                if (freed.toggleFirstSet()) |i| {
                    const page: *[page_size]u8 = @ptrCast(&pages[i * page_size]);
                    @memset(page, 0);
                    pud[pud_idx] = pteFromPtr(page) | (1 << 0) | (1 << 1);
                } else {
                    print("not enough freed pages to make up pud table entry\n", .{});
                    root.spin();
                }
            }

            const pmd = ptrFromPte(*[512]u64, pud[pud_idx]);
            print("pmd: {x} at {} of pud\n", .{ va2pa(@intFromPtr(pmd)), pud_idx });
            for ((unmapped_va >> pmd_shift) & pmd_mask..512) |pmd_idx| {
                if (!pte_is_valid(pmd[pmd_idx])) {
                    if (unmapped_len >= pmd_size and std.mem.isAligned(unmapped_va, pmd_size) and std.mem.isAligned(unmapped_pa, pmd_size)) {
                        // use block mapping directly
                        pmd[pmd_idx] = unmapped_pa | (1 << 0) | mem_attr;
                        //print("mapped {x} {x} sized page at {} of pmd\n", .{ unmapped_pa, pmd_size, pmd_idx });
                        unmapped_va += pmd_size;
                        unmapped_pa += pmd_size;
                        unmapped_len -|= pmd_size;
                        if (unmapped_len == 0) return @ptrFromInt(va);
                        continue;
                    } else {
                        if (freed.toggleFirstSet()) |i| {
                            const page: *[page_size]u8 = @ptrCast(&pages[i * page_size]);
                            @memset(page, 0);
                            pmd[pmd_idx] = pteFromPtr(page) | (1 << 0) | (1 << 1);
                        } else {
                            print("not enough freed pages to make up pmd table entry\n", .{});
                            root.spin();
                        }
                    }
                }

                if (pmd[pmd_idx] & (1 << 1) != 0) {
                    // page table
                    const pt = ptrFromPte(*[512]u64, pmd[pmd_idx]);
                    print("pt: {x} at {} of pmd\n", .{ va2pa(@intFromPtr(pt)), pmd_idx });
                    for ((unmapped_va >> page_shift) & ((1 << 9) - 1)..512) |pt_idx| {
                        pt[pt_idx] = (unmapped_pa & ~@as(u64, page_size - 1)) | (1 << 0) | (1 << 1) | mem_attr;
                        //print("mapped {x} {x} sized page at {} of pt\n", .{ unmapped_pa, page_size, pt_idx });

                        unmapped_va += page_size;
                        unmapped_pa += page_size;
                        unmapped_len -|= page_size;
                        if (unmapped_len == 0) return @ptrFromInt(va);
                    }
                } else {
                    // already mapped in a block, check whether it contains us
                    const previous_mapped_pa = pmd[pmd_idx] & ~@as(u64, pmd_size - 1);
                    if (unmapped_pa >= previous_mapped_pa and previous_mapped_pa < previous_mapped_pa + pmd_size) {
                        const size = previous_mapped_pa + pmd_size - unmapped_pa;
                        unmapped_va += size;
                        unmapped_pa += size;
                        unmapped_len -|= size;
                        if (unmapped_len == 0) return @ptrFromInt(va);
                    } else {
                        print("conflict mapping, va: {x}, pa: {x}, previous_pa: {x}\n", .{ unmapped_va, unmapped_pa, previous_mapped_pa });
                        root.spin();
                    }
                }
            }
        }
    }

    return @ptrFromInt(va);
}

pub fn unmap(pgd: *[512]u64, va: u64, len: u64) void {
    var unmapped_va = va;

    print("unmap va: {x}, len: {x}\n", .{ va, len });
    if (!std.mem.isAligned(va, page_size) or !std.mem.isAligned(len, page_size)) {
        print("invalid alignment, skip\n", .{});
        return;
    }

    defer if (!is_test) asm volatile ("dsb sy" ::: "memory");
    for ((unmapped_va >> pgd_shift) & pgd_mask..512) |pgd_idx| {
        if (pte_is_valid(pgd[pgd_idx])) {
            const pud = ptrFromPte(*[512]u64, pgd[pgd_idx]);
            for ((unmapped_va >> pud_shift) & pud_mask..512) |pud_idx| {
                if (pte_is_valid(pud[pud_idx])) {
                    const pmd = ptrFromPte(*[512]u64, pud[pud_idx]);
                    for ((unmapped_va >> pmd_shift) & pmd_mask..512) |pmd_idx| {
                        if (pte_is_valid(pmd[pmd_idx])) {
                            const pte = pmd[pmd_idx];

                            if (pte & (1 << 1) == 0) {
                                // block page, mark as invalid
                                pmd[pmd_idx] &= ~@as(u64, 1);
                                unmapped_va = (unmapped_va & ~@as(u64, (pmd_size - 1))) + pmd_size;
                                if (unmapped_va >= va + len) return;
                            } else {
                                const pt: *[512]u64 = @ptrFromInt(pte & ~@as(u64, page_mask));
                                for ((unmapped_va >> page_shift) & ((1 << 9) - 1)..512) |pt_idx| {
                                    pt[pt_idx] &= ~@as(u64, 1);
                                    unmapped_va += page_size;
                                    if (unmapped_va >= va + len) return;
                                }
                            }
                        } else {
                            unmapped_va = (unmapped_va & ~@as(u64, (pmd_size - 1))) + pmd_size;
                            if (unmapped_va >= va + len) return;
                        }
                    }
                } else {
                    unmapped_va = (unmapped_va & ~@as(u64, pud_size - 1)) + pud_size;
                    if (unmapped_va >= va + len) return;
                }
            }
        } else {
            unmapped_va = (unmapped_va & ~@as(u64, pgd_size - 1)) + pgd_size;
            if (unmapped_va >= va + len) return;
        }
    }
}

test "map block pages" {
    const pa_base = (2 << 20);
    const va_base = (1 << 30);
    const n = 2;

    var pgd: [512]u64 align(1 << 12) = .{0} ** 512;

    defer @memset(&pages, 0);
    const p = map(&pgd, pa_base, va_base, pmd_size * n, 0);
    try testing.expect(p != null);

    for (0..n) |i| {
        const va = va_base + pmd_size * i;
        const pa = pa_base + pmd_size * i;
        const pgd_idx = (va >> pgd_shift) & 511;
        const pud_idx = (va >> pud_shift) & 511;
        const pmd_idx = (va >> pmd_shift) & 511;

        const pgde = pgd[pgd_idx];
        try testing.expect(pte_is_valid(pgde));
        const pud = ptrFromPte(*[512]u64, pgde);
        const pude = pud[pud_idx];
        try testing.expect(pte_is_valid(pude));
        const pmd = ptrFromPte(*[512]u64, pude);
        const pmde = pmd[pmd_idx];
        try testing.expect(pte_is_valid(pmde));
        const got: u64 = @intFromPtr(ptrFromPte(*u8, pmde));
        try testing.expectEqual(pa, got);
    }
}

test "unmap block pages" {
    const pa_base = (2 << 20);
    const va_base = (1 << 30);
    const n = 2;

    var pgd: [512]u64 align(1 << 12) = .{0} ** 512;

    defer @memset(&pages, 0);
    const p = map(&pgd, pa_base, va_base, pmd_size * n, 0);
    try testing.expect(p != null);
    unmap(&pgd, va_base, pmd_size * n);

    for (0..n) |i| {
        const va = va_base + pmd_size * i;
        const pgd_idx = (va >> pgd_shift) & 511;
        const pud_idx = (va >> pud_shift) & 511;
        const pmd_idx = (va >> pmd_shift) & 511;

        const pgde = pgd[pgd_idx];
        try testing.expect(pte_is_valid(pgde));
        const pud = ptrFromPte(*[512]u64, pgde);
        const pude = pud[pud_idx];
        try testing.expect(pte_is_valid(pude));
        const pmd = ptrFromPte(*[512]u64, pude);
        const pmde = pmd[pmd_idx];
        try testing.expect(!pte_is_valid(pmde));
    }
}

test "map small pages" {
    const pa_base = (2 << 20);
    const va_base = (1 << 30);
    const n = 2;

    var pgd: [512]u64 align(1 << 12) = .{0} ** 512;

    defer @memset(&pages, 0);
    const p = map(&pgd, pa_base, va_base, page_size * n, 0);
    try testing.expect(p != null);

    for (0..n) |i| {
        const va = va_base + page_size * i;
        const pa = pa_base + page_size * i;
        const pgd_idx = (va >> pgd_shift) & 511;
        const pud_idx = (va >> pud_shift) & 511;
        const pmd_idx = (va >> pmd_shift) & 511;
        const pt_idx = (va >> page_shift) & 511;

        const pgde = pgd[pgd_idx];
        try testing.expect(pte_is_valid(pgde));
        const pud = ptrFromPte(*[512]u64, pgde);
        const pude = pud[pud_idx];
        try testing.expect(pte_is_valid(pude));
        const pmd = ptrFromPte(*[512]u64, pude);
        const pmde = pmd[pmd_idx];
        try testing.expect(pte_is_valid(pmde));
        const pt = ptrFromPte(*[512]u64, pmde);
        const pte = pt[pt_idx];
        try testing.expect(pte_is_valid(pte));
        const got: u64 = @intFromPtr(ptrFromPte(*u8, pte));
        try testing.expectEqual(pa, got);
    }
}

test "unmap small pages" {
    const pa_base = (2 << 20);
    const va_base = (1 << 30);
    const n = 2;

    var pgd: [512]u64 align(1 << 12) = .{0} ** 512;

    defer @memset(&pages, 0);
    const p = map(&pgd, pa_base, va_base, page_size * n, 0);
    try testing.expect(p != null);
    unmap(&pgd, va_base, page_size * n);

    for (0..n) |i| {
        const va = va_base + page_size * i;
        const pgd_idx = (va >> pgd_shift) & 511;
        const pud_idx = (va >> pud_shift) & 511;
        const pmd_idx = (va >> pmd_shift) & 511;
        const pt_idx = (va >> page_shift) & 511;

        const pgde = pgd[pgd_idx];
        try testing.expect(pte_is_valid(pgde));
        const pud = ptrFromPte(*[512]u64, pgde);
        const pude = pud[pud_idx];
        try testing.expect(pte_is_valid(pude));
        const pmd = ptrFromPte(*[512]u64, pude);
        const pmde = pmd[pmd_idx];
        try testing.expect(pte_is_valid(pmde));
        const pt = ptrFromPte(*[512]u64, pmde);
        const pte = pt[pt_idx];
        try testing.expect(!pte_is_valid(pte));
    }
}

test "map hybrid pages" {
    // 1 small page + 1 block page + 1 small page
    const pa_base = (2 << 20) - (1 << 12);
    const va_base = (1 << 30) - (1 << 12);
    const len = (1 << 12) + (2 << 20) + (1 << 12);

    var pgd: [512]u64 align(1 << 12) = .{0} ** 512;

    defer @memset(&pages, 0);
    const p = map(&pgd, pa_base, va_base, len, 0);
    try testing.expect(p != null);

    // first small page
    var va: u64 = va_base;
    var pa: u64 = pa_base;
    var pgd_idx: usize = (va >> pgd_shift) & 511;
    var pud_idx: usize = (va >> pud_shift) & 511;
    var pmd_idx: usize = (va >> pmd_shift) & 511;
    var pt_idx: usize = (va >> page_shift) & 511;

    var pgde = pgd[pgd_idx];
    try testing.expect(pte_is_valid(pgde));
    var pud = ptrFromPte(*[512]u64, pgde);
    var pude = pud[pud_idx];
    try testing.expect(pte_is_valid(pude));
    var pmd = ptrFromPte(*[512]u64, pude);
    var pmde = pmd[pmd_idx];
    try testing.expect(pte_is_valid(pmde));
    var pt = ptrFromPte(*[512]u64, pmde);
    var pte = pt[pt_idx];
    try testing.expect(pte_is_valid(pte));
    var got: u64 = @intFromPtr(ptrFromPte(*u8, pte));
    try testing.expectEqual(pa, got);

    // block page
    va += page_size;
    pa += page_size;
    pgd_idx = (va >> pgd_shift) & 511;
    pud_idx = (va >> pud_shift) & 511;
    pmd_idx = (va >> pmd_shift) & 511;
    pt_idx = (va >> page_shift) & 511;

    pgde = pgd[pgd_idx];
    try testing.expect(pte_is_valid(pgde));
    pud = ptrFromPte(*[512]u64, pgde);
    pude = pud[pud_idx];
    try testing.expect(pte_is_valid(pude));
    pmd = ptrFromPte(*[512]u64, pude);
    pmde = pmd[pmd_idx];
    try testing.expect(pte_is_valid(pmde));
    got = @intFromPtr(ptrFromPte(*u8, pmde));
    try testing.expectEqual(pa, got);

    // small page
    va += pmd_size;
    pa += pmd_size;
    pgd_idx = (va >> pgd_shift) & 511;
    pud_idx = (va >> pud_shift) & 511;
    pmd_idx = (va >> pmd_shift) & 511;
    pt_idx = (va >> page_shift) & 511;

    pgde = pgd[pgd_idx];
    try testing.expect(pte_is_valid(pgde));
    pud = ptrFromPte(*[512]u64, pgde);
    pude = pud[pud_idx];
    try testing.expect(pte_is_valid(pude));
    pmd = ptrFromPte(*[512]u64, pude);
    pmde = pmd[pmd_idx];
    try testing.expect(pte_is_valid(pmde));
    got = @intFromPtr(ptrFromPte(*u8, pmde));
    pt = ptrFromPte(*[512]u64, pmde);
    pte = pt[pt_idx];
    try testing.expect(pte_is_valid(pte));
    got = @intFromPtr(ptrFromPte(*u8, pte));
    try testing.expectEqual(pa, got);
}

test "unmap hybrid pages" {
    // 1 small page + 1 block page + 1 small page
    const pa_base = (2 << 20) - (1 << 12);
    const va_base = (1 << 30) - (1 << 12);
    const len = (1 << 12) + (2 << 20) + (1 << 12);

    var pgd: [512]u64 align(1 << 12) = .{0} ** 512;

    defer @memset(&pages, 0);
    const p = map(&pgd, pa_base, va_base, len, 0);
    try testing.expect(p != null);
    unmap(&pgd, @intFromPtr(p), len);

    // first small page
    var va: u64 = va_base;
    var pa: u64 = pa_base;
    var pgd_idx: usize = (va >> pgd_shift) & 511;
    var pud_idx: usize = (va >> pud_shift) & 511;
    var pmd_idx: usize = (va >> pmd_shift) & 511;
    var pt_idx: usize = (va >> page_shift) & 511;

    var pgde = pgd[pgd_idx];
    try testing.expect(pte_is_valid(pgde));
    var pud = ptrFromPte(*[512]u64, pgde);
    var pude = pud[pud_idx];
    try testing.expect(pte_is_valid(pude));
    var pmd = ptrFromPte(*[512]u64, pude);
    var pmde = pmd[pmd_idx];
    try testing.expect(pte_is_valid(pmde));
    var pt = ptrFromPte(*[512]u64, pmde);
    var pte = pt[pt_idx];
    try testing.expect(!pte_is_valid(pte));

    // block page
    va += page_size;
    pa += page_size;
    pgd_idx = (va >> pgd_shift) & 511;
    pud_idx = (va >> pud_shift) & 511;
    pmd_idx = (va >> pmd_shift) & 511;
    pt_idx = (va >> page_shift) & 511;

    pgde = pgd[pgd_idx];
    try testing.expect(pte_is_valid(pgde));
    pud = ptrFromPte(*[512]u64, pgde);
    pude = pud[pud_idx];
    try testing.expect(pte_is_valid(pude));
    pmd = ptrFromPte(*[512]u64, pude);
    pmde = pmd[pmd_idx];
    try testing.expect(!pte_is_valid(pmde));

    // small page
    va += pmd_size;
    pa += pmd_size;
    pgd_idx = (va >> pgd_shift) & 511;
    pud_idx = (va >> pud_shift) & 511;
    pmd_idx = (va >> pmd_shift) & 511;
    pt_idx = (va >> page_shift) & 511;

    pgde = pgd[pgd_idx];
    try testing.expect(pte_is_valid(pgde));
    pud = ptrFromPte(*[512]u64, pgde);
    pude = pud[pud_idx];
    try testing.expect(pte_is_valid(pude));
    pmd = ptrFromPte(*[512]u64, pude);
    pmde = pmd[pmd_idx];
    try testing.expect(pte_is_valid(pmde));
    pt = ptrFromPte(*[512]u64, pmde);
    pte = pt[pt_idx];
    try testing.expect(!pte_is_valid(pte));
}
