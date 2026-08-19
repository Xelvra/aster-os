const std = @import("std");
const serial = @import("serial.zig");
const input_service = @import("input/service.zig");
const graphics = @import("api/graphics.zig");
const mem = @import("mem/mem.zig");
const sync = @import("sched/sync.zig");
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
        while (input_service.popKernelEvent()) |event| {
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

fn testRtcWallClock() void {
    // The CMOS RTC is read at boot and seeds the wall clock; QEMU's mc146818
    // is always present, so ofDayMs() is a real time of day. A broken RTC read
    // (always null) would leave it at 0 and this test would fail.
    const time_mod = @import("time.zig");
    const day_ms = time_mod.ofDayMs();
    expect(day_ms > 0 and day_ms < 24 * 60 * 60 * 1000, "RTC-seeded wall clock is a plausible time of day");
    // The wall clock must advance. The wait is bounded by iterations so a
    // stalled ms() (PIT calibration failed, ms() == 0) is reported as a
    // failure instead of hanging the test suite.
    var spins: usize = 0;
    const before = time_mod.ms();
    while (time_mod.ms() - before < 1100) : (spins += 1) {
        if (spins > 100_000_000) break;
    }
    const day_ms2 = time_mod.ofDayMs();
    expect(day_ms2 > day_ms, "wall clock advances over time");
}

fn testMouseEvent() void {
    // Mouse packets live in their own queue, separate from keys/timers.
    while (input_service.popMouseEvent()) |_| {}

    input_service.pushMouseEvent(.{
        .dx = 3,
        .dy = -2,
        .left = true,
        .right = false,
        .middle = false,
    });
    const event = input_service.popMouseEvent() orelse {
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

fn testMouseWheel() void {
    const service = @import("input/service.zig");
    const lua_mod = @import("lua/lua.zig");
    _ = service.mouseWheel(); // drain any deltas from earlier boot activity

    // The service accumulator sums per-packet deltas and drains on read.
    service.addWheel(2);
    service.addWheel(-1);
    expect(service.mouseWheel() == 1, "wheel accumulator sums deltas");
    expect(service.mouseWheel() == 0, "wheel accumulator drains on read");

    // The Lua binding reads the same accumulator (positive = wheel up).
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua_mod.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    service.addWheel(3);
    const load_status = L.luaL_loadstring(lua_state, "return input.mouse_wheel()");
    expect(load_status == L.LUA_OK, "wheel check script compiles");
    if (load_status != L.LUA_OK) return;
    const run_status = L.lua_pcallk(lua_state, 0, 1, 0, 0, null);
    expect(run_status == L.LUA_OK, "wheel check script runs");
    if (run_status != L.LUA_OK) {
        L.lua_pop(lua_state, 1);
        return;
    }
    const wheel = L.lua_tointegerx(lua_state, -1, null);
    L.lua_pop(lua_state, 1);
    expect(wheel == 3, "Lua input.mouse_wheel() reads the accumulator");
    expect(service.mouseWheel() == 0, "the Lua read drained the accumulator");
}

fn testMouseWheelHardware() void {
    // The PS/2 driver must detect the scroll wheel on the attached mouse
    // (QEMU's ps2 mouse reports ID 3 after the 200/100/80 sequence). Without
    // detection the wheel never reaches the input subsystem — a regression the
    // host tests cannot see (they only cover the packet decoder).
    const ps2 = @import("drivers/ps2.zig");
    if (!ps2.mousePresent()) {
        expect(true, "mouse wheel hardware test skipped (no PS/2 mouse attached)");
        return;
    }
    expect(ps2.mouseHasWheel(), "PS/2 mouse supports the wheel (Intellimouse 4-byte)");
}

fn testMouseWheelPacketPath() void {
    // End-to-end data path from a decoded wheel packet to Lua: a packet with a
    // wheel delta is pushed into the mouse queue (as the PS/2 driver does),
    // consumed exactly like the event loop (main.zig processMouse pops and
    // calls addWheel), and the Lua input.mouse_wheel() binding delivers it.
    const service = @import("input/service.zig");
    const lua_mod = @import("lua/lua.zig");
    _ = service.mouseWheel(); // drain any deltas from earlier boot activity

    input_service.pushMouseEvent(.{
        .dx = 3,
        .dy = -2,
        .left = false,
        .right = false,
        .middle = false,
        .wheel = -2,
    });
    const event = input_service.popMouseEvent() orelse {
        expect(false, "wheel packet popped from the mouse queue");
        return;
    };
    switch (event) {
        .mouse => |m| {
            expect(m.wheel == -2, "wheel delta preserved through the queue");
            service.addWheel(m.wheel); // exactly what the event loop does
        },
        else => {
            expect(false, "event is a mouse event");
            return;
        },
    }
    expect(service.mouseWheel() == -2, "event loop accumulated the wheel delta");

    // The Lua binding the shell's handle_mouse reads sees the same value.
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua_mod.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    service.addWheel(-1);
    const load_status = L.luaL_loadstring(lua_state, "return input.mouse_wheel()");
    expect(load_status == L.LUA_OK, "wheel path check script compiles");
    if (load_status != L.LUA_OK) return;
    const run_status = L.lua_pcallk(lua_state, 0, 1, 0, 0, null);
    expect(run_status == L.LUA_OK, "wheel path check script runs");
    if (run_status != L.LUA_OK) {
        L.lua_pop(lua_state, 1);
        return;
    }
    const wheel = L.lua_tointegerx(lua_state, -1, null);
    L.lua_pop(lua_state, 1);
    expect(wheel == -1, "Lua input.mouse_wheel() delivers the accumulated delta");
}

fn testMouseFloodDoesNotStarveKeys() void {
    // Drain whatever IRQs already queued.
    while (input_service.popKernelEvent()) |_| {}
    while (input_service.popMouseEvent()) |_| {}

    // Fill the mouse queue to its capacity, then push a key into the
    // global queue. A flood of mouse packets must not hide or delay keys.
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        input_service.pushMouseEvent(.{ .dx = 1, .dy = 0, .left = false, .right = false, .middle = false });
    }
    input_service.pushKeyEvent(.{ .code = .a, .pressed = true });

    // The APIC timer keeps firing behind the test and pushes timer_tick
    // events into the global queue; skip them until the key surfaces. The
    // loop is bounded by the queue itself — an empty queue means the key
    // was lost, which is exactly what this test must not allow.
    while (input_service.popKernelEvent()) |ev| {
        switch (ev) {
            .key => {
                expect(true, "key survives behind a flood of mouse packets");
                return;
            },
            .timer_tick, .mouse => {},
        }
    }
    expect(false, "key reachable despite mouse flood");
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
    _ = L.lua_getglobal(lua_state, "render");
    expect(L.lua_isfunction(lua_state, -1), "render function is defined by main.lua");
    _ = L.lua_pop(lua_state, 1);
    _ = lua.callRender();
    expect(true, "lua render ran without fault");
}

fn testDbgLib() void {
    // The Lua debug library is opened as 'dbg' (M6.1.9) so the KI debug
    // module keeps the 'debug' name. dbg.traceback() must exist and the
    // Lua library must not leak into 'debug'.
    const lua = @import("lua/lua.zig");
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    _ = L.lua_getglobal(lua_state, "dbg");
    expect(L.lua_istable(lua_state, -1), "dbg library table is registered");
    _ = L.lua_getfield(lua_state, -1, "traceback");
    expect(L.lua_isfunction(lua_state, -1), "dbg.traceback is a function");
    _ = L.lua_pop(lua_state, 1);
    _ = L.lua_pop(lua_state, 1);

    _ = L.lua_getglobal(lua_state, "debug");
    expect(L.lua_istable(lua_state, -1), "KI debug module still registered as 'debug'");
    _ = L.lua_getfield(lua_state, -1, "write");
    expect(L.lua_isfunction(lua_state, -1), "KI debug.write still present");
    _ = L.lua_pop(lua_state, 1);
    _ = L.lua_getfield(lua_state, -1, "traceback");
    expect(L.lua_isnil(lua_state, -1), "Lua debug library did not leak into 'debug'");
    _ = L.lua_pop(lua_state, 1);
    _ = L.lua_pop(lua_state, 1);
}

fn testLayoutSwitchFromLua() void {
    // Full chain Lua -> binding -> KI dispatch -> input/service -> layout
    // registry (ADR-024). set_layout + layout_name must round-trip, and an
    // unknown layout must be rejected without changing the active one.
    const lua = @import("lua/lua.zig");
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    const script =
        \\if not input.set_layout("cz") then error("set_layout('cz') failed") end
        \\if input.layout_name() ~= "cz" then error("layout_name ~= 'cz'") end
        \\if input.set_layout("nope") then error("set_layout('nope') should fail") end
        \\if input.layout_name() ~= "cz" then error("layout changed after failed set") end
        \\if not input.set_layout("us") then error("set_layout('us') failed") end
        \\if input.layout_name() ~= "us" then error("layout_name ~= 'us'") end
    ;
    const load_status = L.luaL_loadstring(lua_state, script);
    expect(load_status == L.LUA_OK, "layout switch script compiles");
    if (load_status == L.LUA_OK) {
        const run_status = L.lua_pcallk(lua_state, 0, 0, 0, 0, null);
        expect(run_status == L.LUA_OK, "layout switch script runs");
    }
    _ = lua.callRender();
    expect(true, "shell healthy after layout switch");
}

fn testLayoutMappingBehaviour() void {
    // Behaviour check: switching the active layout changes how a physical
    // key maps to a character (CZ: Y->z, Z->y). Goes through the service
    // boundary, the same one the KI and the Lua shell use — the layout
    // registry itself stays internal.
    const lua = @import("lua/lua.zig");
    expect(input_service.setLayout("cz"), "service setLayout cz");
    expect(std.mem.eql(u8, input_service.layoutName(), "cz"), "service layoutName cz");
    expect(input_service.mapChar(.y, .{}) == 'z', "CZ: physical Y maps to z");
    expect(input_service.mapChar(.z, .{}) == 'y', "CZ: physical Z maps to y");
    expect(input_service.setLayout("us"), "service setLayout us");
    expect(input_service.mapChar(.y, .{}) == 'y', "US: physical Y maps to y");
    _ = lua.callRender();
    expect(true, "shell healthy after mapping behaviour check");
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

fn testLuaBindingAdversarial() void {
    // Audit 2026-08-15: these single-line Lua inputs used to panic the kernel
    // (unchecked @intCast in the bindings, framebuffer negative coordinates,
    // libc strtod/vsnprintf overflow). They must now be contained — either a
    // Lua error or a clamped value — never a kernel halt. Each statement is
    // wrapped in pcall where a binding returns nil+error.
    const lua = @import("lua/lua.zig");
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    const script =
        \\-- Each statement must not panic the kernel; a contained Lua error
        \\-- (pcall) is just as good as a returned value. Reaching "PASS" proves
        \\-- the kernel survived all of them.
        \\pcall(function() gfx.draw_rect(0, 0, -5, 2, 0) end)
        \\pcall(function() gfx.draw_rect(0, 0, 4294967296, 2, 0) end)
        \\pcall(function() gfx.fill_screen(4294967296) end)
        \\pcall(function() gfx.round_rect(-1, 0, 10, 10, 2, 0) end)
        \\pcall(function() gfx.gradient_border(-5, 0, 10, 10, 2, 0, 0) end)
        \\pcall(function() file.read(-1, -1) end)
        \\pcall(function() file.truncate(-1, -1) end)
        \\pcall(function() file.close(-1) end)
        \\pcall(function() tonumber("1e9999999999") end)
        \\pcall(function() string.format("%.2147483648f", 0) end)
        \\pcall(function() string.format("%18446744073709551615d", 5) end)
        \\return "PASS"
    ;
    const load_status = L.luaL_loadstring(lua_state, script);
    expect(load_status == L.LUA_OK, "adversarial binding script compiles");
    if (load_status != L.LUA_OK) return;
    const run_status = L.lua_pcallk(lua_state, 0, 1, 0, 0, null);
    expect(run_status == L.LUA_OK, "adversarial binding script runs");
    if (run_status != L.LUA_OK) {
        var status_buf: [16]u8 = undefined;
        const status_line = std.fmt.bufPrint(&status_buf, "adversarial status: {d}", .{run_status}) catch "adversarial status";
        serial.writeLine(status_line);
        var err_len: usize = 0;
        const msg = L.lua_tolstring(lua_state, -1, &err_len);
        if (msg) |m| {
            serial.write("adversarial error: ");
            serial.writeLine(std.mem.span(m));
        } else {
            serial.writeLine("adversarial error: <non-string>");
        }
        L.lua_pop(lua_state, 1);
        return;
    }
    var len: usize = 0;
    const str = L.lua_tolstring(lua_state, -1, &len);
    const result: []const u8 = @as([*]const u8, @ptrCast(str))[0..len];
    if (len != 4 or !std.mem.eql(u8, result, "PASS")) {
        serial.write("adversarial result: ");
        serial.writeLine(result);
    }
    expect(len == 4 and std.mem.eql(u8, result, "PASS"), "kernel survives adversarial binding inputs");
    _ = L.lua_pop(lua_state, 1);
}

fn testInfiniteLoopContainment() void {
    // An infinite loop in the shell must not freeze the system: the
    // instruction budget (lua.zig, LUA_MASKCOUNT) raises a Lua error that
    // the same lua_pcall as a runtime error catches, so callUpdate returns
    // CallResult.err and the event loop hot-reloads (spec/runtime.md §5,
    // brief Task 7b).
    const lua = @import("lua/lua.zig");
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    const script = "function update() while true do end end";
    const load_status = L.luaL_loadstring(lua_state, script);
    expect(load_status == L.LUA_OK, "infinite-loop script compiles");
    if (load_status == L.LUA_OK) {
        const run_status = L.lua_pcallk(lua_state, 0, 0, 0, 0, null);
        expect(run_status == L.LUA_OK, "infinite-loop script runs");
    }
    const result = lua.callUpdate();
    expect(result == lua.CallResult.err, "infinite loop returns CallResult.err");
    expect(true, "kernel survives a lua infinite loop");
    // Restore the real shell so later tests start clean.
    const runtime = @import("api/runtime.zig");
    runtime.reload();
    _ = lua.callRender();
    expect(true, "shell reloaded after infinite-loop containment");
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

fn testLuaTriggeredReload() void {
    // A reload requested from inside a Lua call (session menu "Logout")
    // must not close the lua_State mid-call: the binding only sets a
    // flag, the event loop performs the reload outside the Lua frame.
    const lua = @import("lua/lua.zig");
    const L = @import("lua/cimport.zig").c;
    const runtime = @import("api/runtime.zig");
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    const script = "runtime.reload()";
    const load_status = L.luaL_loadstring(lua_state, script);
    expect(load_status == L.LUA_OK, "reload script compiles");
    if (load_status == L.LUA_OK) {
        const run_status = L.lua_pcallk(lua_state, 0, 0, 0, 0, null);
        expect(run_status == L.LUA_OK, "reload from Lua returns without closing the state");
    }
    expect(runtime.reloadRequested(), "reload flag set, not performed yet");
    _ = lua.callRender();
    expect(true, "lua state survives a reload request");
    // The event loop performs the deferred reload.
    runtime.performReload();
    expect(!runtime.reloadRequested(), "reload performed and flag cleared");
    _ = lua.callRender();
    expect(true, "shell healthy after deferred reload");
}

fn testRenderThroughput() void {
    const time = @import("time.zig");
    const lua = @import("lua/lua.zig");
    // Measure how many full REPL renders Lua can do over a fixed window of
    // APIC ticks. Higher is better; regressions show up after render changes.
    const window_ticks: u64 = 10;
    const start_tick = time.ticks();
    var count: u32 = 0;
    while (time.ticks() < start_tick + window_ticks) {
        _ = lua.callRender();
        count +%= 1;
        if (count > 1000000) break;
    }
    var buf: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "render throughput: {d} renders/{d} ticks", .{ count, window_ticks }) catch "throughput";
    serial.writeLine(line);
    expect(count > 0, "render throughput measured");
}

var task_a_counter = std.atomic.Value(u64).init(0);
var task_b_counter = std.atomic.Value(u64).init(0);
var task_stop = std.atomic.Value(bool).init(false);
var task_a_parked = std.atomic.Value(bool).init(false);
var task_b_parked = std.atomic.Value(bool).init(false);

/// Test-only handle to the kernel heap allocator shared between spawned tasks
/// (they have no `std.mem.Allocator` of their own). Captured in `runAll`.
var concurrent_alloc: std.mem.Allocator = undefined;
var alloc_error = std.atomic.Value(bool).init(false);

fn taskA() callconv(.c) noreturn {
    while (true) {
        if (task_stop.load(.monotonic)) {
            task_a_parked.store(true, .monotonic);
            while (true) {
                asm volatile ("hlt" ::: .{ .memory = true });
            }
        }
        _ = task_a_counter.fetchAdd(1, .monotonic);
        // Allocate on the shared heap: with the interrupt guard (ADR-017) a
        // preemption mid-allocation can no longer corrupt the free list.
        const chunk = concurrent_alloc.alloc(u8, 64) catch {
            alloc_error.store(true, .monotonic);
            continue;
        };
        @memset(chunk, 0xAA);
        concurrent_alloc.free(chunk);
    }
}

fn taskB() callconv(.c) noreturn {
    while (true) {
        if (task_stop.load(.monotonic)) {
            task_b_parked.store(true, .monotonic);
            while (true) {
                asm volatile ("hlt" ::: .{ .memory = true });
            }
        }
        _ = task_b_counter.fetchAdd(1, .monotonic);
        const chunk = concurrent_alloc.alloc(u8, 128) catch {
            alloc_error.store(true, .monotonic);
            continue;
        };
        @memset(chunk, 0x55);
        concurrent_alloc.free(chunk);
    }
}

fn testPreemptiveScheduler() void {
    // Two native kernel tasks on the shared address space, each spinning on
    // its own counter and hammering the shared heap (brief Task 2). The APIC
    // timer IRQ preempts whoever is running and the round-robin scheduler
    // switches — both counters must advance. That is the only reliable proof
    // of real preemption, not cooperative yield.
    const sched = @import("sched/task.zig");
    const time = @import("time.zig");

    task_a_counter.store(0, .monotonic);
    task_b_counter.store(0, .monotonic);
    task_stop.store(false, .monotonic);
    task_a_parked.store(false, .monotonic);
    task_b_parked.store(false, .monotonic);
    alloc_error.store(false, .monotonic);

    _ = sched.spawnTask(taskA) catch {
        expect(false, "scheduler spawns task A");
        return;
    };
    _ = sched.spawnTask(taskB) catch {
        expect(false, "scheduler spawns task B");
        return;
    };

    const deadline = time.ticks() + 30;
    while (time.ticks() < deadline) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
    task_stop.store(true, .monotonic);
    var spins: usize = 0;
    while ((!task_a_parked.load(.monotonic) or !task_b_parked.load(.monotonic)) and spins < 1000000) : (spins += 1) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
    expect(task_a_counter.load(.monotonic) > 0, "task A counter advanced under preemption");
    expect(task_b_counter.load(.monotonic) > 0, "task B counter advanced under preemption");
    expect(task_a_parked.load(.monotonic) and task_b_parked.load(.monotonic), "both tasks parked cleanly");
    expect(!alloc_error.load(.monotonic), "concurrent heap allocation has no error");

    // The heap must still be usable after three contexts (both tasks + main)
    // hammered it concurrently.
    const probe = concurrent_alloc.alloc(u8, 32) catch {
        expect(false, "heap usable after concurrent allocation");
        return;
    };
    concurrent_alloc.free(probe);
    expect(true, "heap usable after concurrent allocation");
}

var sleeper_blocked = std.atomic.Value(bool).init(false);
var sleeper_resumed = std.atomic.Value(bool).init(false);
fn sleepingTask() callconv(.c) noreturn {
    const sched = @import("sched/task.zig");
    sleeper_blocked.store(true, .monotonic);
    sched.sleepMs(100);
    sleeper_resumed.store(true, .monotonic);
    while (true) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}

fn testBlockingTaskSleep() void {
    // A spawned task that calls sched.sleepMs must be descheduled until its
    // deadline: the main context keeps running (ticks advance) while the
    // sleeper stays blocked, and the sleeper resumes only after the sleep.
    const sched = @import("sched/task.zig");
    const time = @import("time.zig");

    sleeper_blocked.store(false, .monotonic);
    sleeper_resumed.store(false, .monotonic);
    _ = sched.spawnTask(sleepingTask) catch {
        expect(false, "scheduler spawns sleeping task");
        return;
    };

    var spins: usize = 0;
    const spawn_start = time.ticks();
    while (!sleeper_blocked.load(.monotonic) and time.ticks() < spawn_start + 200 and spins < 1000000) : (spins += 1) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
    expect(sleeper_blocked.load(.monotonic), "sleeping task starts and blocks");

    // The sleeper asked for 100 ticks; within the first 20 the main context
    // must keep running while the sleeper stays blocked.
    const block_start = time.ticks();
    spins = 0;
    while (time.ticks() < block_start + 20 and spins < 1000000) : (spins += 1) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
    expect(!sleeper_resumed.load(.monotonic), "blocked task does not run during its sleep");

    // The sleeper must resume shortly after its deadline (safety margin for
    // scheduling jitter).
    const deadline = time.ticks() + 200;
    spins = 0;
    while (!sleeper_resumed.load(.monotonic) and time.ticks() < deadline and spins < 1000000) : (spins += 1) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
    expect(sleeper_resumed.load(.monotonic), "task resumes after its sleep deadline");
}

var sem_wait_ran = std.atomic.Value(bool).init(false);
var sem: sync.Semaphore = sync.Semaphore.init(0);
fn semWaiterTask() callconv(.c) noreturn {
    sem.wait();
    sem_wait_ran.store(true, .monotonic);
    while (true) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}

fn testSemaphore() void {
    // A task that blocks on a semaphore must not run until another task
    // signals; after the signal it resumes and records that it ran. Proves the
    // blocking wait/wake path (ADR-017), not just time-based sleep.
    const sched = @import("sched/task.zig");
    const sync_mod = @import("sched/sync.zig");
    sem = sync_mod.Semaphore.init(0);
    sem_wait_ran.store(false, .monotonic);
    _ = sched.spawnTask(semWaiterTask) catch {
        expect(false, "scheduler spawns semaphore waiter");
        return;
    };

    // Give the waiter a chance to run and block (waiter_count becomes 1).
    var spins: usize = 0;
    while (spins < 1000000) : (spins += 1) {
        asm volatile ("hlt" ::: .{ .memory = true });
        if (sem.waiter_count == 1) break;
    }
    expect(sem.waiter_count == 1, "semaphore waiter blocks");
    expect(!sem_wait_ran.load(.monotonic), "blocked waiter does not run before signal");

    sem.signal();
    spins = 0;
    while (!sem_wait_ran.load(.monotonic) and spins < 1000000) : (spins += 1) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
    expect(sem_wait_ran.load(.monotonic), "semaphore waiter resumes after signal");
    expect(sem.waiter_count == 0 and sem.count == 0, "signal handed the slot, count back to zero");
}

var mutex_obj = sync.Mutex.init();
var mutex_ran = std.atomic.Value(bool).init(false);
var mutex_released = std.atomic.Value(bool).init(false);
fn mutexWaiterTask() callconv(.c) noreturn {
    mutex_obj.lock(); // blocks while the main task owns it
    mutex_ran.store(true, .monotonic);
    // Self-relock: a task that locks a mutex it already owns must deadlock
    // (block forever) instead of silently nesting — a single unlock would
    // otherwise release the outer critical section unprotected (regression,
    // ec879d1).
    mutex_obj.lock();
    mutex_released.store(true, .monotonic);
    while (true) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}

fn testMutex() void {
    // A task that blocks on an owned mutex must not run until the owner
    // unlocks (which hands the lock to the waiter); the waiter then self-
    // relocks, which must deadlock it (not nest), so the mutex stays owned.
    const sched = @import("sched/task.zig");
    mutex_obj = sync.Mutex.init();
    mutex_obj.lock(); // main owns it
    mutex_ran.store(false, .monotonic);
    mutex_released.store(false, .monotonic);
    _ = sched.spawnTask(mutexWaiterTask) catch {
        expect(false, "scheduler spawns mutex waiter");
        return;
    };
    var spins: usize = 0;
    while (spins < 1000000) : (spins += 1) {
        asm volatile ("hlt" ::: .{ .memory = true });
        if (mutex_obj.waiter_count == 1) break;
    }
    expect(mutex_obj.waiter_count == 1, "mutex waiter blocks on an owned lock");
    expect(!mutex_ran.load(.monotonic), "blocked waiter does not run before unlock");
    mutex_obj.unlock();
    spins = 0;
    while (!mutex_ran.load(.monotonic) and spins < 1000000) : (spins += 1) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
    expect(mutex_ran.load(.monotonic), "mutex waiter resumed with ownership");
    // The waiter then self-relocked: it must be blocked forever (never reach
    // the release) and the mutex must still be owned by it. A short hlt spin
    // (~1 s at the APIC tick rate) gives the waiter time to reach the
    // self-relock; it must never complete the release.
    spins = 0;
    while (spins < 1000) : (spins += 1) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
    expect(!mutex_released.load(.monotonic), "self-relock deadlocks instead of nesting");
    expect(mutex_obj.locked, "self-relocked mutex stays locked");
    expect(mutex_obj.owner != 0, "self-relocked mutex owner is the waiter");
}

var event_group = sync.EventGroup.init(0);
var evg_ran = std.atomic.Value(bool).init(false);
fn evgWaiterTask() callconv(.c) noreturn {
    event_group.wait(0b101, .any); // wants bit 0 or bit 2
    evg_ran.store(true, .monotonic);
    while (true) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}

fn testEventGroup() void {
    const sched = @import("sched/task.zig");
    event_group = sync.EventGroup.init(0);
    evg_ran.store(false, .monotonic);
    _ = sched.spawnTask(evgWaiterTask) catch {
        expect(false, "scheduler spawns event waiter");
        return;
    };
    var spins: usize = 0;
    while (spins < 1000000) : (spins += 1) {
        asm volatile ("hlt" ::: .{ .memory = true });
        if (event_group.waiter_count == 1) break;
    }
    expect(event_group.waiter_count == 1, "event waiter blocks");
    event_group.set(0b010); // not wanted -> no wake
    expect(!evg_ran.load(.monotonic), "unmatched set does not wake the waiter");
    event_group.set(0b100); // bit 2 is wanted -> wake
    spins = 0;
    while (!evg_ran.load(.monotonic) and spins < 1000000) : (spins += 1) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
    expect(evg_ran.load(.monotonic), "event waiter resumes after a matching set");
    expect(event_group.flags == 0b110, "event flags accumulate");
}

var mq_buf: [8]u8 = undefined;
var message_queue = sync.MessageQueue.init(&mq_buf);
var mq_produced = std.atomic.Value(bool).init(false);
var mq_done = std.atomic.Value(bool).init(false);
var mq_got = false;
fn mqConsumerTask() callconv(.c) noreturn {
    var out: [2]u8 = undefined;
    message_queue.get(&out); // blocks until the producer puts
    mq_got = out[0] == 'A' and out[1] == 'B';
    mq_done.store(true, .monotonic);
    while (true) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}
fn mqProducerTask() callconv(.c) noreturn {
    message_queue.put("AB"); // wakes the blocked consumer
    mq_produced.store(true, .monotonic);
    while (true) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}

fn testMessageQueue() void {
    const sched = @import("sched/task.zig");
    message_queue = sync.MessageQueue.init(&mq_buf);
    mq_produced.store(false, .monotonic);
    mq_done.store(false, .monotonic);
    mq_got = false;
    _ = sched.spawnTask(mqConsumerTask) catch {
        expect(false, "scheduler spawns queue consumer");
        return;
    };
    var spins: usize = 0;
    while (spins < 1000000) : (spins += 1) {
        asm volatile ("hlt" ::: .{ .memory = true });
        if (message_queue.get_waiter_count == 1) break;
    }
    expect(message_queue.get_waiter_count == 1, "consumer blocks on an empty queue");
    _ = sched.spawnTask(mqProducerTask) catch {
        expect(false, "scheduler spawns queue producer");
        return;
    };
    spins = 0;
    while (!mq_done.load(.monotonic) and spins < 1000000) : (spins += 1) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
    expect(mq_got, "consumer received the producer's message");
    expect(mq_produced.load(.monotonic), "producer completed its put");
    expect(message_queue.size == 0, "queue drained after the get");
}

var task_error_recorded = std.atomic.Value(bool).init(false);
fn erroringTask() anyerror!void {
    return error.TaskFailed;
}
fn onTaskError(_: anyerror) void {
    task_error_recorded.store(true, .monotonic);
}

fn testTaskErrorHandler() void {
    const sched = @import("sched/task.zig");
    task_error_recorded.store(false, .monotonic);
    _ = sched.spawnTaskChecked(erroringTask, onTaskError) catch {
        expect(false, "scheduler spawns erroring task");
        return;
    };
    var spins: usize = 0;
    while (!task_error_recorded.load(.monotonic) and spins < 1000000) : (spins += 1) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
    expect(task_error_recorded.load(.monotonic), "task error handler ran on a task error");
}

fn testPerProgramIsolation() void {
    // M7 per-program isolation: a spawned Lua program runs in its own state.
    // An infinite loop in the entry is contained by the instruction budget and
    // cannot touch the shell; a program whose update() errors is dropped; a
    // healthy program ticks and its side effect (a file) is visible from the
    // shell state.
    const lua_mod = @import("lua/lua.zig");
    const storage = @import("api/storage.zig");
    if (!storage.isMounted()) {
        expect(true, "per-program isolation test skipped (no disk attached)");
        return;
    }
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua_mod.getState() orelse {
        expect(false, "lua state exists");
        return;
    };

    // 1. An infinite-loop program must fail at spawn (budget) and the shell
    //    must stay healthy.
    const inf_result = lua_mod.spawnProgram("while true do end", "infinite");
    const inf_contained = if (inf_result) |_| false else |err| err == error.ProgramRunFailed;
    expect(inf_contained, "infinite-loop program contained at spawn");
    const shell_ok = lua_mod.callUpdate() != lua_mod.CallResult.err;
    expect(shell_ok, "shell unaffected after a contained infinite-loop program");

    // 2. A program whose update() errors is dropped, not the whole shell.
    const boom = lua_mod.spawnProgram("function update() error('boom') end", "boom") catch {
        expect(false, "erroring program spawns");
        return;
    };
    expect(lua_mod.programAlive(boom), "erroring program alive after spawn");
    lua_mod.tickPrograms();
    expect(!lua_mod.programAlive(boom), "erroring program dropped after its update failed");
    const shell_ok2 = lua_mod.callUpdate() != lua_mod.CallResult.err;
    expect(shell_ok2, "shell unaffected after an erroring program was dropped");

    // 3. A healthy program ticks: its update creates a file, visible from the
    //    shell state (shared bindings, separate lua_States).
    const prog = lua_mod.spawnProgram(
        "function update() file.create('/prog_tick.txt') end",
        "tick",
    ) catch {
        expect(false, "healthy program spawns");
        return;
    };
    expect(lua_mod.programAlive(prog), "healthy program alive after spawn");
    lua_mod.tickPrograms();
    const script =
        \\local h = file.open("/prog_tick.txt")
        \\if h then file.close(h); file.remove("/prog_tick.txt") end
        \\return h ~= nil
    ;
    const load_status = L.luaL_loadstring(lua_state, script);
    expect(load_status == L.LUA_OK, "isolation check script compiles");
    if (load_status != L.LUA_OK) return;
    const run_status = L.lua_pcallk(lua_state, 0, 1, 0, 0, null);
    expect(run_status == L.LUA_OK, "isolation check script runs");
    if (run_status != L.LUA_OK) {
        L.lua_pop(lua_state, 1);
        return;
    }
    const ticked = L.lua_toboolean(lua_state, -1) == 1;
    expect(ticked, "healthy program's update ran and its side effect is visible");
    _ = L.lua_pop(lua_state, 1);
}

fn testSpawnWiring() void {
    // runtime.spawn for a Lua program AFTER the shell must route through
    // lua.spawnProgram (its own lua_State), not lua.runMain (the shared shell
    // state): a program spawns isolated, ticks via tickPrograms, its update
    // side effect is visible from the shell state, and a missing program file
    // fails cleanly instead of reloading the shell.
    const runtime = @import("api/runtime.zig");
    const lua_mod = @import("lua/lua.zig");
    const storage = @import("api/storage.zig");
    if (!storage.isMounted()) {
        expect(true, "runtime.spawn wiring test skipped (no disk attached)");
        return;
    }

    const prog = runtime.spawn(.{ .kind = .Lua, .entry = "probe.lua" }) catch {
        expect(false, "runtime.spawn launches a Lua program through the isolated path");
        return;
    };
    expect(lua_mod.programAlive(@intCast(prog.handle)), "spawned program alive in its own state");
    lua_mod.tickPrograms();

    const L = @import("lua/cimport.zig").c;
    const shell_state = lua_mod.getState() orelse {
        expect(false, "shell state exists");
        return;
    };
    const script =
        \\local h = file.open("/probe_wiring.txt")
        \\if h then file.close(h); file.remove("/probe_wiring.txt") end
        \\return h ~= nil
    ;
    const load_status = L.luaL_loadstring(shell_state, script);
    expect(load_status == L.LUA_OK, "wiring check script compiles");
    if (load_status != L.LUA_OK) return;
    const run_status = L.lua_pcallk(shell_state, 0, 1, 0, 0, null);
    expect(run_status == L.LUA_OK, "wiring check script runs");
    if (run_status != L.LUA_OK) {
        L.lua_pop(shell_state, 1);
        return;
    }
    const marker = L.lua_toboolean(shell_state, -1) == 1;
    expect(marker, "spawned program's update ran and its side effect is visible");
    _ = L.lua_pop(shell_state, 1);

    // A program file that does not exist must fail cleanly at the isolated
    // path (NotFound from the initrd lookup) — never reload the shared shell
    // state through lua.runMain.
    const missing = runtime.spawn(.{ .kind = .Lua, .entry = "no_such_program.lua" });
    expect(missing == error.NotFound, "missing program file fails cleanly, shell untouched");
}

fn testWasmSpawnTickSurface() void {
    // Phase B (spec/adr/026): spawn -> tick -> surface end-to-end through the
    // isolated wasm path. This is the strongest verification of Phase B — a
    // regression here (e.g. a caller name that does not match the initrd's
    // flat .wasm entry) fails the runtime test instead of only being caught
    // by manually opening the calculator.
    const runtime = @import("api/runtime.zig");
    const wasm = @import("wasm/wasm.zig");
    const sys = @import("api/sys.zig");
    const service = @import("input/service.zig");

    // A caller name without the initrd's flat .wasm extension must fail
    // cleanly (NotFound), not silently spawn nothing.
    const missing = runtime.spawn(.{ .kind = .Wasm, .entry = "calculator" });
    expect(missing == error.NotFound, "entry name without .wasm fails cleanly, no silent mismatch");

    const prog = runtime.spawn(.{ .kind = .Wasm, .entry = "calculator.wasm" }) catch {
        expect(false, "runtime.spawn launches a wasm program by its initrd entry name");
        return;
    };
    const program = wasm.byHandle(prog.handle) orelse {
        expect(false, "spawned wasm program is live in its slot");
        return;
    };
    expect(program.surface[0] == 0, "surface is zero-filled before the first render");

    // Spawn is a singleton per program name (spec/adr/026): a repeated spawn
    // reuses the handle instead of starting a second instance.
    const prog2 = runtime.spawn(.{ .kind = .Wasm, .entry = "calculator.wasm" }) catch {
        expect(false, "second spawn of the same name succeeds");
        return;
    };
    expect(prog2.handle == prog.handle, "spawn is a singleton per program name");

    wasm.tickPrograms();
    const background: u32 = 0x00101827;
    expect(program.surface[0] == background, "tickPrograms ran update()+render(), surface shows the drawn background");

    // input_mouse_x/y are relative to the last surface_render placement, so
    // the program lives in its own coordinate space (spec/adr/026).
    const placed = runtime.surfaceRender(prog.handle, 50, 60);
    expect(placed == @as(u64, @intFromEnum(sys.KiStatus.Success)), "surface_render accepts a live handle");
    service.setMouseState(.{ .x = 50 + 24, .y = 60 + 52, .left = true });
    wasm.tickPrograms();
    service.setMouseState(.{ .x = 0, .y = 0, .left = false });
    wasm.tickPrograms();
    expect(program.surface[0] == background, "program keeps rendering after handling a click (no crash, no trap)");

    const unknown = runtime.surfaceRender(prog.handle + 999, 0, 0);
    expect(unknown == @as(u64, @intFromEnum(sys.KiStatus.NotFound)), "surface_render reports NotFound for an unknown handle");

    // Trap containment (Phase A, re-verified against the Phase B Program
    // struct): a program that traps in start() is dropped at spawn and its
    // slot is freed, without corrupting the table for other live programs.
    const faulted = runtime.spawn(.{ .kind = .Wasm, .entry = "fault.wasm" });
    expect(faulted == error.CallFailed, "a program that traps in start() is dropped, not left half-alive");
    const still_alive = wasm.byHandle(prog.handle) != null;
    expect(still_alive, "an unrelated live program is unaffected by another program's trap");
}

fn testGcStepPreservesStack() void {
    // 0a74b69: gcStep called lua_pop after a successful pcall with nresults=0,
    // which already restores the pre-push stack — the extra pop removed a live
    // value and corrupted the shell's stack. A value pushed before gcStep must
    // survive it.
    const lua = @import("lua/lua.zig");
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    _ = L.lua_pushinteger(lua_state, 0x5157);
    lua.gcStep(1024);
    expect(L.lua_tointegerx(lua_state, -1, null) == 0x5157, "gcStep keeps a live stack value");
    _ = L.lua_pop(lua_state, 1);
}

fn testApCoresUp() void {
    // SMP bring-up (M7): with QEMU -smp N (N > 1) every enabled AP must have
    // reported ready after INIT-SIPI-SIPI. Single-core (-smp 1) passes as a
    // no-op; the assertion becomes active once the bring-up is fixed (see
    // spec/handoffs/05 - the AP currently #PF(RSVD) on its first page walk).
    const smp = @import("cpu/smp.zig");
    if (smp.ap_count == 0) return;
    expect(smp.ap_ready.load(.seq_cst) == smp.ap_count, "SMP: every AP reported ready after SIPI");
}

const tests = [_]Test{
    .{ .name = "timer tick + event queue", .func = testTimerTicks },
    .{ .name = "RTC-seeded wall clock (bar time of day)", .func = testRtcWallClock },
    .{ .name = "mouse event queue", .func = testMouseEvent },
    .{ .name = "mouse wheel accumulator + KI binding", .func = testMouseWheel },
    .{ .name = "mouse wheel hardware detection (PS/2 ID 3)", .func = testMouseWheelHardware },
    .{ .name = "mouse wheel packet -> queue -> Lua binding", .func = testMouseWheelPacketPath },
    .{ .name = "mouse flood does not starve keys", .func = testMouseFloodDoesNotStarveKeys },
    .{ .name = "mouse cursor overlay", .func = testMouseCursor },
    .{ .name = "framebuffer write + drawText", .func = testFramebufferWrites },
    .{ .name = "lua bindings + render", .func = testLuaBindings },
    .{ .name = "lua dbg lib (M6.1.9)", .func = testDbgLib },
    .{ .name = "layout switch via Lua binding (ADR-024)", .func = testLayoutSwitchFromLua },
    .{ .name = "layout mapping behaviour via service", .func = testLayoutMappingBehaviour },
    .{ .name = "live theme change (render stays healthy)", .func = testLiveThemeChange },
    .{ .name = "reload from Lua is deferred, state survives", .func = testLuaTriggeredReload },
    .{ .name = "error containment (lua error)", .func = testErrorContainment },
    .{ .name = "adversarial binding inputs contained", .func = testLuaBindingAdversarial },
    .{ .name = "infinite loop containment (instruction budget)", .func = testInfiniteLoopContainment },
    .{ .name = "render throughput", .func = testRenderThroughput },
    .{ .name = "preemptive RR scheduler (two kernel tasks)", .func = testPreemptiveScheduler },
    .{ .name = "blocking sleep deschedules a task (M7)", .func = testBlockingTaskSleep },
    .{ .name = "semaphore blocks and wakes a task (ADR-017)", .func = testSemaphore },
    .{ .name = "mutex ownership handoff (ADR-017)", .func = testMutex },
    .{ .name = "event group any-mode wake (ADR-017)", .func = testEventGroup },
    .{ .name = "message queue put wakes a blocked get (ADR-017)", .func = testMessageQueue },
    .{ .name = "task error handler runs on an errored task", .func = testTaskErrorHandler },
    .{ .name = "per-program isolation (own lua_State, contained)", .func = testPerProgramIsolation },
    .{ .name = "runtime.spawn wires programs to the isolated path", .func = testSpawnWiring },
    .{ .name = "wasm spawn/tick/surface end-to-end (Phase B, spec/adr/026)", .func = testWasmSpawnTickSurface },
    .{ .name = "SMP AP bring-up (INIT-SIPI-SIPI)", .func = testApCoresUp },
    .{ .name = "gcStep keeps a live stack value (0a74b69)", .func = testGcStepPreservesStack },
};

fn testFilesystem(alloc: std.mem.Allocator, memory: *mem.Memory) void {
    // Exercise the thin file API against the disk mounted at boot: mount,
    // lookup, open, read, EOF, invalid path, and the write path
    // (spec/roadmap.md M6.1.5, M7.1.x). Skipped when no disk is attached.
    // The boot-time storage stack is reused — a second VirtioBlk init would
    // reprogram the shared device's queue and break the mounted one.
    _ = alloc;
    _ = memory;
    const storage = @import("api/storage.zig");
    const file = @import("fs/file.zig");

    if (!storage.isMounted()) {
        expect(true, "filesystem test skipped (no disk attached)");
        return;
    }
    const part = storage.mounted.?.disk;
    var fs = storage.mounted.?;
    expect(true, "ext2 mounted at boot");

    const ino = fs.find("/wm/theme.lua") catch {
        expect(false, "lookup finds /wm/theme.lua");
        return;
    };
    expect(ino > 0, "lookup finds /wm/theme.lua");

    var f = file.File.open(&fs, "/wm/theme.lua") catch {
        expect(false, "open /wm/theme.lua");
        return;
    };
    defer f.close();
    var buf: [4096]u8 = undefined;
    const n = f.read(&buf) catch {
        expect(false, "read /wm/theme.lua");
        return;
    };
    expect(n > 0, "read /wm/theme.lua returns data");
    expect(std.mem.indexOf(u8, buf[0..n], "theme = {") != null, "read returns the theme config table");
    expect(f.eof(), "read reaches EOF");

    if (file.File.open(&fs, "/missing.lua")) |_| {
        expect(false, "open invalid path fails");
    } else |_| {
        expect(true, "open invalid path fails");
    }

    // M7.1.3: rewrite theme.lua in place, grow it past the first block, and
    // shrink it again — the write path (data blocks, allocation, inode size)
    // against the real disk. The CI disk is a throwaway image. writeAt never
    // shrinks, so a replacement is truncate + write.
    var fs2 = fs;
    fs2.truncate(ino, 0) catch {
        expect(false, "ext2 truncate before rewrite");
        return;
    };
    fs2.writeAt(ino, 0, "bg=0x123456") catch {
        expect(false, "ext2 writeAt rewrites a file");
        return;
    };
    expect(true, "ext2 writeAt rewrites a file");
    var rbuf2: [128]u8 = undefined;
    const rn2 = fs2.readAt(ino, 0, &rbuf2) catch {
        expect(false, "ext2 readAt sees the rewrite");
        return;
    };
    expect(std.mem.eql(u8, "bg=0x123456", rbuf2[0..rn2]), "ext2 readAt sees the rewrite");

    var big: [2000]u8 = undefined;
    for (&big) |*b| b.* = 0x42;
    fs2.writeAt(ino, 0, &big) catch {
        expect(false, "ext2 writeAt grows a file");
        return;
    };
    expect(true, "ext2 writeAt grows a file");
    var rbig: [2000]u8 = undefined;
    const rn3 = fs2.readAt(ino, 0, &rbig) catch {
        expect(false, "ext2 readAt reads the grown file");
        return;
    };
    expect(std.mem.eql(u8, &big, rbig[0..rn3]), "ext2 readAt reads the grown file");

    fs2.truncate(ino, 3) catch {
        expect(false, "ext2 truncate shrinks a file");
        return;
    };
    expect(true, "ext2 truncate shrinks a file");
    var rshort: [64]u8 = undefined;
    const rn4 = fs2.readAt(ino, 0, &rshort) catch {
        expect(false, "ext2 readAt sees the truncated file");
        return;
    };
    expect(std.mem.eql(u8, big[0..3], rshort[0..rn4]), "ext2 readAt sees the truncated file");

    // M7.1.1: sector write + readback through the block-device interface.
    // The last partition sector lies past the small ext2 image (the test disk
    // is mostly free space), so the write only touches unused capacity.
    const last = part.last_lba - part.first_lba;
    var wbuf: [512]u8 = undefined;
    @memset(&wbuf, 0xA5);
    part.writeSector(last, &wbuf) catch {
        expect(false, "block write succeeds");
        return;
    };
    expect(true, "block write succeeds");
    var rbuf: [512]u8 = undefined;
    part.readSector(last, &rbuf) catch {
        expect(false, "block readback after write");
        return;
    };
    expect(std.mem.eql(u8, &wbuf, &rbuf), "block readback matches written data");
}

fn testStorageKi() void {
    // The KI storage module (M7.1.4): open/read/truncate/write/close through
    // sys.dispatch against the disk mounted at boot. Skipped when no disk.
    const storage = @import("api/storage.zig");
    if (!storage.isMounted()) {
        expect(true, "storage KI test skipped (no disk attached)");
        return;
    }
    const path = "/wm/theme.lua";
    const open_result = storage.dispatch(.{
        .a = @intFromEnum(storage.StorageOp.open),
        .b = @intFromPtr(path.ptr),
        .c = path.len,
    });
    expect(open_result >> 32 == 0, "storage open succeeds");
    const handle = open_result & 0xFFFFFFFF;

    var buf: [128]u8 = undefined;
    const read_args = storage.ReadArgs{ .handle = handle, .buf = @intFromPtr(&buf), .len = buf.len };
    const read_result = storage.dispatch(.{
        .a = @intFromEnum(storage.StorageOp.read),
        .b = @intFromPtr(&read_args),
    });
    expect(read_result >> 32 == 0, "storage read succeeds");

    const truncate_result = storage.dispatch(.{
        .a = @intFromEnum(storage.StorageOp.truncate),
        .b = handle,
        .c = 0,
    });
    expect(truncate_result >> 32 == 0, "storage truncate succeeds");

    const payload = "ki=ok\n";
    const write_args = storage.WriteArgs{
        .handle = handle,
        .data = @intFromPtr(payload.ptr),
        .len = payload.len,
    };
    const write_result = storage.dispatch(.{
        .a = @intFromEnum(storage.StorageOp.write),
        .b = @intFromPtr(&write_args),
    });
    expect(write_result >> 32 == 0, "storage write succeeds");

    _ = storage.dispatch(.{ .a = @intFromEnum(storage.StorageOp.close), .b = handle });

    const reopen = storage.dispatch(.{
        .a = @intFromEnum(storage.StorageOp.open),
        .b = @intFromPtr(path.ptr),
        .c = path.len,
    });
    expect(reopen >> 32 == 0, "storage reopen succeeds");
    const h2 = reopen & 0xFFFFFFFF;
    var buf2: [128]u8 = undefined;
    const read2 = storage.ReadArgs{ .handle = h2, .buf = @intFromPtr(&buf2), .len = buf2.len };
    const result2 = storage.dispatch(.{
        .a = @intFromEnum(storage.StorageOp.read),
        .b = @intFromPtr(&read2),
    });
    const n2: usize = @intCast(result2 & 0xFFFFFFFF);
    expect(std.mem.eql(u8, payload, buf2[0..n2]), "storage write persisted through reopen");
    _ = storage.dispatch(.{ .a = @intFromEnum(storage.StorageOp.close), .b = h2 });
}

fn testFileBindings() void {
    // The Lua file.* bindings (M7.1.4): rewrite a file and read it back,
    // exercising open/read/truncate/write/close end to end. Skipped when no
    // disk is attached.
    const lua = @import("lua/lua.zig");
    const storage = @import("api/storage.zig");
    if (!storage.isMounted()) {
        expect(true, "file binding test skipped (no disk attached)");
        return;
    }
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    _ = L.lua_getglobal(lua_state, "file");
    expect(L.lua_istable(lua_state, -1), "file binding table is registered");
    _ = L.lua_pop(lua_state, 1);

    const script =
        \\local h = file.open("/wm/theme.lua")
        \\if not h then return "open-failed" end
        \\file.truncate(h, 0)
        \\file.write(h, "lua=ok")
        \\file.close(h)
        \\h = file.open("/wm/theme.lua")
        \\if not h then return "reopen-failed" end
        \\local content = file.read(h, 128)
        \\file.close(h)
        \\return content
    ;
    const load_status = L.luaL_loadstring(lua_state, script);
    expect(load_status == L.LUA_OK, "file binding script compiles");
    if (load_status != L.LUA_OK) return;
    const run_status = L.lua_pcallk(lua_state, 0, 1, 0, 0, null);
    expect(run_status == L.LUA_OK, "file binding script runs");
    if (run_status != L.LUA_OK) {
        L.lua_pop(lua_state, 1);
        return;
    }
    var len: usize = 0;
    const str = L.lua_tolstring(lua_state, -1, &len);
    const content: []const u8 = @as([*]const u8, @ptrCast(str))[0..len];
    expect(len == 6 and std.mem.eql(u8, "lua=ok", content), "file bindings round-trip file content");
    _ = L.lua_pop(lua_state, 1);
}

fn testDofile() void {
    // Stock Lua `dofile` must work like standard Lua: it reads the file through
    // C stdio (fopen), which maps onto the kernel storage. A file on the disk
    // is created, then loaded and run by plain `dofile` — no file.* calls in
    // the consuming script.
    const lua = @import("lua/lua.zig");
    const storage = @import("api/storage.zig");
    if (!storage.isMounted()) {
        expect(true, "dofile test skipped (no disk attached)");
        return;
    }
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    const script =
        \\-- Clean slate: the test disk may persist between runs.
        \\local old = file.open("/wm/dofile_target.lua")
        \\if old then
        \\    file.close(old)
        \\    file.remove("/wm/dofile_target.lua")
        \\end
        \\local h = file.create("/wm/dofile_target.lua")
        \\if not h then return "create-failed" end
        \\file.write(h, "dofile_ran = 'yes'\n")
        \\file.close(h)
        \\dofile("/wm/dofile_target.lua")
        \\return dofile_ran
    ;
    const load_status = L.luaL_loadstring(lua_state, script);
    expect(load_status == L.LUA_OK, "dofile script compiles");
    if (load_status != L.LUA_OK) return;
    const run_status = L.lua_pcallk(lua_state, 0, 1, 0, 0, null);
    expect(run_status == L.LUA_OK, "dofile script runs");
    if (run_status != L.LUA_OK) {
        L.lua_pop(lua_state, 1);
        return;
    }
    var len: usize = 0;
    const str = L.lua_tolstring(lua_state, -1, &len);
    const content: []const u8 = @as([*]const u8, @ptrCast(str))[0..len];
    expect(len == 3 and std.mem.eql(u8, "yes", content), "dofile loaded and ran the file");
    _ = L.lua_pop(lua_state, 1);
}

fn testFileRemove() void {
    // M7.1.9: file.remove deletes a file (dir entry + data gone) and the
    // config backup /wm/.theme.bak is protected while /wm/theme.lua is broken.
    const lua = @import("lua/lua.zig");
    const storage = @import("api/storage.zig");
    if (!storage.isMounted()) {
        expect(true, "file remove test skipped (no disk attached)");
        return;
    }
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    const script =
        \\local w = file.open("/README")
        \\if not w then return "open-failed" end
        \\file.truncate(w, 0)
        \\local big = string.rep("x", 2000)
        \\file.write(w, big)
        \\file.close(w)
        \\local ok, err = pcall(file.remove, "/README")
        \\if not ok then return "remove-err:" .. tostring(err) end
        \\local entries = file.dir("/")
        \\local gone = true
        \\for _, e in ipairs(entries) do
        \\    if e.name == "README" then gone = false end
        \\end
        \\-- .theme.bak must not be deleted here: ext2 has no create, so a
        \\-- removed backup could not be recreated and later tests need it.
        \\if gone then return "PASS" else return "FAIL" end
    ;
    const load_status = L.luaL_loadstring(lua_state, script);
    expect(load_status == L.LUA_OK, "file remove script compiles");
    if (load_status != L.LUA_OK) return;
    const run_status = L.lua_pcallk(lua_state, 0, 1, 0, 0, null);
    expect(run_status == L.LUA_OK, "file remove script runs");
    if (run_status != L.LUA_OK) {
        L.lua_pop(lua_state, 1);
        return;
    }
    var len: usize = 0;
    const str = L.lua_tolstring(lua_state, -1, &len);
    const result: []const u8 = @as([*]const u8, @ptrCast(str))[0..len];
    const ok = len == 4 and std.mem.eql(u8, result, "PASS");
    expect(ok, "file.remove frees a multi-block file");
    _ = L.lua_pop(lua_state, 1);
}

fn testFileCreate() void {
    // file.create makes a brand-new file (ext2 create, the editor save-as
    // path): create, write, read back; creating the same path again fails.
    const lua = @import("lua/lua.zig");
    const storage = @import("api/storage.zig");
    if (!storage.isMounted()) {
        expect(true, "file.create test skipped (no disk attached)");
        return;
    }
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    const script =
        \\-- Start from a clean slate (no create_test.txt from a previous run).
        \\local h = file.open("/create_test.txt")
        \\if h then
        \\    file.close(h)
        \\    file.remove("/create_test.txt")
        \\end
        \\h = file.create("/create_test.txt")
        \\if not h then return "create-failed" end
        \\file.write(h, "fresh file")
        \\file.close(h)
        \\h = file.open("/create_test.txt")
        \\local content = file.read(h, 4096)
        \\file.close(h)
        \\-- Creating the same path again must fail (FileExists).
        \\local dup = file.create("/create_test.txt")
        \\local dup_ok = (dup == nil)
        \\if dup then file.close(dup) end
        \\-- Cleanup so later tests (file.dir listing) are unaffected.
        \\file.remove("/create_test.txt")
        \\if content == "fresh file" and dup_ok then return "PASS" else return "FAIL" end
    ;
    const load_status = L.luaL_loadstring(lua_state, script);
    expect(load_status == L.LUA_OK, "file.create script compiles");
    if (load_status != L.LUA_OK) return;
    const run_status = L.lua_pcallk(lua_state, 0, 1, 0, 0, null);
    expect(run_status == L.LUA_OK, "file.create script runs");
    if (run_status != L.LUA_OK) {
        L.lua_pop(lua_state, 1);
        return;
    }
    var len: usize = 0;
    const str = L.lua_tolstring(lua_state, -1, &len);
    const result: []const u8 = @as([*]const u8, @ptrCast(str))[0..len];
    const ok = len == 4 and std.mem.eql(u8, result, "PASS");
    expect(ok, "file.create makes a new file and rejects a duplicate path");
    _ = L.lua_pop(lua_state, 1);
}

fn testDirMultiBlock() void {
    // A directory grows past one block when it fills up (M7.1 debt: addDirEntry
    // used to return OutOfSpace at the single-block boundary). Create enough
    // files to overflow the root directory's first block, then verify every
    // entry resolves (lookup walks multi-block dirs) and entries in later
    // blocks can be removed. The dir listing caps at 32, so verification goes
    // through open/remove, not file.dir. Skipped when no disk is attached.
    const lua = @import("lua/lua.zig");
    const storage = @import("api/storage.zig");
    if (!storage.isMounted()) {
        expect(true, "multi-block dir test skipped (no disk attached)");
        return;
    }
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    const script =
        \\local N = 80 -- 1 KiB dir block holds ~51 entries; 80 spans two blocks
        \\local ok = true
        \\for i = 1, N do
        \\    local h = file.create("/dmb_" .. i .. ".txt")
        \\    if not h then ok = false break end
        \\    file.write(h, "x")
        \\    file.close(h)
        \\end
        \\for i = 1, N do
        \\    local h = file.open("/dmb_" .. i .. ".txt")
        \\    if not h then ok = false end
        \\    if h then file.close(h) end
        \\end
        \\-- Remove every even entry from 40 up (likely in the second block) and
        \\-- verify the odd ones still resolve while the removed ones are gone.
        \\for i = 40, N, 2 do file.remove("/dmb_" .. i .. ".txt") end
        \\for i = 1, N do
        \\    local h = file.open("/dmb_" .. i .. ".txt")
        \\    if (i % 2 == 0 and i >= 40) then
        \\        if h then ok = false end
        \\    else
        \\        if not h then ok = false end
        \\    end
        \\    if h then file.close(h) end
        \\end
        \\for i = 1, N do file.remove("/dmb_" .. i .. ".txt") end
        \\if ok then return "PASS" else return "FAIL" end
    ;
    const load_status = L.luaL_loadstring(lua_state, script);
    expect(load_status == L.LUA_OK, "multi-block dir script compiles");
    if (load_status != L.LUA_OK) return;
    const run_status = L.lua_pcallk(lua_state, 0, 1, 0, 0, null);
    expect(run_status == L.LUA_OK, "multi-block dir script runs");
    if (run_status != L.LUA_OK) {
        var err_len: usize = 0;
        const err_str = L.lua_tolstring(lua_state, -1, &err_len);
        const err_slice: []const u8 = @as([*]const u8, @ptrCast(err_str))[0..err_len];
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "multi-block dir script error: {s}", .{err_slice}) catch "multi-block dir script error";
        serial.writeLine(line);
        L.lua_pop(lua_state, 1);
        return;
    }
    var len: usize = 0;
    const str = L.lua_tolstring(lua_state, -1, &len);
    const result: []const u8 = @as([*]const u8, @ptrCast(str))[0..len];
    const ok = len == 4 and std.mem.eql(u8, result, "PASS");
    expect(ok, "create/lookup/remove round-trips across a multi-block directory");
    _ = L.lua_pop(lua_state, 1);
}

fn testFileMultiBlock() void {
    // Write a multi-block file (275456 B = 68 blocks of 4096 B) and read it
    // back, verifying a mid-file byte. NOTE: with 4096 B blocks the
    // single-indirect span is 12 direct + 1024 indirect = 1036 blocks
    // (~4.25 MiB), so this file stays within single-indirect — the
    // double-indirect boundary is NOT exercised (handoff H6 §9). Skipped when
    // no disk is attached.
    const lua = @import("lua/lua.zig");
    const storage = @import("api/storage.zig");
    if (!storage.isMounted()) {
        expect(true, "double-indirect test skipped (no disk attached)");
        return;
    }
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    const script =
        \\-- The test disk uses 4 KiB blocks: 12 direct + 1024 single-indirect
        \\-- pointers span blocks 0-1035; the double-indirect boundary (block
        \\-- 1036, ~4.25 MiB) is NOT reached by this 68-block file — the test
        \\-- exercises multi-block write/read inside the single-indirect span
        \\-- (handoff H6 §9). Write in chunks so no single heap allocation is
        \\-- huge, read it all back and verify a mid-file byte.
        \\local h = file.open("/big_test.txt")
        \\if h then file.close(h); file.remove("/big_test.txt") end
        \\h = file.create("/big_test.txt")
        \\if not h then return "FAIL" end
        \\local n = 269 * 1024
        \\local chunk = 32768
        \\local written = 0
        \\while written < n do
        \\    local c = math.min(chunk, n - written)
        \\    file.write(h, string.rep("B", c))
        \\    written = written + c
        \\end
        \\file.close(h)
        \\h = file.open("/big_test.txt")
        \\local parts = {}
        \\local total = 0
        \\while true do
        \\    local piece = file.read(h, 4096)
        \\    if not piece or piece == "" then break end
        \\    parts[#parts + 1] = piece
        \\    total = total + #piece
        \\end
        \\file.close(h)
        \\local ok = (total == n)
        \\local boundary = 268 * 1024 + 1
        \\local sofar = 0
        \\for _, p in ipairs(parts) do
        \\    if sofar + #p >= boundary then
        \\        if p:byte(boundary - sofar) ~= 66 then ok = false end
        \\        break
        \\    end
        \\    sofar = sofar + #p
        \\end
        \\file.remove("/big_test.txt")
        \\if ok then return "PASS" else return "FAIL" end
    ;
    const load_status = L.luaL_loadstring(lua_state, script);
    expect(load_status == L.LUA_OK, "double-indirect script compiles");
    if (load_status != L.LUA_OK) return;
    const run_status = L.lua_pcallk(lua_state, 0, 1, 0, 0, null);
    expect(run_status == L.LUA_OK, "double-indirect script runs");
    if (run_status != L.LUA_OK) {
        var err_len: usize = 0;
        const err_str = L.lua_tolstring(lua_state, -1, &err_len);
        const err_slice: []const u8 = @as([*]const u8, @ptrCast(err_str))[0..err_len];
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "double-indirect script error: {s}", .{err_slice}) catch "double-indirect script error";
        serial.writeLine(line);
        L.lua_pop(lua_state, 1);
        return;
    }
    var len: usize = 0;
    const str = L.lua_tolstring(lua_state, -1, &len);
    const result: []const u8 = @as([*]const u8, @ptrCast(str))[0..len];
    const ok = len == 4 and std.mem.eql(u8, result, "PASS");
    expect(ok, "write/read round-trips a file across multiple 4 KiB blocks");
    _ = L.lua_pop(lua_state, 1);
}

fn testFileRename() void {
    // file.rename relinks an existing file under a new name (no data copy):
    // the old path resolves to nothing, the new path holds the same content,
    // and renaming onto an existing path fails. Skipped when no disk.
    const lua = @import("lua/lua.zig");
    const storage = @import("api/storage.zig");
    if (!storage.isMounted()) {
        expect(true, "file.rename test skipped (no disk attached)");
        return;
    }
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    const script =
        \\-- Start from a clean slate.
        \\local h = file.open("/rename_src.txt")
        \\if h then file.close(h) file.remove("/rename_src.txt") end
        \\local g = file.open("/rename_dst.txt")
        \\if g then file.close(g) file.remove("/rename_dst.txt") end
        \\h = file.create("/rename_src.txt")
        \\if not h then return "create-failed" end
        \\file.write(h, "renamed content")
        \\file.close(h)
        \\file.rename("/rename_src.txt", "/rename_dst.txt")
        \\local old = file.open("/rename_src.txt")
        \\if old then file.close(old) return "old-still-there" end
        \\h = file.open("/rename_dst.txt")
        \\local content = file.read(h, 4096)
        \\file.close(h)
        \\-- Renaming onto an existing path must fail (FileExists).
        \\h = file.create("/rename_src.txt")
        \\if not h then return "recreate-failed" end
        \\file.close(h)
        \\local dup = file.rename("/rename_src.txt", "/rename_dst.txt")
        \\-- Cleanup so later tests (file.dir listing) are unaffected.
        \\file.remove("/rename_dst.txt")
        \\file.remove("/rename_src.txt")
        \\if content == "renamed content" and not dup then return "PASS" else return "FAIL" end
    ;
    const load_status = L.luaL_loadstring(lua_state, script);
    expect(load_status == L.LUA_OK, "file.rename script compiles");
    if (load_status != L.LUA_OK) return;
    const run_status = L.lua_pcallk(lua_state, 0, 1, 0, 0, null);
    expect(run_status == L.LUA_OK, "file.rename script runs");
    if (run_status != L.LUA_OK) {
        L.lua_pop(lua_state, 1);
        return;
    }
    var len: usize = 0;
    const str = L.lua_tolstring(lua_state, -1, &len);
    const result: []const u8 = @as([*]const u8, @ptrCast(str))[0..len];
    const ok = len == 4 and std.mem.eql(u8, result, "PASS");
    expect(ok, "file.rename moves a file and rejects an existing target");
    _ = L.lua_pop(lua_state, 1);
}

fn testEditorApp() void {
    // M7.1.5: the editor loads a file through file.*, saves it back and the
    // round trip matches the buffer. Skipped when no disk is attached.
    const lua = @import("lua/lua.zig");
    const storage = @import("api/storage.zig");
    if (!storage.isMounted()) {
        expect(true, "editor app test skipped (no disk attached)");
        return;
    }
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    const script =
        \\editor_load("/wm/theme.lua")
        \\local before = table.concat(ed_lines, "\n")
        \\editor_save()
        \\-- Saving /wm/theme.lua backs up the previous working copy to
        \\-- /wm/.theme.bak; the test must not leave it behind — a .bak appears
        \\-- on the disk only after a manual Ctrl+S, never from the test suite.
        \\file.remove("/wm/.theme.bak")
        \\local h = file.open("/wm/theme.lua")
        \\local after = file.read(h, 4096) or ""
        \\file.close(h)
        \\return (before == after) and #before
    ;
    const load_status = L.luaL_loadstring(lua_state, script);
    expect(load_status == L.LUA_OK, "editor script compiles");
    if (load_status != L.LUA_OK) return;
    const run_status = L.lua_pcallk(lua_state, 0, 1, 0, 0, null);
    expect(run_status == L.LUA_OK, "editor script runs");
    if (run_status != L.LUA_OK) {
        L.lua_pop(lua_state, 1);
        return;
    }
    const ok = L.lua_toboolean(lua_state, -1) == 1;
    expect(ok, "editor loads, saves and round-trips a file");
    _ = L.lua_pop(lua_state, 1);
}

fn testFileDir() void {
    // M7.1.5: file.dir lists a directory as { name, dir } entries.
    const lua = @import("lua/lua.zig");
    const storage = @import("api/storage.zig");
    if (!storage.isMounted()) {
        expect(true, "file.dir test skipped (no disk attached)");
        return;
    }
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    const script =
        \\local entries = file.dir("/")
        \\if not entries then return nil end
        \\local wm_dir = false
        \\local has_apps = false
        \\for _, e in ipairs(entries) do
        \\    if e.name == "wm" and e.dir then wm_dir = true end
        \\    if e.name == "apps" and e.dir then has_apps = true end
        \\end
        \\local wm_entries = file.dir("/wm")
        \\if not wm_entries then return nil end
        \\local theme_in_wm = false
        \\for _, e in ipairs(wm_entries) do
        \\    if e.name == "theme.lua" and not e.dir then theme_in_wm = true end
        \\end
        \\return wm_dir and has_apps and theme_in_wm
    ;
    const load_status = L.luaL_loadstring(lua_state, script);
    expect(load_status == L.LUA_OK, "file.dir script compiles");
    if (load_status != L.LUA_OK) return;
    const run_status = L.lua_pcallk(lua_state, 0, 1, 0, 0, null);
    expect(run_status == L.LUA_OK, "file.dir script runs");
    if (run_status != L.LUA_OK) {
        L.lua_pop(lua_state, 1);
        return;
    }
    const ok = L.lua_toboolean(lua_state, -1) == 1;
    expect(ok, "file.dir lists files and directories");
    _ = L.lua_pop(lua_state, 1);

    // M7.1.9: files_open no longer prepends ".." — navigation up goes through
    // Escape or a click on the path header; join_path builds child paths.
    const script2 =
        \\local no_dotdot = true
        \\for _, e in ipairs(fs_entries) do
        \\    if e.name == ".." then no_dotdot = false end
        \\end
        \\files_open("/apps")
        \\for _, e in ipairs(fs_entries) do
        \\    if e.name == ".." then no_dotdot = false end
        \\end
        \\local path_ok = join_path("/", "apps") == "/apps" and join_path("/apps", "x") == "/apps/x"
        \\-- editing a file must not reset the current files directory
        \\files_edit("hello.lua")
        \\local stayed = fs_path == "/apps"
        \\files_open("/")
        \\return no_dotdot and path_ok and stayed
    ;
    const load2 = L.luaL_loadstring(lua_state, script2);
    expect(load2 == L.LUA_OK, "files convention script compiles");
    if (load2 == L.LUA_OK) {
        const run2 = L.lua_pcallk(lua_state, 0, 1, 0, 0, null);
        if (run2 == L.LUA_OK) {
            const ok2 = L.lua_toboolean(lua_state, -1) == 1;
            expect(ok2, "files: no '..' entry, join_path builds child paths");
        }
        L.lua_pop(lua_state, 1);
    }
}

fn testAutoReload() void {
    // M7.1.6: a valid /wm/theme.lua applies live; a broken one must not crash —
    // apply_disk_theme reports the error, the live look stays on the built-in
    // default (the disk backup is a manual Ctrl+S backup, never loaded).
    const lua = @import("lua/lua.zig");
    const storage = @import("api/storage.zig");
    if (!storage.isMounted()) {
        expect(true, "auto-reload test skipped (no disk attached)");
        return;
    }
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    const script =
        \\-- seed the working copy with a good config
        \\local s = file.open("/wm/theme.lua")
        \\file.truncate(s, 0)
        \\file.write(s, "theme.background = 0x112233")
        \\file.close(s)
        \\local ok = apply_disk_theme() == nil and theme.background == 0x112233
        \\-- broken working copy: the error is returned and the disk backup is
        \\-- never loaded — the live look stays on the last applied value
        \\local w = file.open("/wm/theme.lua")
        \\file.truncate(w, 0)
        \\file.write(w, "theme.background = 0xZZZZZZ")
        \\file.close(w)
        \\local err = apply_disk_theme()
        \\ok = ok and err ~= nil and theme.background == 0x112233
        \\-- restore the working copy for later tests
        \\local w2 = file.open("/wm/theme.lua")
        \\file.truncate(w2, 0)
        \\file.write(w2, "theme.background = 0x112233")
        \\file.close(w2)
        \\if ok then return "PASS" else return "FAIL" end
    ;
    const load_status = L.luaL_loadstring(lua_state, script);
    expect(load_status == L.LUA_OK, "auto-reload script compiles");
    if (load_status != L.LUA_OK) return;
    const run_status = L.lua_pcallk(lua_state, 0, 1, 0, 0, null);
    expect(run_status == L.LUA_OK, "auto-reload script runs");
    if (run_status != L.LUA_OK) {
        L.lua_pop(lua_state, 1);
        return;
    }
    var len: usize = 0;
    const str = L.lua_tolstring(lua_state, -1, &len);
    const result: []const u8 = @as([*]const u8, @ptrCast(str))[0..len];
    const ok = len == 4 and std.mem.eql(u8, result, "PASS");
    expect(ok, "config applies live, broken config reports error and keeps last applied value");
    _ = L.lua_pop(lua_state, 1);
}

fn testReplHistory() void {
    // M7.1.7: the REPL command history persists to /.repl_history, so Up/Down
    // recall commands across F5 reloads and reboots (mirrors .bash_history).
    const lua = @import("lua/lua.zig");
    const storage = @import("api/storage.zig");
    if (!storage.isMounted()) {
        expect(true, "repl history test skipped (no disk attached)");
        return;
    }
    const L = @import("lua/cimport.zig").c;
    const lua_state = lua.getState() orelse {
        expect(false, "lua state exists");
        return;
    };
    const script =
        \\-- seed three commands, persist them, reload from disk, check order
        \\history = { "a = 1", "b = 2", "c = 3" }
        \\repl_save_history()
        \\history = {}
        \\repl_load_history()
        \\local ok = #history == 3 and history[1] == "a = 1" and history[2] == "b = 2" and history[3] == "c = 3"
        \\-- cap: 150 entries collapse to the last history_max (100)
        \\local big = {}
        \\for i = 1, 150 do big[#big + 1] = "cmd " .. i end
        \\history = big
        \\repl_save_history()
        \\history = {}
        \\repl_load_history()
        \\ok = ok and #history == 100 and history[100] == "cmd 150" and history[1] == "cmd 51"
        \\-- restore the seed file for later tests
        \\history = {}
        \\repl_save_history()
        \\if ok then return "PASS" else return "FAIL" end
    ;
    const load_status = L.luaL_loadstring(lua_state, script);
    expect(load_status == L.LUA_OK, "repl history script compiles");
    if (load_status != L.LUA_OK) return;
    const run_status = L.lua_pcallk(lua_state, 0, 1, 0, 0, null);
    expect(run_status == L.LUA_OK, "repl history script runs");
    if (run_status != L.LUA_OK) {
        L.lua_pop(lua_state, 1);
        return;
    }
    var len: usize = 0;
    const str = L.lua_tolstring(lua_state, -1, &len);
    const result: []const u8 = @as([*]const u8, @ptrCast(str))[0..len];
    const ok = len == 4 and std.mem.eql(u8, result, "PASS");
    expect(ok, "repl history persists commands and caps at 100");
    _ = L.lua_pop(lua_state, 1);
}

pub fn runAll(alloc: std.mem.Allocator, memory: *mem.Memory) noreturn {
    if (!comptime enabled) @compileError("runtime tests are not enabled");
    concurrent_alloc = alloc;
    serial.writeLine("RUNTIME TESTS START");
    for (tests) |t| {
        runOne(t);
    }
    serial.writeLine("ext2 filesystem on disk (M6.1.5)");
    testFilesystem(alloc, memory);
    serial.writeLine("storage KI (M7.1.4)");
    testStorageKi();
    serial.writeLine("lua file bindings (M7.1.4)");
    testFileBindings();
    serial.writeLine("lua dofile loads a disk file (stock stdio)");
    testDofile();
    serial.writeLine("file.remove + config backup protection (M7.1.9)");
    testFileRemove();
    serial.writeLine("file.create new file (M7.1.11)");
    testFileCreate();
    serial.writeLine("file.rename relink inode (rename)");
    testFileRename();
    serial.writeLine("file write/read across multiple 4 KiB blocks");
    testFileMultiBlock();
    serial.writeLine("create/lookup/remove across a multi-block directory");
    testDirMultiBlock();
    serial.writeLine("editor app (M7.1.5)");
    testEditorApp();
    serial.writeLine("file.dir listing (M7.1.5)");
    testFileDir();
    serial.writeLine("auto-reload on save (M7.1.6)");
    testAutoReload();
    serial.writeLine("persistent REPL history (M7.1.7)");
    testReplHistory();
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
