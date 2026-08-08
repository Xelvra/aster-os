const std = @import("std");
const lua_c = @import("cimport.zig").c;
const libc = @import("libc.zig");
const serial = @import("../serial.zig");
const bindings = @import("bindings.zig");

var lua_state: ?*lua_c.lua_State = null;
var heap_allocator: std.mem.Allocator = undefined;

pub fn getState() ?*lua_c.lua_State {
    return lua_state;
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
    };
    for (libs) |lib| {
        lua_c.luaL_requiref(L, lib.name, lib.opener, 1);
        lua_c.lua_pop(L, 1);
    }
    bindings.register(L);
}

/// The shell is split into small modules that are concatenated into one
/// chunk in dependency order (theme first, entry point last). Keeping it one
/// chunk means `local` state is shared across the whole shell, and there is
/// no `require`/filesystem dependency in the kernel.
const theme_src = @embedFile("ui/theme.lua");
const wm_src = @embedFile("ui/wm.lua");
const repl_src = @embedFile("ui/repl.lua");
const launcher_src = @embedFile("ui/launcher.lua");
const input_src = @embedFile("ui/input.lua");
const entry_src = @embedFile("ui/main.lua");
const shell_src = theme_src ++ wm_src ++ repl_src ++ launcher_src ++ input_src ++ entry_src;

pub fn runMain(entry: []const u8) !void {
    const L = lua_state orelse return error.NotReady;
    var name_buf: [64]u8 = undefined;
    const name = if (entry.len < name_buf.len) blk: {
        @memcpy(name_buf[0..entry.len], entry);
        name_buf[entry.len] = 0;
        break :blk name_buf[0..entry.len :0];
    } else "main.lua";
    const status = lua_c.luaL_loadbufferx(
        L,
        @ptrCast(@constCast(shell_src.ptr)),
        shell_src.len,
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

/// Call a named Lua function (global) if it is defined. Every entry from the
/// kernel into Lua goes through lua_pcall so a script error cannot unwind
/// into the Zig stack (spec/runtime.md §5).
fn callGlobalFunction(name: [*:0]const u8) CallResult {
    const L = lua_state orelse return .no_function;
    _ = lua_c.lua_getglobal(L, name);
    if (!lua_c.lua_isfunction(L, -1)) {
        _ = lua_c.lua_pop(L, 1);
        return .no_function;
    }
    const status = lua_c.lua_pcallk(L, 0, 0, 0, 0, null);
    if (status != lua_c.LUA_OK) {
        if (lua_c.lua_isstring(L, -1) != 0) {
            var len: usize = 0;
            const ptr = lua_c.lua_tolstring(L, -1, &len);
            serial.write("shell: {s} failed: ");
            serial.write(std.mem.span(name));
            serial.writeLine("");
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
