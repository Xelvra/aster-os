const std = @import("std");
const serial = @import("serial.zig");
const input_queue = @import("input_queue.zig");
const graphics = @import("api/graphics.zig");
const build_options = @import("build_options");

const debug_exit_port: u16 = 0x501;
const exit_pass: u8 = 0x31;
const exit_fail: u8 = 0x30;

pub const enabled = build_options.runtime_tests;

var failures: usize = 0;

const Test = struct {
    name: []const u8,
    func: *const fn () void,
};

fn testTimerTicks() void {
    var ticks_seen: u64 = 0;
    var spins: usize = 0;
    while (ticks_seen < 5 and spins < 100000) : (spins += 1) {
        while (input_queue.global.pop()) |event| {
            switch (event) {
                .timer_tick => ticks_seen += 1,
                .key => {},
                .mouse => {},
            }
        }
        asm volatile ("hlt" ::: .{ .memory = true });
    }
    expect(ticks_seen >= 5, "APIC timer produces tick events through the queue");
}

fn testMouseEvent() void {
    // Mouse packets live in their own queue, separate from keys/timers.
    while (input_queue.mouse.pop()) |_| {}

    input_queue.mouse.push(.{ .mouse = .{
        .dx = 3,
        .dy = -2,
        .left = true,
        .right = false,
        .middle = false,
    } });
    const event = input_queue.mouse.pop() orelse {
        expect(false, "mouse event popped from queue");
        return;
    };
    switch (event) {
        .mouse => |m| {
            expect(m.dx == 3, "mouse dx preserved");
            expect(m.dy == -2, "mouse dy preserved");
            expect(m.left, "mouse left button preserved");
        },
        else => expect(false, "event is a mouse event"),
    }
}

fn testMouseFloodDoesNotStarveKeys() void {
    // Drain whatever IRQs already queued.
    while (input_queue.global.pop()) |_| {}
    while (input_queue.mouse.pop()) |_| {}

    // Fill the mouse queue to its capacity, then push a key into the
    // global queue. A flood of mouse packets must not hide or delay keys.
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        input_queue.mouse.push(.{ .mouse = .{ .dx = 1, .dy = 0, .left = false, .right = false, .middle = false } });
    }
    input_queue.global.push(.{ .key = .{ .code = .a, .pressed = true } });

    const ev = input_queue.global.pop() orelse {
        expect(false, "key reachable despite mouse flood");
        return;
    };
    switch (ev) {
        .key => expect(true, "key survives behind a flood of mouse packets"),
        else => expect(false, "global queue still holds a key, not a mouse packet"),
    }
}

fn testMouseCursor() void {
    const r = graphics.renderer orelse {
        expect(false, "graphics renderer initialized");
        return;
    };
    const cursor = @import("render/mouse_cursor.zig");
    var cur = cursor.MouseCursor{};
    cur.init(r.fb, 20, 20);
    // Sprite offset (1,3) is the white core of the arrow.
    const core = r.fb.pixelColor(0xFFFFFF);
    expect(r.fb.getPixel(21, 23) == core, "cursor core drawn after init");
    cur.move(r.fb, 5, 0);
    expect(r.fb.getPixel(26, 23) == core, "cursor core drawn at new position");
    // Moving restores the old spot back to what was underneath (black).
    cur.redraw(r.fb);
    expect(r.fb.getPixel(21, 23) == 0, "old cursor position restored");
}

fn testFramebufferWrites() void {
    const r = graphics.renderer orelse {
        expect(false, "graphics renderer initialized");
        return;
    };
    r.fillScreen(0xFF0000);
    const pixel = r.fb.getPixel(0, 0);
    expect(pixel == 0x00FF0000, "fillScreen writes expected color to framebuffer");
    r.drawText("rt", 0, 0, 0xFFFFFF);
    expect(true, "drawText draws without fault");
}

fn testLuaBindings() void {
    const lua = @import("lua/lua.zig");
    expect(true, "lua state initialized and main.lua loaded without fault");
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    _ = L.lua_getglobal(lua_state, "gfx");
    expect(L.lua_istable(lua_state, -1), "gfx binding table is registered");
    _ = L.lua_pop(lua_state, 1);
    _ = L.lua_getglobal(lua_state, "runtime");
    expect(L.lua_istable(lua_state, -1), "runtime binding table is registered");
    _ = L.lua_pop(lua_state, 1);
    _ = L.lua_getglobal(lua_state, "power");
    expect(L.lua_istable(lua_state, -1), "power binding table is registered");
    _ = L.lua_pop(lua_state, 1);
    _ = L.lua_getglobal(lua_state, "render");
    expect(L.lua_isfunction(lua_state, -1), "render function is defined by main.lua");
    _ = L.lua_pop(lua_state, 1);
    _ = lua.callRender();
    expect(true, "lua render ran without fault");
}

fn testErrorContainment() void {
    // A Lua error inside update/render must be caught by lua_pcall and
    // reported as CallResult.err, not crash the kernel (spec/runtime.md §5).
    const lua = @import("lua/lua.zig");
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    // Replace render with a function that always raises.
    const script = "function render() error('boom') end";
    const load_status = L.luaL_loadstring(lua_state, script);
    expect(load_status == L.LUA_OK, "failing render script compiles");
    if (load_status == L.LUA_OK) {
        const run_status = L.lua_pcallk(lua_state, 0, 0, 0, 0, null);
        expect(run_status == L.LUA_OK, "failing render script runs");
    }
    const result = lua.callRender();
    expect(result == lua.CallResult.err, "failing render returns CallResult.err");
    expect(true, "kernel survives a lua render error");
    // Restore the real shell by hot-reloading it.
    const runtime = @import("api/runtime.zig");
    runtime.reload();
    _ = lua.callRender();
    expect(true, "shell reloaded after error containment");
}

fn testLiveThemeChange() void {
    // A theme change typed into the REPL must repaint without losing the
    // shell and without faulting render (spec/runtime.md §5a). The bar
    // height is read live from the theme, so a change takes effect on the
    // next render and mouse hit-testing follows it.
    const lua = @import("lua/lua.zig");
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    const script = "theme.background = 0x112233; theme.bar.height = 48; theme.wm.gap_out = 12";
    const load_status = L.luaL_loadstring(lua_state, script);
    expect(load_status == L.LUA_OK, "live theme script compiles");
    if (load_status == L.LUA_OK) {
        const run_status = L.lua_pcallk(lua_state, 0, 0, 0, 0, null);
        expect(run_status == L.LUA_OK, "live theme script runs");
    }
    const result = lua.callRender();
    expect(result == lua.CallResult.ok, "render stays healthy after a live theme change");
    // Restore the real shell so later tests start clean.
    const runtime = @import("api/runtime.zig");
    runtime.reload();
    _ = lua.callRender();
    expect(true, "shell reloaded after live theme change");
}

fn testRenderThroughput() void {
    const idt = @import("cpu/idt.zig");
    const lua = @import("lua/lua.zig");
    // Measure how many full REPL renders Lua can do over a fixed window of
    // APIC ticks. Higher is better; regressions show up after render changes.
    const window_ticks: u64 = 10;
    const start_tick = idt.tick_counter.load(.monotonic);
    var count: u32 = 0;
    while (idt.tick_counter.load(.monotonic) < start_tick + window_ticks) {
        _ = lua.callRender();
        count +%= 1;
        if (count > 1000000) break;
    }
    var buf: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "render throughput: {d} renders/{d} ticks", .{ count, window_ticks }) catch "throughput";
    serial.writeLine(line);
    expect(count > 0, "render throughput measured");
}

const tests = [_]Test{
    .{ .name = "timer tick + event queue", .func = testTimerTicks },
    .{ .name = "mouse event queue", .func = testMouseEvent },
    .{ .name = "mouse flood does not starve keys", .func = testMouseFloodDoesNotStarveKeys },
    .{ .name = "mouse cursor overlay", .func = testMouseCursor },
    .{ .name = "framebuffer write + drawText", .func = testFramebufferWrites },
    .{ .name = "lua bindings + render", .func = testLuaBindings },
    .{ .name = "live theme change (render stays healthy)", .func = testLiveThemeChange },
    .{ .name = "error containment (lua error)", .func = testErrorContainment },
    .{ .name = "render throughput", .func = testRenderThroughput },
};

pub fn runAll() noreturn {
    if (!comptime enabled) @compileError("runtime tests are not enabled");
    serial.writeLine("RUNTIME TESTS START");
    for (tests) |t| {
        runOne(t);
    }
    if (failures == 0) {
        serial.writeLine("RUNTIME TESTS PASS");
        exitQemu(exit_pass);
    } else {
        serial.writeLine("RUNTIME TESTS FAIL");
        exitQemu(exit_fail);
    }
}

fn runOne(t: Test) void {
    serial.writeLine(t.name);
    t.func();
}

pub fn expect(cond: bool, name: []const u8) void {
    if (cond) {
        serial.writeLine("  ok");
    } else {
        failures += 1;
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "  FAIL: {s}", .{name}) catch "  FAIL";
        serial.writeLine(line);
    }
}

fn exitQemu(code: u8) noreturn {
    asm volatile (
        \\outb %[val], %[port]
        :
        : [val] "{al}" (code),
          [port] "{dx}" (debug_exit_port),
        : .{ .memory = true });
    while (true) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}
