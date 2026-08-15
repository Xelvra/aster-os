const std = @import("std");
const serial = @import("serial.zig");
const debug = @import("api/debug.zig");
const graphics = @import("api/graphics.zig");
const runtime = @import("api/runtime.zig");
const storage = @import("api/storage.zig");
const sys = @import("api/sys.zig");
const sysmon = @import("api/sysmon.zig");
const boot = @import("boot/boot.zig");
const boot_info = @import("boot/boot_info.zig");
const bootlog = @import("bootlog.zig");
const acpi = @import("cpu/acpi.zig");
const apic = @import("cpu/apic.zig");
const idt = @import("cpu/idt.zig");
const block = @import("drivers/block.zig");
const pic = @import("drivers/pic.zig");
const ps2 = @import("drivers/ps2.zig");
const virtio = @import("drivers/virtio.zig");
const framebuffer = @import("fb/framebuffer.zig");
const ext2 = @import("fs/ext2.zig");
const file = @import("fs/file.zig");
const gpt = @import("fs/gpt.zig");
const input_service = @import("input/service.zig");
const lua = @import("lua/lua.zig");
const cache_attr = @import("mem/cache_attr.zig");
const mem = @import("mem/mem.zig");
const page_map = @import("mem/page_map.zig");
const pfa = @import("mem/pfa.zig");
const mouse_cursor_mod = @import("render/mouse_cursor.zig");
const renderer_mod = @import("render/renderer.zig");
const sched = @import("sched/task.zig");
const time = @import("time.zig");
const runtime_test = @import("runtime_test.zig");

/// Main kernel stack. The bootloader hands the kernel a small stack; switch
/// to a large one before kernelMain — deep call chains (Lua) and large stack
/// frames overflow a small bootloader stack.
var kernel_stack: [262144]u8 align(16) = undefined;

export fn _start() callconv(.c) noreturn {
    const top: [*]u8 = @ptrCast(&kernel_stack);
    asm volatile ("mov %[stack], %%rsp"
        :
        : [stack] "r" (top + kernel_stack.len),
    );
    enable_sse();
    serial.init();
    kernelMain() catch {
        serial.writeLine("ASTER KERNEL INIT FAILED");
        halt();
    };
    halt();
}

fn enable_sse() void {
    const cr0 = read_cr0();
    write_cr0(cr0 & ~@as(u64, 1 << 2));
    write_cr0(read_cr0() | (1 << 1));
    write_cr4(read_cr4() | (3 << 9));
    write_mxcsr(0x1F80);
}
fn read_cr0() u64 {
    return asm volatile ("mov %%cr0, %[v]"
        : [v] "=r" (-> u64),
    );
}

fn write_cr0(value: u64) void {
    asm volatile ("mov %[v], %%cr0"
        :
        : [v] "r" (value),
        : .{ .memory = true });
}

fn read_cr4() u64 {
    return asm volatile ("mov %%cr4, %[v]"
        : [v] "=r" (-> u64),
    );
}

fn write_cr4(value: u64) void {
    asm volatile ("mov %[v], %%cr4"
        :
        : [v] "r" (value),
        : .{ .memory = true });
}

fn write_mxcsr(value: u32) void {
    // ReleaseSafe passes a "m" operand as address-of-address, so ldmxcsr
    // would load a pointer instead of the value -> #GP on real HW/KVM
    // (TCG ignores reserved MXCSR bits, masking the bug). Pass the address
    // in a register and dereference it explicitly (scratch-register pattern,
    // see spec/troubleshooting.md C27).
    var v: u32 = value;
    asm volatile ("mov %[addr], %%rax\nldmxcsr (%%rax)"
        :
        : [addr] "r" (&v),
        : .{ .rax = true, .memory = true });
}

/// Run CPUID and return EAX, EBX, ECX, EDX.
fn cpuId(leaf: u32, subleaf: u32) [4]u32 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [out_eax] "={eax}" (eax),
          [out_ebx] "={ebx}" (ebx),
          [out_ecx] "={ecx}" (ecx),
          [out_edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
        : .{ .memory = true });
    return .{ eax, ebx, ecx, edx };
}

/// Report the accelerator: "kvm" under KVM, "tcg" under QEMU TCG, "hv" for
/// any other hypervisor. CPUID leaf 1 ECX bit 31 is the hypervisor-present
/// bit; leaf 0x40000000 carries the hypervisor vendor in EBX, ECX, EDX
/// (KVM = "KVMKVMKVM", QEMU TCG = "TCGTCGTCGTCG").
fn accelName() []const u8 {
    const leaf1 = cpuId(1, 0);
    if ((leaf1[2] & (1 << 31)) == 0) return "tcg";
    const hv = cpuId(0x40000000, 0);
    var vendor: [12]u8 = undefined;
    @memcpy(vendor[0..4], &std.mem.toBytes(hv[1]));
    @memcpy(vendor[4..8], &std.mem.toBytes(hv[2]));
    @memcpy(vendor[8..12], &std.mem.toBytes(hv[3]));
    if (std.mem.startsWith(u8, &vendor, "KVMKVMKVM")) return "kvm";
    if (std.mem.startsWith(u8, &vendor, "TCG")) return "tcg";
    return "hv";
}

fn kernelMain() !void {
    serial.writeLine("ASTER KERNEL ENTRY");
    bootlog.blank();
    bootlog.banner();

    time.calibrateRealTime();
    const boot_ms = time.ms();
    const info = try boot.collect();
    bootlog.ok("bootloader", "limine handoff");

    idt.init();
    pic.remap();
    bootlog.ok("interrupts", "idt · pic");
    sched.init(@intFromPtr(&kernel_stack));

    var memory: mem.Memory = undefined;
    try memory.init(&info);
    sysmon.init(&memory);

    const alloc = memory.allocator();
    const test_buf = try alloc.alloc(u8, 64);
    defer alloc.free(test_buf);
    @memset(test_buf, 0xAB);
    if (test_buf[0] != 0xAB or test_buf[63] != 0xAB) return error.HeapTestFailed;

    page_map.init(&memory.pfa, info.hhdm_offset);
    const ioapic_result = if (info.rsdp_address) |addr| acpi.findIoApic(addr, info.hhdm_offset) else null;
    const ioapic_override: ?u64 = if (ioapic_result) |r| switch (r) {
        .found => |addr| addr,
        else => null,
    } else null;
    apic.init(info.hhdm_offset, ioapic_override);
    const ioapic_note: []const u8 = if (ioapic_result) |r| switch (r) {
        .found => " · ioapic: madt",
        .bad_checksum => " · ioapic: fallback, bad-checksum",
        .no_madt => " · ioapic: fallback, no-madt",
        .no_ioapic_entry => " · ioapic: fallback, no-ioapic-entry",
        .no_rsdp => " · ioapic: fallback, no-rsdp",
    } else " · ioapic: fallback, no-rsdp";
    var cpu_detail: [96]u8 = undefined;
    const cpu_line = std.fmt.bufPrint(&cpu_detail, "page tables · apic timer{s}", .{ioapic_note}) catch "page tables · apic timer";
    bootlog.ok("cpu", cpu_line);

    ps2.init();
    bootlog.ok("input", "ps/2 keyboard + mouse");
    probeStorage(alloc, &memory);

    var display: DisplayState = .{};
    if (initGraphics(&display, &info, &memory)) {
        var gfx_buf: [96]u8 = undefined;
        bootlog.ok("graphics", graphicsDetail(&info, &gfx_buf));
        bootlog.ok("renderer", "primitives + bitmap font");
    } else {
        bootlog.warn("graphics", "no framebuffer, console disabled");
    }

    runtime.init(alloc, info.initrd);
    const program = runtime.spawn(.{ .kind = .Lua, .entry = "main.lua" }) catch |err| {
        bootlog.fail("runtime", "lua shell failed to start");
        return err;
    };
    _ = program;
    bootlog.ok("runtime", "lua 5.4.8 shell");

    var mem_buf: [64]u8 = undefined;
    const mem_detail = std.fmt.bufPrint(&mem_buf, "{d} MiB usable · {d} MiB used", .{
        usableMiB(&info), ramUsedMiB(&memory),
    }) catch "memory";
    bootlog.ok("memory", mem_detail);

    if (testKiDispatch()) {
        bootlog.ok("kernel interface", "dispatch ready");
    } else {
        bootlog.fail("kernel interface", "dispatch failed");
    }

    bootlog.ok("accelerator", accelName());
    var seq_buf: [64]u8 = undefined;
    const seq_detail = std.fmt.bufPrint(&seq_buf, "complete · {d} KiB · {d} ms", .{
        (info.kernel_size + 1023) / 1024,
        time.ms() - boot_ms,
    }) catch "complete";
    bootlog.ok("boot sequence", seq_detail);
    bootlog.blank();

    serial.writeLine("ASTER BOOT OK");

    asm volatile ("sti" ::: .{ .memory = true });
    if (comptime runtime_test.enabled) {
        runtime_test.runAll(alloc, &memory);
    }
    eventLoop(&display);
}

/// Display pipeline state: the two framebuffers, the renderer, the cursor
/// overlay and the frame-loop dirty tracking. One instance is owned by
/// kernelMain and threaded through the frame loop by pointer — this is the
/// explicit-passing pattern of spec/code-style.md §1, not module globals.
const DisplayState = struct {
    fb_storage: ?framebuffer.Framebuffer = null,
    back_fb: ?framebuffer.Framebuffer = null,
    renderer: renderer_mod.Renderer = undefined,
    mouse_cursor: mouse_cursor_mod.MouseCursor = .{},
    needs_render: bool = true,
    first_frame_reported: bool = false,
};

fn initGraphics(display: *DisplayState, info: *const boot_info.BootInfo, memory: *mem.Memory) bool {
    const fb_info = info.framebuffer orelse return false;
    display.fb_storage = framebuffer.Framebuffer.init(fb_info);

    // Phase 2 double buffering: render into an offscreen back buffer and
    // present it to the visible framebuffer in one copy, so the viewer never
    // sees a half-drawn frame. The back buffer is plain RAM (not GOP MMIO),
    // one page per 4 KiB of pitch*height. A large contiguous run is fine: the
    // heap grow, initfs and this buffer are the only big PFA allocations.
    const bytes: usize = @intCast(fb_info.pitch * fb_info.height);
    const pages_needed = (bytes + pfa.page_size - 1) / pfa.page_size;
    if (memory.pfa.allocPages(pages_needed, true) catch null) |pages| {
        var back = display.fb_storage.?;
        back.base = @ptrFromInt(pages[0] + memory.pfa.hhdm_offset);
        display.back_fb = back;
    }

    display.renderer = renderer_mod.Renderer.init(renderTarget(display));
    graphics.init(display.renderer);
    display.renderer.fillScreen(0x000000);
    display.mouse_cursor.init(renderTarget(display), @intCast(fb_info.width / 2), @intCast(fb_info.height / 2));
    input_service.setMouseState(.{
        .x = @divTrunc(@as(i32, @intCast(fb_info.width)), 2),
        .y = @divTrunc(@as(i32, @intCast(fb_info.height)), 2),
    });
    return true;
}

/// The framebuffer the renderer draws into: the back buffer when double
/// buffering is active, the visible framebuffer otherwise.
fn renderTarget(display: *DisplayState) *framebuffer.Framebuffer {
    if (display.back_fb) |*back| return back;
    return &display.fb_storage.?;
}

/// Copy the finished back buffer to the visible framebuffer in one pass
/// (Phase 2 present). Without double buffering this is a no-op.
fn present(display: *DisplayState) void {
    const back = display.back_fb orelse return;
    const front = &display.fb_storage.?;
    const bytes: usize = @intCast(front.pitch * front.height);
    const src: [*]const u8 = @ptrCast(@volatileCast(back.base));
    const dst: [*]volatile u8 = front.base;
    for (0..bytes) |i| {
        dst[i] = src[i];
    }
}

fn probeStorage(alloc: std.mem.Allocator, memory: *mem.Memory) void {
    storage.disk = virtio.VirtioBlk.init(alloc, &memory.pfa, memory.pfa.hhdm_offset) catch return;
    const blk = &storage.disk;
    blk.setupQueue() catch return;
    var sector: [512]u8 = undefined;
    blk.readSector(0, &sector) catch return;
    bootlog.ok("storage", "virtio-blk");

    // GPT partition discovery (M6.1.2): partitions become block-device views.
    var partitions: [8]block.PartitionView = undefined;
    const count = gpt.discover(alloc, blk.asBlockDevice(), &partitions) catch return;
    if (count == 0) return;
    var buf: [48]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{d} partition(s)", .{count}) catch return;
    bootlog.ok("gpt", msg);

    // M6.1.3: mount ext2 read-only on the linux-filesystem partition and
    // list the root directory as the exit check ("výpis souborů"). The mount
    // is handed to the KI storage module (M7.1.4) so Lua file.* works after
    // boot.
    var fs_partition: ?block.PartitionView = null;
    for (partitions[0..count]) |p| {
        if (gpt.eqlGuid(p.type_guid, gpt.type_guid_linux_fs)) {
            fs_partition = p;
            break;
        }
    }
    const part = fs_partition orelse return;
    var fs = ext2.Ext2.init(part) catch return;
    storage.mount(fs);
    bootlog.ok("fs", "ext2");
    var entries: [32]ext2.DirEntry = undefined;
    const n = fs.readDir(ext2.root_inode, &entries) catch return;
    // Listing (variant A): real entries only (no "." / ".."), no repeated
    // prefix; the theme.lua config value is read through the thin file API
    // (M6.1.4) and printed after its name. Order: the ext2 `lost+found`
    // directory first, then the remaining directories, then files (ext2
    // file_type: 2 = directory, 1 = regular).
    const column: usize = 22;
    const config_name = "theme.lua";
    for (0..3) |pass| {
        for (entries[0..n]) |e| {
            const name = e.name[0..e.name_len];
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const is_dir = e.file_type == 2;
            const is_lost_found = std.mem.eql(u8, name, "lost+found");
            const in_pass = switch (pass) {
                0 => is_lost_found,
                1 => is_dir and !is_lost_found,
                else => !is_dir,
            };
            if (!in_pass) continue;
            serial.write("  ");
            serial.write(name);
            if (std.mem.eql(u8, name, config_name)) {
                var fh = file.File.open(&fs, name) catch null;
                if (fh) |*f| {
                    var fbuf: [128]u8 = undefined;
                    const m = f.read(&fbuf) catch 0;
                    if (m > 0) {
                        var pad: usize = name.len + 2;
                        while (pad < column) : (pad += 1) serial.write(" ");
                        serial.write(fbuf[0..m]);
                    }
                }
            }
            serial.writeLine("");
        }
    }
}

fn testKiDispatch() bool {
    // Dispatch the Debug write op with an empty message: exercises the full
    // KI path (sys.dispatch -> debug module) without polluting the boot log.
    const dummy: u8 = 0;
    const status = sys.dispatch(.Debug, .{
        .a = @intFromEnum(debug.DebugOp.write),
        .b = @intFromPtr(&dummy),
        .c = 0,
    });
    return status == 0;
}

/// Bounded mouse packet processing per poll() so a busy mouse cannot
/// starve the keyboard/Lua update.
const max_mouse_per_poll: usize = 64;

/// Cursor speed multiplier applied in the input event loop. Some hosts report
/// PS/2 deltas scaled down (e.g. QEMU SDL on Wayland delivers small relative
/// deltas), so a 1:1 cursor feels sluggish. A named constant so it can be
/// tuned without magic numbers; ±127 * this stays well inside i16. The cursor
/// overlay itself (mouse_cursor.move) stays pure 1:1 so it is host-testable.
const cursor_speed: i16 = 2;

fn eventLoop(display: *DisplayState) noreturn {
    while (true) {
        poll(display);
        if (update()) {
            // The shell errored; reload it so the desktop recovers instead
            // of staying half-drawn (spec/runtime.md §5 error containment).
            serial.writeLine("shell: error, hot reload");
            runtime.requestReload();
            display.needs_render = true;
        }
        if (graphics.invalidate_requested) {
            display.needs_render = true;
            graphics.invalidate_requested = false;
        }
        if (runtime.reloadRequested()) {
            // The reload is performed here, outside any Lua call frame —
            // a pending reload can come from F5 (poll) or from Lua itself
            // (session menu "Logout"). Never close a lua_State mid-call.
            runtime.performReload();
            display.needs_render = true;
        }
        if (display.needs_render) {
            render(display);
            if (!display.first_frame_reported) {
                display.first_frame_reported = true;
                serial.writeLine("ASTER FIRST FRAME");
            }
            display.needs_render = false;
        }
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}

fn poll(display: *DisplayState) void {
    // Two queues, two jobs:
    //  - global: timer ticks are consumed; keys are left queued for Lua but
    //    mark the screen dirty so a typed character repaints immediately.
    //  - mouse: packets are consumed here to move the cursor overlay, bounded
    //    so a busy mouse cannot starve the keyboard/Lua update.
    while (true) {
        const event = input_service.peekKernelEvent() orelse break;
        switch (event) {
            .timer_tick => {
                _ = input_service.popKernelEvent();
            },
            .key => |key| {
                if (key.code == .f5 and key.pressed) {
                    _ = input_service.popKernelEvent();
                    serial.writeLine("shell: hot reload (F5)");
                    runtime.requestReload();
                    display.needs_render = true;
                }
                if (key.pressed) display.needs_render = true;
                break;
            },
            .mouse => unreachable, // mouse lives in its own queue
        }
    }

    var mouse_processed: usize = 0;
    while (mouse_processed < max_mouse_per_poll) {
        const event = input_service.peekMouseEvent() orelse break;
        switch (event) {
            .timer_tick, .key => unreachable, // not valid in the mouse queue
            .mouse => |m| {
                _ = input_service.popMouseEvent();
                display.mouse_cursor.move(renderTarget(display), m.dx * cursor_speed, m.dy * cursor_speed);
                input_service.setMouseState(.{
                    .x = display.mouse_cursor.x,
                    .y = display.mouse_cursor.y,
                    .left = m.left,
                    .right = m.right,
                    .middle = m.middle,
                });
                mouse_processed += 1;
            },
        }
    }
    if (mouse_processed > 0) {
        // The cursor moved in the back buffer; show it without re-rendering
        // the Lua scene. Present once for the whole batch — a per-packet
        // copy (full-screen memcpy) starves the keyboard/Lua update.
        present(display);
    }
}

fn update() bool {
    const result = lua.callUpdate();
    lua.gcStep(1024);
    return result == lua.CallResult.err;
}

fn render(display: *DisplayState) void {
    if (graphics.renderer == null) return;
    if (lua.callRender() == .err) {
        // The shell draw loop failed; reload so the next frame is clean.
        serial.writeLine("shell: render error, hot reload");
        runtime.requestReload();
    }
    display.mouse_cursor.redraw(renderTarget(display));
    present(display);
}

fn ramUsedMiB(memory: *mem.Memory) u64 {
    // Used at the PFA level = kernel image + framebuffer + heap + stacks +
    // bitmap (everything the PFA bitmap marks as taken). This is the
    // "RAM (idle)" metric from spec/roadmap.md §2.
    const used_bytes = (memory.pfa.total_pages - memory.pfa.totalFreePages()) * pfa.page_size;
    return used_bytes / (1024 * 1024);
}

fn usableMiB(info: *const boot_info.BootInfo) u64 {
    var total: u64 = 0;
    for (info.memory_entries) |entry| {
        if (entry.type == .usable) total += entry.length;
    }
    return total / (1024 * 1024);
}

fn graphicsDetail(info: *const boot_info.BootInfo, buf: []u8) []const u8 {
    if (info.framebuffer) |fb| {
        const attr = cache_attr.framebufferCacheAttr(fb.address, info.hhdm_offset);
        return std.fmt.bufPrint(buf, "{d}x{d} framebuffer · {s}", .{ fb.width, fb.height, @tagName(attr) }) catch "framebuffer";
    }
    return "none";
}

fn halt() noreturn {
    asm volatile ("cli" ::: .{ .memory = true });
    while (true) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}
