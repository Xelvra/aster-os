const std = @import("std");
const serial = @import("serial.zig");
const boot = @import("boot/boot.zig");
const boot_info = @import("boot/boot_info.zig");
const mem = @import("mem/mem.zig");
const cache_attr = @import("mem/cache_attr.zig");
const idt = @import("cpu/idt.zig");
const pic = @import("drivers/pic.zig");
const apic = @import("cpu/apic.zig");
const page_map = @import("mem/page_map.zig");
const ps2 = @import("drivers/ps2.zig");
const input = @import("input.zig");
const input_queue = @import("input_queue.zig");
const framebuffer = @import("fb/framebuffer.zig");
const renderer_mod = @import("render/renderer.zig");
const mouse_cursor_mod = @import("render/mouse_cursor.zig");
const graphics = @import("api/graphics.zig");
const runtime_test = @import("runtime_test.zig");
const lua = @import("lua/lua.zig");

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
    asm volatile ("ldmxcsr %[v]"
        :
        : [v] "m" (value),
        : .{ .memory = true });
}

fn kernelMain() !void {
    serial.writeLine("ASTER KERNEL ENTRY");
    serial.writeLine("ASTER BOOT OK");

    const info = try boot.collect();
    printBootInfo(&info);

    idt.init();
    serial.writeLine("idt: init ok");
    pic.remap();
    serial.writeLine("pic: remap ok");

    var memory = try mem.Memory.init(&info);
    printMemoryInfo(&memory, &info);

    const alloc = memory.allocator();
    const test_buf = try alloc.alloc(u8, 64);
    defer alloc.free(test_buf);
    @memset(test_buf, 0xAB);
    if (test_buf[0] == 0xAB and test_buf[63] == 0xAB) {
        serial.writeLine("heap alloc test: ok");
    } else {
        serial.writeLine("heap alloc test: failed");
    }

    page_map.init(&memory.pfa, info.hhdm_offset);
    apic.init(info.hhdm_offset);
    ps2.init();
    serial.writeLine("apic: init ok");

    initGraphics(&info);

    const runtime = @import("api/runtime.zig");
    runtime.init(alloc);
    const program = runtime.spawn(.{ .kind = .Lua, .entry = "main.lua" }) catch |err| {
        serial.writeLine("runtime: lua spawn failed");
        return err;
    };
    _ = program;
    serial.writeLine("runtime: lua spawn ok");

    testKiDispatch();

    asm volatile ("sti" ::: .{ .memory = true });
    if (comptime runtime_test.enabled) {
        runtime_test.runAll();
    }
    serial.writeLine("timer test: waiting for ticks");
    eventLoop();
}

var fb_storage: ?framebuffer.Framebuffer = null;
var renderer: renderer_mod.Renderer = undefined;
var mouse_cursor: mouse_cursor_mod.MouseCursor = .{};

fn initGraphics(info: *const boot_info.BootInfo) void {
    const fb_info = info.framebuffer orelse {
        serial.writeLine("graphics: no framebuffer, console disabled");
        return;
    };
    fb_storage = framebuffer.Framebuffer.init(fb_info);
    renderer = renderer_mod.Renderer.init(&fb_storage.?);
    graphics.init(renderer);
    renderer.fillScreen(0x000000);
    mouse_cursor.init(&fb_storage.?, @intCast(fb_info.width / 2), @intCast(fb_info.height / 2));
    input.mouse_state.x = @divTrunc(@as(i32, @intCast(fb_info.width)), 2);
    input.mouse_state.y = @divTrunc(@as(i32, @intCast(fb_info.height)), 2);
    serial.writeLine("graphics: framebuffer ok");
}

fn testKiDispatch() void {
    const sys = @import("api/sys.zig");
    const msg = "ki dispatch test";
    const status = sys.dispatch(.Debug, .{
        .a = @intFromEnum(sys.DebugOp.write),
        .b = @intFromPtr(msg),
        .c = msg.len,
    });
    if (status == 0) {
        serial.writeLine("ki dispatch: ok");
    } else {
        serial.writeLine("ki dispatch: failed");
    }
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
            const runtime = @import("api/runtime.zig");
            runtime.reload();
            needs_render = true;
        }
        if (graphics.invalidate_requested) {
            needs_render = true;
            graphics.invalidate_requested = false;
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
                    const runtime = @import("api/runtime.zig");
                    runtime.reload();
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
        const runtime = @import("api/runtime.zig");
        runtime.reload();
    }
    if (fb_storage) |*fb| mouse_cursor.redraw(fb);
}

fn printMemoryInfo(memory: *mem.Memory, info: *const boot_info.BootInfo) void {
    var buf: [128]u8 = undefined;

    var usable_total: u64 = 0;
    for (info.memory_entries) |entry| {
        if (entry.type == .usable) usable_total += entry.length;
        if (entry.base >= 0xfe000000 and entry.base < 0xff000000) {
            const mm = std.fmt.bufPrint(&buf, "mm: base=0x{x} len=0x{x} type={}", .{ entry.base, entry.length, @intFromEnum(entry.type) }) catch return;
            serial.writeLine(mm);
        }
    }
    const ram = std.fmt.bufPrint(&buf, "usable ram: {} bytes ({} MiB)", .{ usable_total, usable_total / (1024 * 1024) }) catch return;
    serial.writeLine(ram);

    const free = std.fmt.bufPrint(&buf, "free pages: {}", .{memory.pfa.totalFreePages()}) catch return;
    serial.writeLine(free);
}

fn printBootInfo(info: *const boot_info.BootInfo) void {
    var buf: [128]u8 = undefined;

    const hhdm = std.fmt.bufPrint(&buf, "hhdm offset: 0x{x:0>16}", .{info.hhdm_offset}) catch return;
    serial.writeLine(hhdm);

    if (info.framebuffer) |fb_info| {
        const fb_line = std.fmt.bufPrint(&buf, "framebuffer: {}x{} pitch={} bpp={}", .{ fb_info.width, fb_info.height, fb_info.pitch, fb_info.bpp }) catch return;
        serial.writeLine(fb_line);
        const attr = cache_attr.framebufferCacheAttr(fb_info.address, info.hhdm_offset);
        const attr_line = std.fmt.bufPrint(&buf, "framebuffer cache: {s}", .{@tagName(attr)}) catch return;
        serial.writeLine(attr_line);
    } else {
        serial.writeLine("framebuffer: none");
    }
}

fn halt() noreturn {
    asm volatile ("cli" ::: .{ .memory = true });
    while (true) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}
