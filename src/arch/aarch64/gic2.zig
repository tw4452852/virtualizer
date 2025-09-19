const c = @cImport({
    @cInclude("libfdt.h");
    @cInclude("libfdt_env.h");
});
const print = @import("serial.zig").print;
const mmu = @import("mmu.zig");

const Self = @This();
const VCPU_CTL = extern struct {
    hcr: u32,
    vtr: u32,
    vmcr: u32,
    res1: [1]u32,
    misr: u32,
    res2: [3]u32,
    eisr0: u32,
    eisr1: u32,
    res3: [2]u32,
    elsr0: u32,
    elsr1: u32,
    res4: [46]u32,
    apr: u32,
    res5: [3]u32,
    lr: [64]u32,
};

const CPU_IF = extern struct {
    icontrol: u32,
    pri_msk_c: u32,
    pb_c: u32,
    int_ack: u32,
    eoi: u32,
    run_priority: u32,
    hi_pend: u32,
    ns_alias_bp_c: u32,
    ns_alias_ack: u32,
    ns_alias_eoi: u32,
    ns_alias_hi_pend: u32,
    res1: [5]u32,
    integ_en_c: u32,
    interrupt_out: u32,
    res2: [2]u32,
    match_c: u32,
    enable_c: u32,
    res3: [30]u32,
    active_priority: [4]u32,
    ns_active_priority: [4]u32,
    res4: [3]u32,
    cpu_if_ident: u32,
    res5: [948]u32,
    periph_id: [8]u32,
    component_id: [4]u32,
    dir: u32,
};

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

vcpu_ctl: *volatile VCPU_CTL = undefined,
cpu_if: *volatile CPU_IF = undefined,
dist: *volatile DIST = undefined,
num_lrs: usize = 0,
maintenance_irq: u32 = 25, // TODO: retrieve from dtb

extern var pgd: [512]u64 align(1 << 12);
extern var vm_pgd: [512]u64 align(1 << 12);

pub fn init(dtb: ?[*]u8) ?Self {
    var self: Self = .{};
    const root_node_offset = c.fdt_path_offset(dtb, "/");
    if (root_node_offset < 0) {
        print("GICv2: failed to find root node: {}\n", .{root_node_offset});
        return null;
    }
    var gic_node_offset = c.fdt_first_subnode(dtb, root_node_offset);
    while (gic_node_offset >= 0) : (gic_node_offset = c.fdt_next_subnode(dtb, gic_node_offset)) {
        if (c.fdt_getprop(dtb, gic_node_offset, "interrupt-controller", null) != null) break;
    } else {
        print("GICv2: failed to find interrupt controller\n", .{});
        return null;
    }
    var len: c_int = undefined;
    const data: [*c]const u8 = @ptrCast(c.fdt_getprop(dtb, gic_node_offset, "reg", &len).?);
    var gicd_addr: u64 = 0;
    var gicd_size: u64 = 0;
    var gich_addr: u64 = 0;
    var gich_size: u64 = 0;
    var gicc_addr: u64 = 0;
    var gicc_size: u64 = 0;
    var gicv_addr: u64 = 0;
    var gicv_size: u64 = 0;
    for (0..@as(c_uint, @bitCast(len)) / 16) |i| {
        @setRuntimeSafety(false);

        const addr = c.fdt64_to_cpu(@as(*const u64, @ptrCast(@alignCast(data + i * 16))).*);
        const size = c.fdt64_to_cpu(@as(*const u64, @ptrCast(@alignCast(data + i * 16 + 8))).*);
        print("GICv2: reg {}: addr: {x}, size: {x}\n", .{ i, addr, size });

        if (i == 0) {
            gicd_addr = addr;
            gicd_size = size;
        } else if (i == 1) { // GICC
            gicc_addr = addr;
            gicc_size = size;
        } else if (i == 2) { // GICH
            gich_addr = addr;
            gich_size = size;
        } else if (i == 3) {
            gicv_addr = addr;
            gicv_size = size;
        }
    }

    if (gicv_size > 0 and gicc_size == gicv_size and gich_size > 0) {
        self.vcpu_ctl = @ptrCast(@alignCast(mmu.map_device(&pgd, gich_addr, gich_addr, gich_size)));
        self.cpu_if = @ptrCast(@alignCast(mmu.map_device(&pgd, gicc_addr, gicc_addr, gicc_size)));
        self.dist = @ptrCast(@alignCast(mmu.map_device(&pgd, gicd_addr, gicd_addr, gicd_size)));
        // map gicv as gicc for VM
        mmu.map_normal_s2(&vm_pgd, gicv_addr, gicc_addr, gicv_size);

        const regs = [_]u64{ c.cpu_to_fdt64(gicd_addr), c.cpu_to_fdt64(gicd_size), c.cpu_to_fdt64(gicc_addr), c.cpu_to_fdt64(gicc_size) };
        if (c.fdt_setprop(dtb, gic_node_offset, "reg", &regs, @sizeOf(@TypeOf(regs))) != 0) {
            print("GICv2: failed to update gic node\n", .{});
            return null;
        }
    } else {
        print("GICv2: invalid gic regions: gicc: {x}@{x}, gich: {x}@{x}, gicv: {x}@{x}\n", .{ gicc_size, gicc_addr, gich_size, gich_addr, gicv_size, gicv_addr });
        return null;
    }

    self.num_lrs = (self.vcpu_ctl.vtr & 0xf3) + 1;
    print("GICv2: {} LRs\n", .{self.num_lrs});

    return self;
}

pub fn enable_vcpuif(self: *Self) void {
    self.cpu_if.icontrol = 3 | (1 << 9); // enable group0&1, EOImode = 1
    self.cpu_if.pri_msk_c = 0xf0;
    self.cpu_if.pb_c = 3;
    self.vcpu_ctl.hcr = 1;
}

/// we handle maintenance irq internally
pub fn ack_irq(self: *const Self) u32 {
    const v = self.cpu_if.int_ack;
    const irq = v & 0x3ff;

    if (irq == self.maintenance_irq) {
        const eisr = self.vcpu_ctl.eisr0;
        //print("eisr: {x}\n", .{eisr});
        for (0..self.num_lrs) |i| {
            if ((eisr & (@as(u32, 1) << @truncate(i))) != 0) {
                //print("lr{}: {x}\n", .{ i, self.vcpu_ctl.lr[i] });
                const id = self.vcpu_ctl.lr[i] & 0x3ff;
                self.deactive(id);
                self.clear_lr(i);
            }
        }
        self.eoi(v);
        self.deactive(v);

        return self.ack_irq();
    } else return v;
}

fn eoi(self: *const Self, v: u32) void {
    self.cpu_if.eoi = v;
}

fn deactive(self: *const Self, v: u32) void {
    self.cpu_if.dir = v;
}

fn enable_maintainance_irq(self: *const Self) void {
    const idx = self.maintenance_irq >> 5;
    const bit = self.maintenance_irq & 0x1f;

    self.dist.enable_set[idx] = @as(u32, 1) << @truncate(bit);
}

fn clear_lr(self: *const Self, i: usize) void {
    self.vcpu_ctl.lr[i] = 0;
}

pub fn inject_virq(self: *const Self, v: u32) void {
    const irq = v & 0x3ff;
    const elsr = self.vcpu_ctl.elsr0;
    //print("elsr: {x}\n", .{elsr});
    for (0..self.num_lrs) |i| {
        if ((elsr & (@as(u32, 1) << @truncate(i))) != 0) {
            //print("prepare injecting on slot {}\n", .{i});
            if (irq > 15 and !(irq >= 1020 and irq <= 1023)) {
                self.vcpu_ctl.lr[i] = (1 << 31) | (1 << 28) | v << 10 | v;
            } else if (irq < 16) {
                self.vcpu_ctl.lr[i] = (1 << 28) | v | (1 << 19); // trigger maintenance irq when guest EOI
                self.enable_maintainance_irq();
            } else {
                print("Not support injecting irq {}\n", .{irq});
            }
            break;
        }
    } else {
        print("no room in LRs, skip irq {x}\n", .{v});
    }

    self.eoi(v);
}
