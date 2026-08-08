const std = @import("std");
const serial = @import("serial.zig");
const boot = @import("boot/boot.zig");
const boot_info = @import("boot/boot_info.zig");
const mem = @import("mem/mem.zig");
const pfa = @import("mem/pfa.zig");
const cache_attr = @import("mem/cache_attr.zig");
const idt = @import("cpu/idt.zig");
const pic = @import("drivers/pic.zig");
const apic = @import("cpu/apic.zig");
const page_map = @import("mem/page_map.zig");
const ps2 = @import("drivers/ps2.zig");
const block = @import("drivers/block.zig");
const input = @import("input.zig");
const input_queue = @import("input_queue.zig");
const framebuffer = @import("fb/framebuffer.zig");
const renderer_mod = @import("render/renderer.zig");
const mouse_cursor_mod = @import("render/mouse_cursor.zig");
const graphics = @import("api/graphics.zig");
const runtime = @import("api/runtime.zig");
const runtime_test = @import("runtime_test.zig");
const lua = @import("lua/lua.zig");
const bootlog = @import("bootlog.zig");

export fn _start() callconv(.c) noreturn {
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

/// Report the accelerator: "kvm" under KVM, "tcg" when no hypervisor is
/// present (QEMU TCG by default), "hv" for any other hypervisor. CPUID
/// leaf 1 ECX bit 31 is the hypervisor-present bit; leaf 0x40000000
/// carries the hypervisor vendor (EBX, EDX, ECX — KVM = "KVMKVMKVM").
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

    const info = try boot.collect();
    bootlog.ok("bootloader", "limine handoff");

    idt.init();
    pic.remap();
    bootlog.ok("interrupts", "idt · pic");

    var memory = try mem.Memory.init(&info);
    const sysmon = @import("api/sysmon.zig");
    sysmon.init(&memory);

    const alloc = memory.allocator();
    const test_buf = try alloc.alloc(u8, 64);
    defer alloc.free(test_buf);
    @memset(test_buf, 0xAB);
    if (test_buf[0] != 0xAB or test_buf[63] != 0xAB) return error.HeapTestFailed;

    page_map.init(&memory.pfa, info.hhdm_offset);
    apic.init(info.hhdm_offset);
    bootlog.ok("cpu", "page tables · apic timer");

    ps2.init();
    bootlog.ok("input", "ps/2 keyboard + mouse");
    probeStorage(alloc, &memory);

    if (initGraphics(&info)) {
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
    bootlog.ok("boot sequence", "complete");
    bootlog.blank();

    serial.writeLine("ASTER BOOT OK");

    asm volatile ("sti" ::: .{ .memory = true });
    if (comptime runtime_test.enabled) {
        runtime_test.runAll();
    }
    eventLoop();
}

var fb_storage: ?framebuffer.Framebuffer = null;
var renderer: renderer_mod.Renderer = undefined;
var mouse_cursor: mouse_cursor_mod.MouseCursor = .{};

fn initGraphics(info: *const boot_info.BootInfo) bool {
    const fb_info = info.framebuffer orelse return false;
    fb_storage = framebuffer.Framebuffer.init(fb_info);
    renderer = renderer_mod.Renderer.init(&fb_storage.?);
    graphics.init(renderer);
    renderer.fillScreen(0x000000);
    mouse_cursor.init(&fb_storage.?, @intCast(fb_info.width / 2), @intCast(fb_info.height / 2));
    input.mouse_state.x = @divTrunc(@as(i32, @intCast(fb_info.width)), 2);
    input.mouse_state.y = @divTrunc(@as(i32, @intCast(fb_info.height)), 2);
    return true;
}

fn probeStorage(alloc: std.mem.Allocator, memory: *mem.Memory) void {
    const virtio = @import("drivers/virtio.zig");
    const gpt = @import("fs/gpt.zig");
    var blk = virtio.VirtioBlk.init(alloc, &memory.pfa, memory.pfa.hhdm_offset) catch return;
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
    // list the root directory as the exit check ("výpis souborů").
    const ext2 = @import("fs/ext2.zig");
    var fs_partition: ?block.PartitionView = null;
    for (partitions[0..count]) |p| {
        if (gpt.eqlGuid(p.type_guid, gpt.type_guid_linux_fs)) {
            fs_partition = p;
            break;
        }
    }
    const part = fs_partition orelse return;
    const fs = ext2.Ext2.init(part) catch return;
    bootlog.ok("fs", "ext2");
    var entries: [32]ext2.DirEntry = undefined;
    const n = fs.readDir(ext2.root_inode, &entries) catch return;
    for (entries[0..n]) |e| {
        serial.write("  fs ");
        serial.write(e.name[0..e.name_len]);
        serial.writeLine("");
    }
}

fn testKiDispatch() bool {
    const sys = @import("api/sys.zig");
    const debug = @import("api/debug.zig");
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

var needs_render = true;
var first_frame_reported = false;

/// Bounded mouse packet processing per poll() so a busy mouse cannot
/// starve the keyboard/Lua update.
const max_mouse_per_poll: usize = 64;

fn eventLoop() noreturn {
    while (true) {
        poll();
        if (update()) {
            // The shell errored; reload it so the desktop recovers instead
            // of staying half-drawn (spec/runtime.md §5 error containment).
            serial.writeLine("shell: error, hot reload");
            runtime.requestReload();
            needs_render = true;
        }
        if (graphics.invalidate_requested) {
            needs_render = true;
            graphics.invalidate_requested = false;
        }
        if (runtime.reloadRequested()) {
            // The reload is performed here, outside any Lua call frame —
            // a pending reload can come from F5 (poll) or from Lua itself
            // (session menu "Logout"). Never close a lua_State mid-call.
            runtime.performReload();
            needs_render = true;
        }
        if (needs_render) {
            render();
            if (!first_frame_reported) {
                first_frame_reported = true;
                serial.writeLine("ASTER FIRST FRAME");
            }
            needs_render = false;
        }
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}

fn poll() void {
    // Two queues, two jobs:
    //  - global: timer ticks are consumed; keys are left queued for Lua but
    //    mark the screen dirty so a typed character repaints immediately.
    //  - mouse: packets are consumed here to move the cursor overlay, bounded
    //    so a busy mouse cannot starve the keyboard/Lua update.
    while (true) {
        const event = input_queue.global.peek() orelse break;
        switch (event) {
            .timer_tick => {
                _ = input_queue.global.pop();
            },
            .key => |key| {
                if (key.code == .f5 and key.pressed) {
                    _ = input_queue.global.pop();
                    serial.writeLine("shell: hot reload (F5)");
                    runtime.requestReload();
                    needs_render = true;
                }
                if (key.pressed) needs_render = true;
                break;
            },
            .mouse => unreachable, // mouse lives in its own queue
        }
    }

    var mouse_processed: usize = 0;
    while (mouse_processed < max_mouse_per_poll) {
        const event = input_queue.mouse.peek() orelse break;
        switch (event) {
            .timer_tick, .key => unreachable, // not valid in the mouse queue
            .mouse => |m| {
                _ = input_queue.mouse.pop();
                mouse_cursor.move(&fb_storage.?, m.dx, m.dy);
                input.mouse_state.x = mouse_cursor.x;
                input.mouse_state.y = mouse_cursor.y;
                input.mouse_state.left = m.left;
                input.mouse_state.right = m.right;
                input.mouse_state.middle = m.middle;
                mouse_processed += 1;
            },
        }
    }
}

fn update() bool {
    const result = lua.callUpdate();
    lua.gcStep(1024);
    return result == lua.CallResult.err;
}

fn render() void {
    if (graphics.renderer == null) return;
    if (lua.callRender() == .err) {
        // The shell draw loop failed; reload so the next frame is clean.
        serial.writeLine("shell: render error, hot reload");
        runtime.requestReload();
    }
    if (fb_storage) |*fb| mouse_cursor.redraw(fb);
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
