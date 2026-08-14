const std = @import("std");
const lua_c = @import("cimport.zig").c;
const libc = @import("libc.zig");
const serial = @import("../serial.zig");
const bindings = @import("bindings.zig");
const tar_mod = @import("../fs/tar.zig");

var lua_state: ?*lua_c.lua_State = null;
var heap_allocator: std.mem.Allocator = undefined;
var initrd: ?[]const u8 = null;

/// Instruction budget for one kernel → Lua call (brief Task 7b, audit §3.6).
/// `lua_pcall` catches runtime errors but not an infinite loop — `while true
/// do end` in the shell would otherwise monopolize the CPU forever (the
/// preemptive scheduler only yields at the timer tick and the shell runs on
/// the main context). A count hook (LUA_MASKCOUNT) raises a Lua error after
/// this many VM instructions, which the same lua_pcall that catches runtime
/// errors also catches, driving the existing error-containment / hot-reload
/// path. The value is well above a legitimate heavy render (the WM draws tens
/// of primitives per frame, far under 10M VM instructions) yet small enough
/// that an infinite loop trips within a frame budget (frame latency p99
/// target < 16 ms, spec/invariants.md §2).
const instruction_budget: c_int = 10_000_000;

pub fn getState() ?*lua_c.lua_State {
    return lua_state;
}

/// The shell modules are packed into the initrd tar (build.zig) and read at
/// runtime (M6). Set once at boot from the bootloader module.
pub fn setInitrd(data: ?[]const u8) void {
    initrd = data;
}

fn luaAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    _ = ud;
    if (nsize == 0) {
        if (ptr != null) {
            const p: [*]u8 = @ptrCast(@alignCast(ptr.?));
            heap_allocator.free(p[0..osize]);
        }
        return null;
    }
    if (ptr == null) {
        const mem = heap_allocator.alloc(u8, nsize) catch return null;
        return mem.ptr;
    }
    const old: [*]u8 = @ptrCast(@alignCast(ptr.?));
    const resized = heap_allocator.realloc(old[0..osize], nsize) catch return null;
    return resized.ptr;
}

pub fn init(allocator: std.mem.Allocator) void {
    heap_allocator = allocator;
    libc.setHeapAllocator(allocator);
    createState();
}

/// Close the current Lua state and create a fresh one (hot reload,
/// spec/runtime.md §5). Userdata/callbacks of the old state are freed
/// with it, so nothing survives a reload.
pub fn reload() void {
    if (lua_state) |old| {
        lua_c.lua_close(old);
        lua_state = null;
    }
    createState();
}

fn createState() void {
    lua_state = lua_c.lua_newstate(luaAlloc, null);
    if (lua_state == null) return;
    openLibraries(lua_state.?);
}
const Library = struct {
    name: [*:0]const u8,
    opener: *const fn (L: ?*lua_c.lua_State) callconv(.c) c_int,
};

fn openLibraries(L: *lua_c.lua_State) void {
    const libs = [_]Library{
        .{ .name = lua_c.LUA_GNAME, .opener = lua_c.luaopen_base },
        .{ .name = lua_c.LUA_COLIBNAME, .opener = lua_c.luaopen_coroutine },
        .{ .name = lua_c.LUA_TABLIBNAME, .opener = lua_c.luaopen_table },
        .{ .name = lua_c.LUA_STRLIBNAME, .opener = lua_c.luaopen_string },
        .{ .name = lua_c.LUA_UTF8LIBNAME, .opener = lua_c.luaopen_utf8 },
        .{ .name = lua_c.LUA_MATHLIBNAME, .opener = lua_c.luaopen_math },
        // Lua's debug library is opened as 'dbg' because the 'debug' name is
        // taken by the KI debug module (debug.write); see spec/roadmap.md
        // M6.1.9. Stock luaopen_debug cannot be used: its debug.debug reads
        // stdin, which the kernel does not have — only traceback is opened.
        .{ .name = "dbg", .opener = openDbg },
    };
    for (libs) |lib| {
        lua_c.luaL_requiref(L, lib.name, lib.opener, 1);
        lua_c.lua_pop(L, 1);
    }
    bindings.register(L);
}

const DbgFuncs = [_]lua_c.luaL_Reg{
    .{ .name = "traceback", .func = dbgTraceback },
    .{ .name = null, .func = null },
};

/// dbg.traceback([message], [level]) — formats a stack traceback of the
/// current Lua state (luaL_traceback, like the stock library's traceback).
fn dbgTraceback(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const msg = lua_c.lua_tolstring(L, 1, null);
    const level: c_int = if (lua_c.lua_isnoneornil(L, 2))
        1
    else
        @intCast(lua_c.lua_tointegerx(L, 2, null));
    lua_c.luaL_traceback(L, L, msg, level);
    return 1;
}

fn openDbg(L: ?*lua_c.lua_State) callconv(.c) c_int {
    lua_c.lua_createtable(L, 0, 1);
    lua_c.luaL_setfuncs(L, @ptrCast(&DbgFuncs), 0);
    return 1;
}

/// The shell is split into small modules concatenated into one chunk in
/// dependency order (theme first, entry point last). Keeping it one chunk
/// means `local` state is shared across the whole shell, and there is no
/// `require`/filesystem dependency in the kernel.
const shell_files = [_][]const u8{ "theme.lua", "wm.lua", "repl.lua", "editor.lua", "files.lua", "launcher.lua", "input.lua", "main.lua" };

/// Concatenate the shell modules read from the initrd tar into a fresh heap
/// buffer. The caller frees it after loading.
fn loadShellSource() ![]const u8 {
    const tar = initrd orelse return error.NoInitrd;
    var total: usize = 0;
    for (shell_files) |f| {
        total += (try tar_mod.find(tar, f)).len;
    }
    const buf = try heap_allocator.alloc(u8, total);
    errdefer heap_allocator.free(buf);
    var offset: usize = 0;
    for (shell_files) |f| {
        const data = try tar_mod.find(tar, f);
        @memcpy(buf[offset .. offset + data.len], data);
        offset += data.len;
    }
    return buf[0..offset];
}

pub fn runMain(entry: []const u8) !void {
    const L = lua_state orelse return error.NotReady;
    const src = try loadShellSource();
    defer heap_allocator.free(src);
    var name_buf: [64]u8 = undefined;
    const name = if (entry.len < name_buf.len) blk: {
        @memcpy(name_buf[0..entry.len], entry);
        name_buf[entry.len] = 0;
        break :blk name_buf[0..entry.len :0];
    } else "main.lua";
    const status = lua_c.luaL_loadbufferx(
        L,
        @ptrCast(@constCast(src.ptr)),
        src.len,
        name.ptr,
        null,
    );
    if (status != lua_c.LUA_OK) {
        const err = lua_c.lua_tolstring(L, -1, null);
        if (err) |e| serial.writeLine(std.mem.span(e));
        return error.LuaLoadFailed;
    }
    const run_status = lua_c.lua_pcallk(L, 0, 0, 0, 0, null);
    if (run_status != lua_c.LUA_OK) {
        const err = lua_c.lua_tolstring(L, -1, null);
        if (err) |e| serial.writeLine(std.mem.span(e));
        return error.LuaRunFailed;
    }
}

/// Result of calling a Lua global function.
pub const CallResult = enum {
    ok,
    no_function,
    err,
};

/// Count hook (LUA_MASKCOUNT): fires after `instruction_budget` VM
/// instructions and raises a Lua error, caught by the surrounding lua_pcall.
fn instructionBudgetHook(L: ?*lua_c.lua_State, ar: ?*lua_c.lua_Debug) callconv(.c) void {
    _ = ar;
    _ = lua_c.luaL_error(L, "instruction budget exceeded");
}

/// Arm the instruction budget for one kernel → Lua call.
fn armBudget(L: *lua_c.lua_State) void {
    _ = lua_c.lua_sethook(L, instructionBudgetHook, lua_c.LUA_MASKCOUNT, instruction_budget);
}

/// Disarm the instruction budget after the call returns.
fn disarmBudget(L: *lua_c.lua_State) void {
    _ = lua_c.lua_sethook(L, null, 0, 0);
}

/// Call a named Lua function (global) if it is defined. Every entry from the
/// kernel into Lua goes through lua_pcall so a script error cannot unwind
/// into the Zig stack (spec/runtime.md §5). The instruction budget is armed
/// for the call: an infinite loop raises a Lua error caught here, so the
/// shell hot-reloads instead of freezing (brief Task 7b).
fn callGlobalFunction(name: [*:0]const u8) CallResult {
    const L = lua_state orelse return .no_function;
    _ = lua_c.lua_getglobal(L, name);
    if (!lua_c.lua_isfunction(L, -1)) {
        _ = lua_c.lua_pop(L, 1);
        return .no_function;
    }
    armBudget(L);
    defer disarmBudget(L);
    const status = lua_c.lua_pcallk(L, 0, 0, 0, 0, null);
    if (status != lua_c.LUA_OK) {
        if (lua_c.lua_isstring(L, -1) != 0) {
            var len: usize = 0;
            const ptr = lua_c.lua_tolstring(L, -1, &len);
            serial.write("shell: ");
            serial.write(std.mem.span(name));
            serial.writeLine(" failed:");
            serial.writeLine(ptr[0..len]);
        }
        _ = lua_c.lua_pop(L, 1);
        return .err;
    }
    return .ok;
}

/// Call the Lua `render()` function if it is defined.
pub fn callRender() CallResult {
    return callGlobalFunction("render");
}

/// Call the Lua `update()` function if it is defined.
pub fn callUpdate() CallResult {
    return callGlobalFunction("update");
}

/// Run a GC step within the frame budget (see spec/runtime.md §6).
pub fn gcStep(budget: usize) void {
    const L = lua_state orelse return;
    const b: c_int = @intCast(@min(budget, std.math.maxInt(c_int)));
    _ = lua_c.lua_gc(L, lua_c.LUA_GCSTEP, b);
}
