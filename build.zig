const std = @import("std");

const Arch = enum {
    aarch64,
};

pub fn build(b: *std.Build) void {
    const kernel_path = b.option([]const u8, "kernel", "Path to the linux kernel image") orelse {
        std.debug.print("Specify the linux kernel image with -Dkernel\n", .{});
        std.process.exit(1);
    };
    const arch: Arch = b.option(Arch, "arch", "Architecture to build") orelse .aarch64;

    const target = switch (arch) {
        .aarch64 => b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a76 },
            .os_tag = .freestanding,
            .abi = .none,
        }),
    };

    const optimize = b.standardOptimizeOption(.{});

    const prefix = b.fmt("src/arch/{s}", .{@tagName(arch)});
    const arch_mod = b.addModule("arch", .{
        .root_source_file = .{
            .path = b.fmt("{s}/root.zig", .{prefix}),
        },
    });
    const crt0 = b.addObject(.{
        .name = "crt0",
        .root_source_file = .{
            .path = b.fmt("{s}/crt0.zig", .{prefix}),
        },
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "image.elf",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addObject(crt0);
    exe.root_module.addImport("arch", arch_mod);
    exe.root_module.addAnonymousImport("kernel", .{
        .root_source_file = .{ .path = kernel_path },
    });
    exe.setLinkerScriptPath(.{ .path = b.fmt("{s}/linker.ld", .{prefix}) });
    switch (arch) {
        .aarch64 => {
            const libfdt = b.dependency("libfdt", .{
                .target = target,
                .optimize = optimize,
            }).artifact("libfdt");
            arch_mod.linkLibrary(libfdt);
        },
    }
    b.installArtifact(exe);

    const img = b.addObjCopy(exe.getEmittedBin(), .{
        .format = .bin,
    });
    const install_img = b.addInstallBinFile(img.getOutput(), "image");
    b.getInstallStep().dependOn(&install_img.step);

    const run_cmd = b.addSystemCommand(&.{
        b.fmt("{s}/run.sh", .{prefix}),
        "zig-out/bin/image",
    });
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
