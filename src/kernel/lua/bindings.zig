const std = @import("std");
const lua_c = @import("cimport.zig").c;
const sys = @import("../api/sys.zig");
const graphics = @import("../api/graphics.zig");
const api_input = @import("../api/input.zig");
const api_timer = @import("../api/timer.zig");
const api_debug = @import("../api/debug.zig");
const api_runtime = @import("../api/runtime.zig");
const api_storage = @import("../api/storage.zig");
const sysmon = @import("../api/sysmon.zig");

fn pushError(L: ?*lua_c.lua_State, comptime format: []const u8, args: anytype) void {
    lua_c.lua_pushnil(L);
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, format, args) catch "error";
    const msg_ptr: [*c]const u8 = @ptrCast(msg.ptr);
    _ = lua_c.lua_pushlstring(L, msg_ptr, msg.len);
}

fn typenameSlice(L: ?*lua_c.lua_State, index: c_int) []const u8 {
    const t = lua_c.luaL_typename(L, index);
    return std.mem.span(t);
}

fn checkInteger(L: ?*lua_c.lua_State, index: c_int, comptime name: []const u8) ?lua_c.lua_Integer {
    if (lua_c.lua_isinteger(L, index) == 0) {
        pushError(L, "expected integer for '{s}', got {s}", .{ name, typenameSlice(L, index) });
        return null;
    }
    const null_isnum: [*c]c_int = @ptrFromInt(0);
    return lua_c.lua_tointegerx(L, index, null_isnum);
}

fn checkString(L: ?*lua_c.lua_State, index: c_int, comptime name: []const u8) ?[]const u8 {
    if (lua_c.lua_isstring(L, index) == 0) {
        pushError(L, "expected string for '{s}', got {s}", .{ name, typenameSlice(L, index) });
        return null;
    }
    var len: usize = 0;
    const ptr = lua_c.lua_tolstring(L, index, &len);
    return ptr[0..len];
}

/// Cast a Lua integer to a binding field type, returning null (with a Lua
/// error) when it is out of range. Guards the kernel against @intCast panics
/// that would halt it in ReleaseSafe (audit 2026-08-15, Critical).
fn castChecked(L: ?*lua_c.lua_State, comptime T: type, v: lua_c.lua_Integer, comptime name: []const u8) ?T {
    if (std.math.cast(T, v)) |val| return val;
    pushError(L, "integer out of range for '{s}'", .{name});
    return null;
}

const RectArgs = extern struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    color: u32,
};

const RoundRectArgs = extern struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    radius: u32,
    color: u32,
};

const BorderArgs = extern struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    thickness: u32,
    color: u32,
};

const GradientBorderArgs = extern struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    thickness: u32,
    color_a: u32,
    color_b: u32,
};

/// Generate a Lua binding for a graphics op that takes only integer args.
/// The extern struct's field order is the Lua argument order (and the
/// graphics.zig ABI contract); every field is checked and copied with the
/// same error path as a hand-written binding. Called via sys.dispatch with
/// the struct pointer, mirroring the other binding shapes.
fn makeGfxOp(comptime op: graphics.GraphicsOp, comptime Args: type) fn (?*lua_c.lua_State) callconv(.c) c_int {
    return struct {
        fn call(L: ?*lua_c.lua_State) callconv(.c) c_int {
            var args: Args = undefined;
            inline for (std.meta.fields(Args), 1..) |field, i| {
                const v = checkInteger(L, @intCast(i), field.name) orelse return 2;
                @field(args, field.name) = castChecked(L, field.type, v, field.name) orelse return 2;
            }
            _ = sys.dispatch(.Graphics, .{
                .a = @intFromEnum(op),
                .b = @intFromPtr(&args),
            });
            lua_c.lua_pushinteger(L, 0);
            return 1;
        }
    }.call;
}

fn gfxDrawText(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const text = checkString(L, 1, "text") orelse return 2;
    const x = checkInteger(L, 2, "x") orelse return 2;
    const y = checkInteger(L, 3, "y") orelse return 2;
    const color = checkInteger(L, 4, "color") orelse return 2;

    const TextArgs = extern struct {
        text: u64,
        len: u64,
        x: i32,
        y: i32,
        color: u32,
    };
    var t = TextArgs{
        .text = @intFromPtr(text.ptr),
        .len = text.len,
        .x = castChecked(L, i32, x, "x") orelse return 2,
        .y = castChecked(L, i32, y, "y") orelse return 2,
        .color = castChecked(L, u32, color, "color") orelse return 2,
    };
    _ = sys.dispatch(.Graphics, .{
        .a = @intFromEnum(graphics.GraphicsOp.draw_text),
        .b = @intFromPtr(&t),
    });
    lua_c.lua_pushinteger(L, 0);
    return 1;
}

fn gfxFillScreen(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const color = checkInteger(L, 1, "color") orelse return 2;
    _ = sys.dispatch(.Graphics, .{
        .a = @intFromEnum(graphics.GraphicsOp.fill_screen),
        .b = castChecked(L, u32, color, "color") orelse return 2,
    });
    lua_c.lua_pushinteger(L, 0);
    return 1;
}

fn gfxPresent(L: ?*lua_c.lua_State) callconv(.c) c_int {
    _ = sys.dispatch(.Graphics, .{
        .a = @intFromEnum(graphics.GraphicsOp.present),
    });
    lua_c.lua_pushinteger(L, 0);
    return 1;
}

fn gfxInvalidate(L: ?*lua_c.lua_State) callconv(.c) c_int {
    _ = sys.dispatch(.Graphics, .{
        .a = @intFromEnum(graphics.GraphicsOp.invalidate),
    });
    lua_c.lua_pushinteger(L, 0);
    return 1;
}

fn gfxWidth(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const value = sys.dispatch(.Graphics, .{ .a = @intFromEnum(graphics.GraphicsOp.width) });
    lua_c.lua_pushinteger(L, @intCast(value));
    return 1;
}

fn gfxHeight(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const value = sys.dispatch(.Graphics, .{ .a = @intFromEnum(graphics.GraphicsOp.height) });
    lua_c.lua_pushinteger(L, @intCast(value));
    return 1;
}

fn timeTicks(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const ticks = sys.dispatch(.Timer, .{ .a = @intFromEnum(api_timer.TimerOp.ticks) });
    lua_c.lua_pushinteger(L, @intCast(ticks));
    return 1;
}

fn inputNextEvent(L: ?*lua_c.lua_State) callconv(.c) c_int {
    // Mouse packets are consumed by the kernel cursor overlay and filtered
    // out by the KI input module; a busy mouse cannot flood the Lua stream.
    var event: api_input.Event = undefined;
    const has_event = sys.dispatch(.Input, .{
        .a = @intFromEnum(api_input.InputOp.next_event),
        .b = @intFromPtr(&event),
    });
    if (has_event == 0) {
        lua_c.lua_pushnil(L);
        return 1;
    }
    buildEventTable(L, event);
    return 1;
}

fn inputMouseX(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const value = sys.dispatch(.Input, .{ .a = @intFromEnum(api_input.InputOp.mouse_x) });
    lua_c.lua_pushinteger(L, @intCast(value));
    return 1;
}

fn inputMouseY(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const value = sys.dispatch(.Input, .{ .a = @intFromEnum(api_input.InputOp.mouse_y) });
    lua_c.lua_pushinteger(L, @intCast(value));
    return 1;
}

fn inputMouseLeft(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const value = sys.dispatch(.Input, .{ .a = @intFromEnum(api_input.InputOp.mouse_left) });
    lua_c.lua_pushboolean(L, @intCast(value));
    return 1;
}

fn inputMouseRight(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const value = sys.dispatch(.Input, .{ .a = @intFromEnum(api_input.InputOp.mouse_right) });
    lua_c.lua_pushboolean(L, @intCast(value));
    return 1;
}

fn inputMouseMiddle(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const value = sys.dispatch(.Input, .{ .a = @intFromEnum(api_input.InputOp.mouse_middle) });
    lua_c.lua_pushboolean(L, @intCast(value));
    return 1;
}

fn inputSetLayout(L: ?*lua_c.lua_State) callconv(.c) c_int {
    // Copy the name into a fixed buffer so the KI handler sees a
    // NUL-terminated string; the active layout is registry state owned by
    // the input subsystem (ADR-024).
    const name = checkString(L, 1, "name") orelse return 2;
    var buf: [32]u8 = undefined;
    const copy_len = @min(name.len, buf.len - 1);
    @memcpy(buf[0..copy_len], name[0..copy_len]);
    buf[copy_len] = 0;
    const status = sys.dispatch(.Input, .{
        .a = @intFromEnum(api_input.InputOp.set_layout),
        .b = @intFromPtr(&buf),
    });
    const ok = status == @intFromEnum(sys.KiStatus.Success);
    lua_c.lua_pushboolean(L, if (ok) 1 else 0);
    return 1;
}

fn inputLayoutName(L: ?*lua_c.lua_State) callconv(.c) c_int {
    var buf: [32]u8 = undefined;
    const len = sys.dispatch(.Input, .{
        .a = @intFromEnum(api_input.InputOp.layout_name),
        .b = @intFromPtr(&buf),
    });
    const name: [*c]const u8 = @ptrCast(&buf);
    _ = lua_c.lua_pushlstring(L, name, @intCast(len));
    return 1;
}

fn buildEventTable(L: ?*lua_c.lua_State, event: api_input.Event) void {
    lua_c.lua_createtable(L, 0, 5);
    switch (event) {
        .timer_tick => |t| {
            _ = lua_c.lua_pushliteral(L, "timer");
            lua_c.lua_setfield(L, -2, "type");
            lua_c.lua_pushinteger(L, @intCast(t));
            lua_c.lua_setfield(L, -2, "tick");
        },
        .key => |key| {
            api_input.setModifier(key.code, key.pressed);
            if (key.code == .caps_lock) api_input.setCapsLock(key.pressed);
            _ = lua_c.lua_pushliteral(L, "key");
            lua_c.lua_setfield(L, -2, "type");
            lua_c.lua_pushboolean(L, if (key.pressed) 1 else 0);
            lua_c.lua_setfield(L, -2, "pressed");
            const name = api_input.eventName(key);
            const name_ptr: [*c]const u8 = @ptrCast(name.ptr);
            _ = lua_c.lua_pushlstring(L, name_ptr, name.len);
            lua_c.lua_setfield(L, -2, "code");
            const mods = api_input.modifierState();
            lua_c.lua_pushboolean(L, if (api_input.effectiveShift()) 1 else 0);
            lua_c.lua_setfield(L, -2, "shift");
            lua_c.lua_pushboolean(L, if (mods.ctrl) 1 else 0);
            lua_c.lua_setfield(L, -2, "ctrl");
            lua_c.lua_pushboolean(L, if (mods.alt) 1 else 0);
            lua_c.lua_setfield(L, -2, "alt");
            lua_c.lua_pushboolean(L, if (api_input.superPressed()) 1 else 0);
            lua_c.lua_setfield(L, -2, "super");
            lua_c.lua_pushboolean(L, if (mods.alt_gr) 1 else 0);
            lua_c.lua_setfield(L, -2, "alt_gr");
            const mapped = api_input.mapChar(key.code, .{
                .shift = api_input.effectiveShift(),
                .ctrl = mods.ctrl,
                .alt = mods.alt,
                .alt_gr = mods.alt_gr,
            });
            if (mapped) |ch| {
                var ch_buf: [1]u8 = .{ch};
                const ch_ptr: [*c]const u8 = @ptrCast(&ch_buf);
                _ = lua_c.lua_pushlstring(L, ch_ptr, 1);
                lua_c.lua_setfield(L, -2, "char");
            } else {
                lua_c.lua_pushnil(L);
                lua_c.lua_setfield(L, -2, "char");
            }
        },
        .mouse => unreachable,
    }
}

const GfxFuncs = [_]lua_c.luaL_Reg{
    .{ .name = "draw_rect", .func = makeGfxOp(.draw_rect, RectArgs) },
    .{ .name = "round_rect", .func = makeGfxOp(.round_rect, RoundRectArgs) },
    .{ .name = "rect_border", .func = makeGfxOp(.rect_border, BorderArgs) },
    .{ .name = "gradient_border", .func = makeGfxOp(.gradient_border, GradientBorderArgs) },
    .{ .name = "draw_text", .func = gfxDrawText },
    .{ .name = "fill_screen", .func = gfxFillScreen },
    .{ .name = "present", .func = gfxPresent },
    .{ .name = "invalidate", .func = gfxInvalidate },
    .{ .name = "width", .func = gfxWidth },
    .{ .name = "height", .func = gfxHeight },
    .{ .name = null, .func = null },
};

const InputFuncs = [_]lua_c.luaL_Reg{
    .{ .name = "next_event", .func = inputNextEvent },
    .{ .name = "mouse_x", .func = inputMouseX },
    .{ .name = "mouse_y", .func = inputMouseY },
    .{ .name = "mouse_left", .func = inputMouseLeft },
    .{ .name = "mouse_right", .func = inputMouseRight },
    .{ .name = "mouse_middle", .func = inputMouseMiddle },
    .{ .name = "set_layout", .func = inputSetLayout },
    .{ .name = "layout_name", .func = inputLayoutName },
    .{ .name = null, .func = null },
};

const TimeFuncs = [_]lua_c.luaL_Reg{
    .{ .name = "ticks", .func = timeTicks },
    .{ .name = null, .func = null },
};

const DebugFuncs = [_]lua_c.luaL_Reg{
    .{ .name = "write", .func = debugWrite },
    .{ .name = null, .func = null },
};

const SysmonFuncs = [_]lua_c.luaL_Reg{
    .{ .name = "ram_total_mb", .func = sysmonRamTotalMb },
    .{ .name = "ram_free_mb", .func = sysmonRamFreeMb },
    .{ .name = null, .func = null },
};

const RuntimeFuncs = [_]lua_c.luaL_Reg{
    .{ .name = "reload", .func = runtimeReload },
    .{ .name = null, .func = null },
};

const FileFuncs = [_]lua_c.luaL_Reg{
    .{ .name = "open", .func = fileOpen },
    .{ .name = "read", .func = fileRead },
    .{ .name = "write", .func = fileWrite },
    .{ .name = "close", .func = fileClose },
    .{ .name = "truncate", .func = fileTruncate },
    .{ .name = "dir", .func = fileDir },
    .{ .name = "remove", .func = fileRemove },
    .{ .name = "create", .func = fileCreate },
    .{ .name = "rename", .func = fileRename },
    .{ .name = null, .func = null },
};

/// The storage KI reports `(status << 32) | value`; a zero status is success.
fn storageResultOk(result: u64) bool {
    return result >> 32 == 0;
}

fn fileOpen(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const path = checkString(L, 1, "path") orelse return 2;
    const result = sys.dispatch(.Storage, .{
        .a = @intFromEnum(api_storage.StorageOp.open),
        .b = @intFromPtr(path.ptr),
        .c = path.len,
    });
    if (storageResultOk(result)) {
        lua_c.lua_pushinteger(L, @intCast(result & 0xFFFFFFFF));
        return 1;
    }
    pushError(L, "file.open failed", .{});
    return 2;
}

fn fileCreate(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const path = checkString(L, 1, "path") orelse return 2;
    const result = sys.dispatch(.Storage, .{
        .a = @intFromEnum(api_storage.StorageOp.create),
        .b = @intFromPtr(path.ptr),
        .c = path.len,
    });
    if (storageResultOk(result)) {
        lua_c.lua_pushinteger(L, @intCast(result & 0xFFFFFFFF));
        return 1;
    }
    pushError(L, "file.create failed", .{});
    return 2;
}

fn fileRead(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const handle = checkInteger(L, 1, "handle") orelse return 2;
    const len = checkInteger(L, 2, "len") orelse return 2;
    var buf: [4096]u8 = undefined;
    const cap: u64 = @min(@as(u64, @intCast(@max(len, 0))), buf.len);
    const ra = api_storage.ReadArgs{
        .handle = castChecked(L, u64, handle, "handle") orelse return 2,
        .buf = @intFromPtr(&buf),
        .len = cap,
    };
    const result = sys.dispatch(.Storage, .{
        .a = @intFromEnum(api_storage.StorageOp.read),
        .b = @intFromPtr(&ra),
    });
    if (storageResultOk(result)) {
        const n: usize = @intCast(result & 0xFFFFFFFF);
        const ptr: [*c]const u8 = @ptrCast(&buf);
        _ = lua_c.lua_pushlstring(L, ptr, n);
        return 1;
    }
    pushError(L, "file.read failed", .{});
    return 2;
}

fn fileWrite(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const handle = checkInteger(L, 1, "handle") orelse return 2;
    const data = checkString(L, 2, "data") orelse return 2;
    const wa = api_storage.WriteArgs{
        .handle = castChecked(L, u64, handle, "handle") orelse return 2,
        .data = @intFromPtr(data.ptr),
        .len = data.len,
    };
    const result = sys.dispatch(.Storage, .{
        .a = @intFromEnum(api_storage.StorageOp.write),
        .b = @intFromPtr(&wa),
    });
    if (storageResultOk(result)) {
        lua_c.lua_pushinteger(L, 0);
        return 1;
    }
    pushError(L, "file.write failed", .{});
    return 2;
}

fn fileClose(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const handle = checkInteger(L, 1, "handle") orelse return 2;
    _ = sys.dispatch(.Storage, .{
        .a = @intFromEnum(api_storage.StorageOp.close),
        .b = castChecked(L, u64, handle, "handle") orelse return 2,
    });
    lua_c.lua_pushinteger(L, 0);
    return 1;
}

fn fileTruncate(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const handle = checkInteger(L, 1, "handle") orelse return 2;
    const new_size = checkInteger(L, 2, "size") orelse return 2;
    const result = sys.dispatch(.Storage, .{
        .a = @intFromEnum(api_storage.StorageOp.truncate),
        .b = castChecked(L, u64, handle, "handle") orelse return 2,
        .c = castChecked(L, u64, new_size, "size") orelse return 2,
    });
    if (storageResultOk(result)) {
        lua_c.lua_pushinteger(L, 0);
        return 1;
    }
    pushError(L, "file.truncate failed", .{});
    return 2;
}

fn fileDir(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const path = checkString(L, 1, "path") orelse return 2;
    var buf: [1024]u8 = undefined;
    const la = api_storage.ListArgs{
        .path = @intFromPtr(path.ptr),
        .path_len = path.len,
        .out = @intFromPtr(&buf),
        .out_cap = buf.len,
    };
    const result = sys.dispatch(.Storage, .{
        .a = @intFromEnum(api_storage.StorageOp.list),
        .b = @intFromPtr(&la),
    });
    if (!storageResultOk(result)) {
        pushError(L, "file.dir failed", .{});
        return 2;
    }
    const n: usize = @intCast(result & 0xFFFFFFFF);
    _ = lua_c.lua_createtable(L, 0, 0);
    var off: usize = 0;
    var idx: c_int = 1;
    while (off + 2 <= n) {
        const name_len: usize = buf[off];
        const is_dir: bool = buf[off + 1] == 1;
        if (off + 2 + name_len > n) break;
        _ = lua_c.lua_createtable(L, 0, 2);
        const name_ptr: [*c]const u8 = @ptrCast(&buf[off + 2]);
        _ = lua_c.lua_pushlstring(L, name_ptr, name_len);
        lua_c.lua_setfield(L, -2, "name");
        lua_c.lua_pushboolean(L, if (is_dir) 1 else 0);
        lua_c.lua_setfield(L, -2, "dir");
        lua_c.lua_rawseti(L, -2, idx);
        idx += 1;
        off += 2 + name_len;
    }
    return 1;
}

fn fileRemove(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const path = checkString(L, 1, "path") orelse return 2;
    const result = sys.dispatch(.Storage, .{
        .a = @intFromEnum(api_storage.StorageOp.remove),
        .b = @intFromPtr(path.ptr),
        .c = path.len,
    });
    if (storageResultOk(result)) {
        lua_c.lua_pushinteger(L, 0);
        return 1;
    }
    pushError(L, "file.remove failed", .{});
    return 2;
}

fn fileRename(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const old_path = checkString(L, 1, "old_path") orelse return 2;
    const new_path = checkString(L, 2, "new_path") orelse return 2;
    const ra = api_storage.RenameArgs{
        .old_path = @intFromPtr(old_path.ptr),
        .old_len = old_path.len,
        .new_path = @intFromPtr(new_path.ptr),
        .new_len = new_path.len,
    };
    const result = sys.dispatch(.Storage, .{
        .a = @intFromEnum(api_storage.StorageOp.rename),
        .b = @intFromPtr(&ra),
    });
    if (storageResultOk(result)) {
        lua_c.lua_pushinteger(L, 0);
        return 1;
    }
    pushError(L, "file.rename failed", .{});
    return 2;
}

fn sysmonRamTotalMb(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const value = sys.dispatch(.Sysmon, .{ .a = @intFromEnum(sysmon.SysmonOp.ram_total_mb) });
    lua_c.lua_pushinteger(L, @intCast(value));
    return 1;
}

fn sysmonRamFreeMb(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const value = sys.dispatch(.Sysmon, .{ .a = @intFromEnum(sysmon.SysmonOp.ram_free_mb) });
    lua_c.lua_pushinteger(L, @intCast(value));
    return 1;
}

fn runtimeReload(L: ?*lua_c.lua_State) callconv(.c) c_int {
    _ = sys.dispatch(.Runtime, .{ .a = @intFromEnum(api_runtime.RuntimeOp.reload) });
    lua_c.lua_pushinteger(L, 0);
    return 1;
}

fn debugWrite(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const text = checkString(L, 1, "text") orelse return 2;
    var buf: [256]u8 = undefined;
    const copy_len = @min(text.len, buf.len);
    @memcpy(buf[0..copy_len], text[0..copy_len]);
    var out_len = copy_len;
    if (out_len < buf.len) {
        buf[out_len] = '\n';
        out_len += 1;
    }
    const out = buf[0..out_len];
    _ = sys.dispatch(.Debug, .{
        .a = @intFromEnum(api_debug.DebugOp.write),
        .b = @intFromPtr(out.ptr),
        .c = out.len,
    });
    lua_c.lua_pushinteger(L, 0);
    return 1;
}

pub fn register(L: *lua_c.lua_State) void {
    lua_c.lua_createtable(L, 0, 4);
    lua_c.luaL_setfuncs(L, @ptrCast(&GfxFuncs), 0);
    lua_c.lua_setglobal(L, "gfx");

    lua_c.lua_createtable(L, 0, 1);
    lua_c.luaL_setfuncs(L, @ptrCast(&InputFuncs), 0);
    lua_c.lua_setglobal(L, "input");

    lua_c.lua_createtable(L, 0, 1);
    lua_c.luaL_setfuncs(L, @ptrCast(&TimeFuncs), 0);
    lua_c.lua_setglobal(L, "time");

    lua_c.lua_createtable(L, 0, 1);
    lua_c.luaL_setfuncs(L, @ptrCast(&DebugFuncs), 0);
    lua_c.lua_setglobal(L, "debug");

    lua_c.lua_createtable(L, 0, 2);
    lua_c.luaL_setfuncs(L, @ptrCast(&SysmonFuncs), 0);
    lua_c.lua_setglobal(L, "sysmon");

    lua_c.lua_createtable(L, 0, 1);
    lua_c.luaL_setfuncs(L, @ptrCast(&RuntimeFuncs), 0);
    lua_c.lua_setglobal(L, "runtime");

    lua_c.lua_createtable(L, 0, 5);
    lua_c.luaL_setfuncs(L, @ptrCast(&FileFuncs), 0);
    lua_c.lua_setglobal(L, "file");
}
