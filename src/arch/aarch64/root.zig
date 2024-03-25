const std = @import("std");
const VCPU = @import("vcpu.zig");
pub const GIC2 = @import("gic2.zig");
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
    while (true) {}
}

pub fn cpu_idx() usize {
    var tpidr: u64 = undefined;

    asm volatile ("mrs %[tpidr], tpidr_el2"
        : [tpidr] "=r" (tpidr),
    );

    return tpidr & 0xfff;
}

extern fn va2pa(va: u64) u64;
extern var dtb_pa: u64;
extern var start_pa: u64;
extern var end_pa: u64;
extern var pgd: [512]u64 align(1 << 12);
extern var vm_pgd: [512]u64 align(1 << 12);
extern var vcpus: *[32]VCPU;
extern var gic2: *GIC2;

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

    const aligned_end_pa = std.mem.alignForward(u64, end_pa, std.mem.page_size);
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
    for (0..kernel_image.len) |i| {
        kernel[i] = kernel_image[i];
    }
    const real_kerne_len: u64 = std.mem.littleToNative(u64, @as(*const u64, @alignCast(@ptrCast(kernel + 16))).*);
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

        const addr = c.fdt64_to_cpu(@as(*const u64, @alignCast(@ptrCast(data + i * 16))).*);
        const size = c.fdt64_to_cpu(@as(*const u64, @alignCast(@ptrCast(data + i * 16 + 8))).*);
        print("memory {}: addr: {x}, size: {x}\n", .{ i, addr, size });
        mmu.map_normal_s2(&vm_pgd, addr, addr, size);
    }

    if (!gic2.init(dtb)) {
        print("failed to initialize GICv2\n", .{});
        spin();
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
