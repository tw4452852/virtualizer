const std = @import("std");
const VCPU = @import("vcpu.zig");
pub const GIC = @import("gic.zig");
pub const mmu = @import("mmu.zig");
const c = @cImport({
    @cInclude("libfdt.h");
    @cInclude("libfdt_env.h");
});
const serial = @import("serial.zig");

pub fn print(comptime fmt: []const u8, args: anytype) void {
    serial.print(fmt, args);
}

pub fn spin() noreturn {
    print("spinning...\n", .{});
    while (true) {}
}

pub fn get_tpidr_el2() u64 {
    var tpidr: u64 = undefined;

    asm volatile ("mrs %[tpidr], tpidr_el2"
        : [tpidr] "=r" (tpidr),
    );
    return tpidr;
}

pub fn cpu_idx() usize {
    return get_tpidr_el2() & 0xfff;
}

extern fn va2pa(va: u64) u64;
extern var dtb_pa: u64;
extern var start_pa: u64;
extern var end_pa: u64;
extern var pgd: [512]u64 align(1 << 12);
extern var vm_pgd: [512]u64 align(1 << 12);
extern var vcpus: *[32]VCPU;
extern var gic: *GIC;

const ImageHeader = extern struct {
    code0: u32,
    code1: u32,
    text_offset: u64,
    image_size: u64,
    flags: u64,
    res2: u64,
    res3: u64,
    res4: u64,
    magic: u32,
    res5: u32,
};
const arm64_magic: u32 = @bitCast(@as([4]u8, "ARM\x64".*));

fn get_kernel_image_len(p: [*c]u8) ?u64 {
    const hdr: *align(1) ImageHeader = @ptrCast(p);
    return if (hdr.magic == arm64_magic) std.mem.littleToNative(u64, hdr.image_size) else null;
}

pub fn start_vm(kernel_image: []const u8) noreturn {
    var image_end_va: u64 = undefined;
    var image_start_va: u64 = undefined;

    asm volatile (
        \\ adrp %[start], _start
        \\ adrp %[end], _end
        \\ add %[end], %[end], #:lo12:_end
        : [end] "=r" (image_end_va),
          [start] "=r" (image_start_va),
    );
    const dtb_va = std.mem.alignForward(u64, image_end_va, (2 << 20));
    const dtb_len = (2 << 20);
    const dtb = mmu.map_normal(&pgd, dtb_pa, dtb_va, dtb_len).?;

    print("start primary vcpu, kernel: {x}@{x}, dtb: {x}\n", .{ kernel_image.len, @intFromPtr(kernel_image.ptr), @intFromPtr(dtb) });

    var ret = c.fdt_open_into(dtb, dtb, dtb_len);
    if (ret != 0) {
        print("failed to open dtb: {}\n", .{ret});
        spin();
    }

    const aligned_end_pa = std.mem.alignForward(u64, end_pa, std.heap.page_size_min);
    ret = c.fdt_add_mem_rsv(dtb, start_pa, aligned_end_pa - start_pa);
    if (ret != 0) {
        print("failed to add resv for image range ({x} - {x}): {}\n", .{ start_pa, aligned_end_pa, ret });
        spin();
    }
    print("reserve image range: {x} - {x}\n", .{ start_pa, aligned_end_pa });
    ret = c.fdt_pack(dtb);
    if (ret != 0) {
        print("failed to pack dtb: {}\n", .{ret});
        spin();
    }

    const kernel_va = dtb_va + dtb_len;
    const kernel_pa = dtb_pa + dtb_len;
    const kernel_len = std.mem.alignForward(u64, kernel_image.len, (2 << 20));
    const kernel = mmu.map_normal(&pgd, kernel_pa, kernel_va, kernel_len).?;
    @memcpy(kernel[0..kernel_image.len], kernel_image);

    const real_kerne_len: u64 = if (get_kernel_image_len(kernel)) |len| len else kernel_len;
    print("kernel is loaded at {x}, size: {x}\n", .{ kernel_pa, real_kerne_len });

    mmu.map_normal_s2(&vm_pgd, kernel_pa, kernel_pa, real_kerne_len);
    // map memory for VM
    const mem_node_offset = c.fdt_path_offset(dtb, "/memory");
    if (mem_node_offset < 0) {
        print("failed to find memory node: {}\n", .{mem_node_offset});
        spin();
    }
    var len: c_int = undefined;
    const pp = c.fdt_get_property(dtb, mem_node_offset, "reg", &len).?;
    for (0..@as(c_uint, @bitCast(len)) / 16) |i| {
        @setRuntimeSafety(false);
        const data = pp.*.data();

        const addr = c.fdt64_to_cpu(@as(*const u64, @ptrCast(@alignCast(data + i * 16))).*);
        const size = c.fdt64_to_cpu(@as(*const u64, @ptrCast(@alignCast(data + i * 16 + 8))).*);
        print("memory {}: addr: {x}, size: {x}\n", .{ i, addr, size });
        mmu.map_normal_s2(&vm_pgd, addr, addr, size);
    }

    if (!gic.init(dtb)) {
        print("failed to initialize GIC\n", .{});
    }

    ret = c.fdt_pack(dtb);
    if (ret != 0) {
        print("failed to pack dtb: {}\n", .{ret});
        spin();
    }
    vcpus[0].enable();
    vcpus[0].x[0] = dtb_pa;
    vcpus[0].x[VCPU.ELR] = kernel_pa;
    vcpus[0].x[VCPU.SPSR] = (1 << 9) | (1 << 8) | (1 << 7) | (1 << 6) | 5; // EL1h
    vcpus[0].restore();

    spin();
}

pub fn emergency_map(paddr: u64) [*]u8 {
    const sz = (1 << 12);
    const align_paddr = std.mem.alignBackward(u64, paddr, sz);
    return mmu.map_normal(&pgd, align_paddr, align_paddr, sz).? + (paddr - align_paddr);
}
