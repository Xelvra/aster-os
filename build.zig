const std = @import("std");
const builtin = @import("builtin");

/// True when the KVM device is accessible on this host (mirrors
/// tools/qemu-accel.sh); used as the default for `zig build run` so it
/// accelerates when available and falls back to TCG otherwise.
fn kvmAvailable() bool {
    if (builtin.os.tag != .linux) return false;
    return std.os.linux.access("/dev/kvm", 0) == 0;
}

pub fn build(b: *std.Build) void {
    // ADR-013: pin the exact Zig version. A mismatch would produce a subtly
    // different kernel and silently desync CI and the reproducible gate
    // (2026-08-15-self-audit).
    const pinned = std.mem.trim(u8, @embedFile(".zig-version"), " \n\r");
    const expected = std.SemanticVersion.parse(pinned) catch {
        std.debug.print("build: cannot parse .zig-version '{s}'\n", .{pinned});
        std.process.exit(1);
    };
    const current = builtin.zig_version;
    if (current.major != expected.major or current.minor != expected.minor or current.patch != expected.patch) {
        std.debug.print("build: this project requires Zig {s}, running {d}.{d}.{d}\n", .{
            pinned, current.major, current.minor, current.patch,
        });
        std.process.exit(1);
    }

    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
    } });

    const optimize = if (b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode") orelse null) |mode|
        mode
    else
        .ReleaseSafe;

    const runtime_tests = b.option(bool, "runtime-tests", "Build kernel with in-QEMU runtime tests") orelse false;
    const use_kvm = b.option(bool, "kvm", "Run QEMU with KVM acceleration (-enable-kvm); auto-detects /dev/kvm when omitted") orelse kvmAvailable();
    const disk_path = b.option([]const u8, "disk", "Attach a raw disk image to QEMU (enables virtio-blk storage, visible as '[ OK ] storage' in the boot log)");

    const kernel_options = b.addOptions();
    kernel_options.addOption(bool, "runtime_tests", runtime_tests);
    kernel_options.addOption([]const u8, "version", @embedFile(".version"));

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
    kernel.root_module.addAssemblyFile(b.path("src/kernel/cpu/smp_tramp.s"));
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
    // wasm3.h for the kernel-side wasm3 API (src/kernel/wasm/cimport.zig);
    // the same directory holds the kernel's freestanding inttypes.h.
    kernel.root_module.addIncludePath(b.path("libs/wasm3/source"));
    kernel.root_module.addIncludePath(b.path("src/kernel/wasm"));
    kernel.root_module.addCSourceFiles(.{
        .files = &lua_sources,
        .flags = &.{ "-std=c99", "-ffreestanding", "-Os" },
    });
    kernel.root_module.addCSourceFile(.{
        .file = b.path("src/kernel/lua/vsnprintf.c"),
        .flags = &.{ "-std=c99", "-ffreestanding", "-Os" },
    });

    // Wasm runtime (M7): wasm3 WebAssembly interpreter, built as its OWN
    // sandbox module — the C sources get only their own freestanding headers
    // (libs/wasm3/include), never the Lua vendor's. malloc/free/realloc/abort
    // resolve against the shared kernel libc (src/kernel/libc.zig). The wasm
    // import surface and runtime module live in src/kernel/wasm.
    const wasm3_sources = [_][]const u8{
        "libs/wasm3/source/m3_bind.c",
        "libs/wasm3/source/m3_code.c",
        "libs/wasm3/source/m3_compile.c",
        "libs/wasm3/source/m3_core.c",
        "libs/wasm3/source/m3_emit.c",
        "libs/wasm3/source/m3_env.c",
        "libs/wasm3/source/m3_exec.c",
        "libs/wasm3/source/m3_function.c",
        "libs/wasm3/source/m3_module.c",
        "libs/wasm3/source/m3_optimize.c",
        "libs/wasm3/source/m3_parse.c",
    };
    const wasm3_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        // The kernel is a PIE with -mcmodel kernel; the wasm3 object must be
        // position-independent too or its PC-relative relocations against
        // .rodata/.data fail at link time (Debug build, CI).
        .code_model = .kernel,
        .red_zone = false,
        .single_threaded = true,
        .pic = true,
        // wasm3's threaded-code interpreter dispatches through function
        // pointers cast to a common visitor/op-handler type (its core
        // execution model, e.g. ForEachModule's ModuleVisitor); Zig's default
        // C UBSan (-fsanitize-c=trap, function-type-mismatch check) traps on
        // that legitimate C idiom. Disabled for this vendored module only —
        // never patch libs/wasm3 itself for this.
        .sanitize_c = .off,
    });
    wasm3_mod.addIncludePath(b.path("libs/wasm3/source"));
    wasm3_mod.addIncludePath(b.path("libs/wasm3/include"));
    wasm3_mod.addCSourceFiles(.{
        .files = &wasm3_sources,
        // wasm3 config: cap linear memory (256 pages = 16 MiB, a kernel-usable
        // budget vs the default 2 GiB), keep 32-bit slots fast and errors terse.
        .flags = &.{ "-std=c99", "-ffreestanding", "-Os", "-Dd_m3MaxLinearMemoryPages=256", "-Dd_m3Use32BitSlots=1", "-Dd_m3VerboseErrorMessages=0" },
    });
    const wasm3_obj = b.addObject(.{ .name = "wasm3", .root_module = wasm3_mod });
    kernel.root_module.addObject(wasm3_obj);
    b.installArtifact(kernel);

    // The shell modules, concatenated by the kernel in this order (the kernel
    // keeps the same list in lua.zig — keep them in sync).
    const shell_files = [_][]const u8{ "theme.lua", "wm.lua", "repl.lua", "editor.lua", "files.lua", "launcher.lua", "input.lua", "main.lua" };

    // initfs: the shell modules and assets are packed into a tar archive that
    // Limine loads as a module (initrd); the kernel reads them at runtime
    // instead of them being @embedFile'd (M6, spec/roadmap.md).
    // Each .lua file is passed with addFileArg so Zig tracks it: editing any
    // shell file invalidates the archive and the ISO is rebuilt with the new
    // shell. (addDirectoryArg does NOT track file contents in Zig 0.16, so
    // the archive would stay stale forever.)
    const tar_cmd = b.addSystemCommand(&.{ "tar", "-cf" });
    const initfs_path = tar_cmd.addOutputFileArg("initfs.tar");
    // Deterministic archive so the ISO is reproducible (2026-08-15-self-audit,
    // ADR-014): stable entry order, zeroed mtime/uid/gid.
    tar_cmd.addArg("--sort=name");
    tar_cmd.addArg("--mtime=@0");
    tar_cmd.addArg("--owner=0");
    tar_cmd.addArg("--group=0");
    tar_cmd.addArg("--numeric-owner");
    // The kernel looks files up by their flat name (no directory prefix), so
    // strip the absolute source path from the archive entries.
    tar_cmd.addArg("--transform");
    tar_cmd.addArg("s|^.*/||");
    for (shell_files) |f| {
        tar_cmd.addFileArg(b.path(b.fmt("src/kernel/lua/ui/{s}", .{f})));
    }

    // Spawned Lua programs (runtime.spawn beyond the shell bootstrap, M7) are
    // packed next to the shell modules; the kernel looks them up by their flat
    // file name (lua.loadProgramSource).
    const program_files = [_][]const u8{"probe.lua"};
    for (program_files) |f| {
        tar_cmd.addFileArg(b.path(b.fmt("src/kernel/lua/programs/{s}", .{f})));
    }

    // Spawned wasm programs (runtime.spawn(.Wasm, ...), M7) are Zig binaries
    // compiled to wasm32-freestanding and packed into the initrd by their flat
    // .wasm name (wasm.loadProgramSource). The kernel keeps the same list.
    const wasm_app_files = [_][]const u8{ "hello.zig", "fault.zig", "calculator.zig" };
    for (wasm_app_files) |f| {
        const wasm_app = b.addExecutable(.{
            .name = std.fs.path.stem(f),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/kernel/apps/{s}", .{f})),
                .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
                .optimize = .ReleaseSmall,
                .link_libc = false,
            }),
        });
        // Library-style wasm module: exported start(), no _start entry.
        wasm_app.entry = .disabled;
        // Zig 0.16 strips `export fn` symbols from wasm modules by default
        // (dead-code elimination, ziglang/zig#14102); rdynamic keeps the
        // exports and their imports in the module.
        wasm_app.rdynamic = true;
        tar_cmd.addFileArg(wasm_app.getEmittedBin());
        // calculator.wasm is also a disk app (spec/adr/026, 2026-08-18): the
        // launcher discovers it by scanning /apps/ on disk, not by name — the
        // initrd copy above stays only as a no-disk fallback (hello/fault use
        // it exclusively; they are wasm3 smoke tests, not launcher apps).
        // tools/make-test-disk.sh copies this into the test disk's /apps/.
        if (std.mem.eql(u8, f, "calculator.zig")) {
            const install_app = b.addInstallFile(wasm_app.getEmittedBin(), "apps/calculator.wasm");
            b.getInstallStep().dependOn(&install_app.step);
        }
    }

    const iso_root = b.addWriteFiles();
    _ = iso_root.addCopyFile(kernel.getEmittedBin(), "boot/aster");
    _ = iso_root.addCopyFile(b.path("limine.conf"), "boot/limine.conf");
    _ = iso_root.addCopyFile(b.path("libs/limine/bin/limine-bios.sys"), "boot/limine-bios.sys");
    _ = iso_root.addCopyFile(b.path("libs/limine/bin/limine-bios-cd.bin"), "boot/limine-bios-cd.bin");
    _ = iso_root.addCopyFile(b.path("libs/limine/bin/limine-uefi-cd.bin"), "boot/limine-uefi-cd.bin");
    _ = iso_root.addCopyFile(b.path("libs/limine/bin/BOOTX64.EFI"), "EFI/BOOT/BOOTX64.EFI");
    _ = iso_root.addCopyFile(b.path("libs/limine/bin/BOOTIA32.EFI"), "EFI/BOOT/BOOTIA32.EFI");
    _ = iso_root.addCopyFile(initfs_path, "boot/initfs.tar");

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
    // Install the built ISO at a fixed path (zig-out/aster.iso) so the tools
    // and CI can use a deterministic location instead of guessing by mtime
    // among the many cached ISOs (2026-08-15-self-audit).
    const iso_install = b.addInstallFileWithDir(iso_path, .{ .custom = "" }, "aster.iso");
    iso_install.step.dependOn(&bios_install.step);
    iso_step.dependOn(&iso_install.step);

    const run_cmd = b.addSystemCommand(&.{"qemu-system-x86_64"});
    if (use_kvm) run_cmd.addArg("-enable-kvm");
    run_cmd.addArg("-M");
    run_cmd.addArg("q35");
    run_cmd.addArg("-m");
    run_cmd.addArg("512M");
    run_cmd.addArg("-smp");
    run_cmd.addArg("2");
    // The RTC holds local wall time (the BIOS/Windows convention), so the
    // kernel's bar clock reads the host's local time directly, no UTC offset.
    run_cmd.addArg("-rtc");
    run_cmd.addArg("base=localtime");
    run_cmd.addArg("-cdrom");
    run_cmd.addFileArg(iso_path);
    run_cmd.step.dependOn(&bios_install.step);
    if (disk_path) |path| {
        run_cmd.addArg("-drive");
        run_cmd.addArg(b.fmt("file={s},format=raw,if=none,id=hd0", .{path}));
        run_cmd.addArg("-device");
        run_cmd.addArg("virtio-blk-pci,drive=hd0,disable-legacy=on");
    }
    // SDL display: on Wayland this is the only reliable input path. GDK has no
    // native pointer grab on Wayland (it emulates the grab by warping the
    // cursor back), and even GTK-forced-to-X11 (XWayland) let the cursor
    // escape in a windowed mode and failed on a second monitor. SDL uses the
    // native Wayland relative-pointer lock, so the mouse reaches every edge of
    // the 800x600 framebuffer in a window and in fullscreen, on every monitor,
    // with no X11→Wayland translation latency. Grab/release: Ctrl+Alt+G.
    run_cmd.addArg("-display");
    run_cmd.addArg("sdl");
    run_cmd.addArg("-serial");
    run_cmd.addArg("stdio");
    run_cmd.addArg("-boot");
    run_cmd.addArg("order=d");
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
    rt_run_cmd.addArg("-smp");
    rt_run_cmd.addArg("2");
    rt_run_cmd.addArg("-rtc");
    rt_run_cmd.addArg("base=localtime");
    rt_run_cmd.addArg("-cdrom");
    rt_run_cmd.addFileArg(iso_path);
    rt_run_cmd.step.dependOn(&bios_install.step);
    rt_run_cmd.addArg("-device");
    rt_run_cmd.addArg("isa-debug-exit");
    rt_run_cmd.addArg("-serial");
    rt_run_cmd.addArg("stdio");
    rt_run_cmd.addArg("-boot");
    rt_run_cmd.addArg("order=d");
    rt_run_cmd.addArg("-no-reboot");
    rt_run_cmd.expectExitCode(99);

    const rt_step = b.step("runtime-test", "Run in-QEMU runtime tests via isa-debug-exit");
    if (runtime_tests) {
        rt_step.dependOn(&rt_run_cmd.step);
    } else {
        rt_step.dependOn(&b.addFail("runtime tests need '-Druntime-tests=true'").step);
    }

    const kernel_test_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/test_support.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    kernel_test_module.addIncludePath(b.path("libs/lua-5.4/src"));
    kernel_test_module.addIncludePath(b.path("libs/lua-5.4/include"));
    kernel_test_module.addIncludePath(b.path("libs/wasm3/source"));
    kernel_test_module.addIncludePath(b.path("src/kernel/wasm"));
    kernel_test_module.addCSourceFiles(.{
        .files = &lua_sources,
        .flags = &.{ "-std=c99", "-ffreestanding", "-Os" },
    });
    kernel_test_module.addCSourceFile(.{
        .file = b.path("src/kernel/lua/vsnprintf.c"),
        .flags = &.{ "-std=c99", "-ffreestanding", "-Os" },
    });
    const wasm3_test_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .Debug,
        .single_threaded = true,
        // See wasm3_mod above: wasm3's function-pointer dispatch idiom trips
        // Zig's default C UBSan function-type-mismatch trap.
        .sanitize_c = .off,
    });
    wasm3_test_mod.addIncludePath(b.path("libs/wasm3/source"));
    wasm3_test_mod.addIncludePath(b.path("libs/wasm3/include"));
    wasm3_test_mod.addCSourceFiles(.{
        .files = &wasm3_sources,
        .flags = &.{ "-std=c99", "-ffreestanding", "-Os", "-Dd_m3MaxLinearMemoryPages=256", "-Dd_m3Use32BitSlots=1", "-Dd_m3VerboseErrorMessages=0" },
    });
    const wasm3_test_obj = b.addObject(.{ .name = "wasm3", .root_module = wasm3_test_mod });
    kernel_test_module.addObject(wasm3_test_obj);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .link_libc = true,
            .imports = &.{
                .{ .name = "kernel", .module = kernel_test_module },
            },
        }),
    });

    const test_step = b.step("test", "Run host unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Lua shell regression tests: the real shell modules are concatenated
    // after the host stubs (tests/lua/) and run with a plain Lua interpreter.
    // The step depends on every shell source and test file, so editing any of
    // them re-runs the suite (the kernel's own module order is mirrored here).
    const shell_test_cmd = b.addSystemCommand(&.{"tools/lua-shell-test.sh"});
    for (shell_files) |f| {
        shell_test_cmd.addFileArg(b.path(b.fmt("src/kernel/lua/ui/{s}", .{f})));
    }
    shell_test_cmd.addFileArg(b.path("tests/lua/stubs.lua"));
    shell_test_cmd.addFileArg(b.path("tests/lua/run.lua"));

    const shell_test_step = b.step("shell-test", "Run the Lua shell regression tests on the host");
    shell_test_step.dependOn(&shell_test_cmd.step);
}
