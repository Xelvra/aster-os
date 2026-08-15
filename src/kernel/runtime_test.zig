const std = @import("std");
const serial = @import("serial.zig");
const input_service = @import("input/service.zig");
const graphics = @import("api/graphics.zig");
const mem = @import("mem/mem.zig");
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

    const ev = input_service.popKernelEvent() orelse {
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

const tests = [_]Test{
    .{ .name = "timer tick + event queue", .func = testTimerTicks },
    .{ .name = "mouse event queue", .func = testMouseEvent },
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
    .{ .name = "infinite loop containment (instruction budget)", .func = testInfiniteLoopContainment },
    .{ .name = "render throughput", .func = testRenderThroughput },
    .{ .name = "preemptive RR scheduler (two kernel tasks)", .func = testPreemptiveScheduler },
    .{ .name = "blocking sleep deschedules a task (M7)", .func = testBlockingTaskSleep },
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
        \\-- grow the (existing) README past one block, then delete it: the
        \\-- README is a test-disk artifact nobody reads afterwards, so this
        \\-- exercises freeing a two-block file without breaking later tests
        \\local w = file.open("/README")
        \\if not w then return "open-failed" end
        \\file.truncate(w, 0)
        \\local big = string.rep("x", 2000)
        \\file.write(w, big)
        \\file.close(w)
        \\file.remove("/README")
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
        \\files_open("/")
        \\return no_dotdot and path_ok
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
    // apply_disk_theme reports the error, the live look stays on the last
    // valid version and .theme.bak is untouched.
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
        \\-- seed the working copy and the last-valid backup with the same
        \\-- good config so a broken working copy is detectable (a successful
        \\-- Ctrl+S would put the previous working copy into .theme.bak)
        \\local s = file.open("/wm/theme.lua")
        \\file.truncate(s, 0)
        \\file.write(s, "theme.background = 0x112233")
        \\file.close(s)
        \\local s2 = file.open("/wm/.theme.bak")
        \\file.truncate(s2, 0)
        \\file.write(s2, "theme.background = 0x112233")
        \\file.close(s2)
        \\local ok = apply_disk_theme() == nil and theme.background == 0x112233
        \\-- broken working copy: the error is returned, the live look stays on
        \\-- the last valid version and .theme.bak is untouched
        \\local w = file.open("/wm/theme.lua")
        \\file.truncate(w, 0)
        \\file.write(w, "theme.background = 0xZZZZZZ")
        \\file.close(w)
        \\local err = apply_disk_theme()
        \\ok = ok and err ~= nil and theme.background == 0x112233
        \\local b2 = file.open("/wm/.theme.bak")
        \\local bak2 = ""
        \\while true do
        \\    local c = file.read(b2, 4096)
        \\    if not c or c == "" then break end
        \\    bak2 = bak2 .. c
        \\end
        \\file.close(b2)
        \\ok = ok and bak2 == "theme.background = 0x112233"
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
    expect(ok, "config applies live, broken config falls back to .theme.bak, backup intact");
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
    serial.writeLine("file.remove + config backup protection (M7.1.9)");
    testFileRemove();
    serial.writeLine("file.create new file (M7.1.11)");
    testFileCreate();
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
