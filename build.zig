const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
    } });

    const optimize = if (b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode") orelse null) |mode|
        mode
    else
        .ReleaseSafe;

    const kernel = b.addExecutable(.{
        .name = "aster",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .code_model = .kernel,
            .red_zone = false,
            .link_libc = false,
            .error_tracing = false,
            .strip = optimize != .Debug,
        }),
    });
    kernel.pie = true;
    kernel.link_z_max_page_size = 0x1000;
    b.installArtifact(kernel);

    const iso_root = b.addWriteFiles();
    _ = iso_root.addCopyFile(kernel.getEmittedBin(), "boot/aster");
    _ = iso_root.addCopyFile(b.path("limine.conf"), "boot/limine.conf");
    _ = iso_root.addCopyFile(b.path("libs/limine/bin/limine-bios.sys"), "boot/limine-bios.sys");
    _ = iso_root.addCopyFile(b.path("libs/limine/bin/limine-bios-cd.bin"), "boot/limine-bios-cd.bin");
    _ = iso_root.addCopyFile(b.path("libs/limine/bin/limine-uefi-cd.bin"), "boot/limine-uefi-cd.bin");
    _ = iso_root.addCopyFile(b.path("libs/limine/bin/BOOTX64.EFI"), "EFI/BOOT/BOOTX64.EFI");
    _ = iso_root.addCopyFile(b.path("libs/limine/bin/BOOTIA32.EFI"), "EFI/BOOT/BOOTIA32.EFI");

    const iso_dir = iso_root.getDirectory();

    const xorriso = b.addSystemCommand(&.{ "xorriso", "-as", "mkisofs" });
    xorriso.addArg("-b");
    xorriso.addArg("boot/limine-bios-cd.bin");
    xorriso.addArg("-no-emul-boot");
    xorriso.addArg("-boot-load-size");
    xorriso.addArg("4");
    xorriso.addArg("-boot-info-table");
    xorriso.addArg("--efi-boot");
    xorriso.addArg("boot/limine-uefi-cd.bin");
    xorriso.addArg("-efi-boot-part");
    xorriso.addArg("--efi-boot-image");
    xorriso.addArg("--protective-msdos-label");
    xorriso.addArg("-o");
    const iso_path = xorriso.addOutputFileArg("aster.iso");
    xorriso.addDirectoryArg(iso_dir);
    xorriso.step.dependOn(&iso_root.step);

    const limine_tool = b.addSystemCommand(&.{"cc"});
    limine_tool.addArg("-O2");
    limine_tool.addArg("-std=c99");
    limine_tool.addFileArg(b.path("libs/limine/tools/limine.c"));
    limine_tool.addArg("-o");
    const limine_path = limine_tool.addOutputFileArg("limine");
    limine_tool.step.dependOn(&kernel.step);

    const bios_install = std.Build.Step.Run.create(b, "bios-install");
    bios_install.addFileArg(limine_path);
    bios_install.addArg("bios-install");
    bios_install.addFileArg(iso_path);
    bios_install.step.dependOn(&xorriso.step);
    bios_install.step.dependOn(&limine_tool.step);
    const iso_step = b.step("iso", "Build bootable ISO image");
    iso_step.dependOn(&bios_install.step);

    const run_cmd = b.addSystemCommand(&.{"qemu-system-x86_64"});
    run_cmd.addArg("-M");
    run_cmd.addArg("q35");
    run_cmd.addArg("-m");
    run_cmd.addArg("512M");
    run_cmd.addArg("-cdrom");
    run_cmd.addFileArg(iso_path);
    run_cmd.addArg("-serial");
    run_cmd.addArg("stdio");
    run_cmd.addArg("-no-reboot");
    run_cmd.addArg("-no-shutdown");
    run_cmd.step.dependOn(&bios_install.step);

    const run_step = b.step("run", "Boot Aster in QEMU");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const test_step = b.step("test", "Run host unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
