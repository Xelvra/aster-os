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

    const runtime_tests = b.option(bool, "runtime-tests", "Build kernel with in-QEMU runtime tests") orelse false;
    const use_kvm = b.option(bool, "kvm", "Run QEMU with KVM acceleration (-enable-kvm)") orelse false;

    const kernel_options = b.addOptions();
    kernel_options.addOption(bool, "runtime_tests", runtime_tests);

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
    kernel.root_module.addOptions("build_options", kernel_options);
    kernel.pie = true;
    kernel.link_z_max_page_size = 0x1000;
    kernel.root_module.addAssemblyFile(b.path("src/kernel/cpu/isr.s"));
    kernel.root_module.addAssemblyFile(b.path("src/kernel/lua/setjmp.s"));

    const lua_sources = [_][]const u8{
        "libs/lua-5.4/src/lapi.c",
        "libs/lua-5.4/src/lauxlib.c",
        "libs/lua-5.4/src/lbaselib.c",
        "libs/lua-5.4/src/lcode.c",
        "libs/lua-5.4/src/lcorolib.c",
        "libs/lua-5.4/src/lctype.c",
        "libs/lua-5.4/src/ldebug.c",
        "libs/lua-5.4/src/ldo.c",
        "libs/lua-5.4/src/ldump.c",
        "libs/lua-5.4/src/lfunc.c",
        "libs/lua-5.4/src/lgc.c",
        "libs/lua-5.4/src/llex.c",
        "libs/lua-5.4/src/lmathlib.c",
        "libs/lua-5.4/src/lmem.c",
        "libs/lua-5.4/src/lobject.c",
        "libs/lua-5.4/src/lopcodes.c",
        "libs/lua-5.4/src/lparser.c",
        "libs/lua-5.4/src/lstate.c",
        "libs/lua-5.4/src/lstring.c",
        "libs/lua-5.4/src/lstrlib.c",
        "libs/lua-5.4/src/ltable.c",
        "libs/lua-5.4/src/ltablib.c",
        "libs/lua-5.4/src/ltm.c",
        "libs/lua-5.4/src/lundump.c",
        "libs/lua-5.4/src/lutf8lib.c",
        "libs/lua-5.4/src/lvm.c",
        "libs/lua-5.4/src/lzio.c",
    };
    kernel.root_module.addIncludePath(b.path("libs/lua-5.4/src"));
    kernel.root_module.addIncludePath(b.path("libs/lua-5.4/include"));
    kernel.root_module.addCSourceFiles(.{
        .files = &lua_sources,
        .flags = &.{ "-std=c99", "-ffreestanding", "-Os" },
    });
    kernel.root_module.addCSourceFile(.{
        .file = b.path("src/kernel/lua/vsnprintf.c"),
        .flags = &.{ "-std=c99", "-ffreestanding", "-Os" },
    });
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

    // xorriso writes its version banner to stderr on every run; Zig 0.16
    // treats any stderr as a diagnostic and prints a misleading "failed
    // command:" line even on exit 0. Silence it, but keep real errors: stderr
    // is captured to a temp file and replayed only if xorriso fails.
    const xorriso = b.addSystemCommand(&.{
        "sh",  "-c",
        \\tmp=$(mktemp); "$@" 2>"$tmp"; rc=$?; if [ "$rc" -ne 0 ]; then cat "$tmp" >&2; fi; rm -f "$tmp"; exit "$rc"
        ,
        "sh",  "xorriso",
        "-as", "mkisofs",
    });
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
    xorriso.addArg("-quiet");
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
    bios_install.step.dependOn(&limine_tool.step);
    const iso_step = b.step("iso", "Build bootable ISO image");
    iso_step.dependOn(&bios_install.step);

    const run_cmd = b.addSystemCommand(&.{"qemu-system-x86_64"});
    if (use_kvm) run_cmd.addArg("-enable-kvm");
    run_cmd.addArg("-M");
    run_cmd.addArg("q35");
    run_cmd.addArg("-m");
    run_cmd.addArg("512M");
    run_cmd.addArg("-cdrom");
    run_cmd.addFileArg(iso_path);
    run_cmd.step.dependOn(&bios_install.step);
    run_cmd.addArg("-display");
    // Scale the 800x600 window to fit the host screen (the kernel draws at
    // its native framebuffer resolution; zoom-to-fit only affects the QEMU
    // window, not the framebuffer or the mouse coordinate space).
    run_cmd.addArg("gtk,zoom-to-fit=on");
    run_cmd.addArg("-serial");
    run_cmd.addArg("stdio");
    run_cmd.addArg("-no-reboot");
    run_cmd.addArg("-no-shutdown");

    const run_step = b.step("run", "Boot Aster in QEMU");
    run_step.dependOn(&run_cmd.step);

    const rt_run_cmd = b.addSystemCommand(&.{"qemu-system-x86_64"});
    if (use_kvm) rt_run_cmd.addArg("-enable-kvm");
    rt_run_cmd.addArg("-M");
    rt_run_cmd.addArg("q35");
    rt_run_cmd.addArg("-m");
    rt_run_cmd.addArg("512M");
    rt_run_cmd.addArg("-cdrom");
    rt_run_cmd.addFileArg(iso_path);
    rt_run_cmd.step.dependOn(&bios_install.step);
    rt_run_cmd.addArg("-device");
    rt_run_cmd.addArg("isa-debug-exit");
    rt_run_cmd.addArg("-serial");
    rt_run_cmd.addArg("stdio");
    rt_run_cmd.addArg("-no-reboot");
    rt_run_cmd.expectExitCode(99);

    const rt_step = b.step("runtime-test", "Run in-QEMU runtime tests via isa-debug-exit");
    if (runtime_tests) {
        rt_step.dependOn(&rt_run_cmd.step);
    } else {
        rt_step.dependOn(&b.addFail("runtime tests need '-Druntime-tests=true'").step);
    }

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "kernel", .module = b.createModule(.{
                    .root_source_file = b.path("src/kernel/test_support.zig"),
                    .target = b.graph.host,
                    .optimize = .Debug,
                }) },
            },
        }),
    });

    const test_step = b.step("test", "Run host unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
