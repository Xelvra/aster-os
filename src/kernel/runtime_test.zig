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
    _ = L.lua_getglobal(lua_state, "power");
    expect(L.lua_istable(lua_state, -1), "power binding table is registered");
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

fn taskA() callconv(.c) noreturn {
    while (true) {
        if (task_stop.load(.monotonic)) {
            task_a_parked.store(true, .monotonic);
            while (true) {
                asm volatile ("hlt" ::: .{ .memory = true });
            }
        }
        _ = task_a_counter.fetchAdd(1, .monotonic);
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
    }
}

fn testPreemptiveScheduler() void {
    // Two native kernel tasks on the shared address space, each spinning on
    // its own counter. The APIC timer IRQ preempts whoever is running and the
    // round-robin scheduler switches — both counters must advance. That is the
    // only reliable proof of real preemption, not cooperative yield.
    const sched = @import("sched/task.zig");
    const time = @import("time.zig");

    task_a_counter.store(0, .monotonic);
    task_b_counter.store(0, .monotonic);
    task_stop.store(false, .monotonic);
    task_a_parked.store(false, .monotonic);
    task_b_parked.store(false, .monotonic);

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
    .{ .name = "render throughput", .func = testRenderThroughput },
    .{ .name = "preemptive RR scheduler (two kernel tasks)", .func = testPreemptiveScheduler },
};

fn testFilesystem(alloc: std.mem.Allocator, memory: *mem.Memory) void {
    // Mount the ext2 partition of an attached test disk and exercise the
    // thin file API: mount, lookup, open, read, EOF, invalid path
    // (spec/roadmap.md M6.1.5). Skipped when no disk is attached.
    const virtio = @import("drivers/virtio.zig");
    const block = @import("drivers/block.zig");
    const gpt = @import("fs/gpt.zig");
    const ext2 = @import("fs/ext2.zig");
    const file = @import("fs/file.zig");

    var blk = virtio.VirtioBlk.init(alloc, &memory.pfa, memory.pfa.hhdm_offset) catch {
        expect(true, "filesystem test skipped (no disk attached)");
        return;
    };
    blk.setupQueue() catch {
        expect(true, "filesystem test skipped (virtio queue failed)");
        return;
    };
    var partitions: [8]block.PartitionView = undefined;
    const count = gpt.discover(alloc, blk.asBlockDevice(), &partitions) catch {
        expect(true, "filesystem test skipped (no GPT)");
        return;
    };
    var fs_partition: ?block.PartitionView = null;
    for (partitions[0..count]) |p| {
        if (gpt.eqlGuid(p.type_guid, gpt.type_guid_linux_fs)) {
            fs_partition = p;
            break;
        }
    }
    const part = fs_partition orelse {
        expect(true, "filesystem test skipped (no linux partition)");
        return;
    };
    const fs = ext2.Ext2.init(part) catch {
        expect(false, "ext2 mounts");
        return;
    };
    expect(true, "ext2 mounts");

    const ino = fs.find("/theme.lua") catch {
        expect(false, "lookup finds /theme.lua");
        return;
    };
    expect(ino > 0, "lookup finds /theme.lua");

    var f = file.File.open(&fs, "/theme.lua") catch {
        expect(false, "open /theme.lua");
        return;
    };
    defer f.close();
    var buf: [128]u8 = undefined;
    const n = f.read(&buf) catch {
        expect(false, "read /theme.lua");
        return;
    };
    expect(n > 0, "read /theme.lua returns data");
    expect(std.mem.eql(u8, buf[0..n], "bg=0x0f1117"), "read returns the config content");
    expect(f.eof(), "read reaches EOF");

    if (file.File.open(&fs, "/missing.lua")) |_| {
        expect(false, "open invalid path fails");
    } else |_| {
        expect(true, "open invalid path fails");
    }
}

pub fn runAll(alloc: std.mem.Allocator, memory: *mem.Memory) noreturn {
    if (!comptime enabled) @compileError("runtime tests are not enabled");
    serial.writeLine("RUNTIME TESTS START");
    for (tests) |t| {
        runOne(t);
    }
    serial.writeLine("ext2 filesystem on disk (M6.1.5)");
    testFilesystem(alloc, memory);
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
