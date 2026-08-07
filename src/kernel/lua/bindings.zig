const std = @import("std");
const lua_c = @import("cimport.zig").c;
const sys = @import("../api/sys.zig");
const graphics = @import("../api/graphics.zig");
const input = @import("../input.zig");
const layout = @import("../input/layout.zig");
const input_queue = @import("../input_queue.zig");
const idt = @import("../cpu/idt.zig");

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

fn gfxDrawRect(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const x = checkInteger(L, 1, "x") orelse return 2;
    const y = checkInteger(L, 2, "y") orelse return 2;
    const w = checkInteger(L, 3, "w") orelse return 2;
    const h = checkInteger(L, 4, "h") orelse return 2;
    const color = checkInteger(L, 5, "color") orelse return 2;

    const RectArgs = extern struct {
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        color: u32,
    };
    var rect = RectArgs{
        .x = @intCast(x),
        .y = @intCast(y),
        .w = @intCast(w),
        .h = @intCast(h),
        .color = @intCast(color),
    };
    _ = sys.dispatch(.Graphics, .{
        .a = @intFromEnum(graphics.GraphicsOp.draw_rect),
        .b = @intFromPtr(&rect),
    });
    lua_c.lua_pushinteger(L, 0);
    return 1;
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
        .x = @intCast(x),
        .y = @intCast(y),
        .color = @intCast(color),
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
        .b = @intCast(color),
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

fn timeTicks(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const ticks = idt.tick_counter.load(.monotonic);
    lua_c.lua_pushinteger(L, @intCast(ticks));
    return 1;
}

fn inputNextEvent(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const event = input_queue.global.pop() orelse {
        lua_c.lua_pushnil(L);
        return 1;
    };
    lua_c.lua_createtable(L, 0, 5);
    switch (event) {
        .timer_tick => |t| {
            _ = lua_c.lua_pushliteral(L, "timer");
            lua_c.lua_setfield(L, -2, "type");
            lua_c.lua_pushinteger(L, @intCast(t));
            lua_c.lua_setfield(L, -2, "tick");
        },
        .key => |key| {
            setShift(key.code, key.pressed);
            if (key.code == .caps_lock) setCapsLock(key.pressed);
            setCtrl(key.code, key.pressed);
            _ = lua_c.lua_pushliteral(L, "key");
            lua_c.lua_setfield(L, -2, "type");
            lua_c.lua_pushboolean(L, if (key.pressed) 1 else 0);
            lua_c.lua_setfield(L, -2, "pressed");
            const name = input.eventName(key);
            const name_ptr: [*c]const u8 = @ptrCast(name.ptr);
            _ = lua_c.lua_pushlstring(L, name_ptr, name.len);
            lua_c.lua_setfield(L, -2, "code");
            lua_c.lua_pushboolean(L, if (effectiveShift()) 1 else 0);
            lua_c.lua_setfield(L, -2, "shift");
            lua_c.lua_pushboolean(L, if (ctrl_pressed) 1 else 0);
            lua_c.lua_setfield(L, -2, "ctrl");
            const eff_shift = effectiveShift();
            const l = layout.Layout{ .shift = eff_shift, .ctrl = ctrl_pressed };
            const mapped = l.mapChar(key.code);
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
    }
    return 1;
}

var shift_pressed = false;
var caps_lock_on = false;
var ctrl_pressed = false;

fn setShift(code: input.KeyCode, pressed: bool) void {
    switch (code) {
        .shift_left, .shift_right => shift_pressed = pressed,
        else => {},
    }
}

fn setCapsLock(pressed: bool) void {
    if (pressed) caps_lock_on = !caps_lock_on;
}

fn setCtrl(code: input.KeyCode, pressed: bool) void {
    switch (code) {
        .ctrl_left, .ctrl_right => ctrl_pressed = pressed,
        else => {},
    }
}

/// Effective shift for letters: shift XOR caps lock (letters are
/// uppercase when exactly one of the two is active).
fn effectiveShift() bool {
    return shift_pressed != caps_lock_on;
}

const GfxFuncs = [_]lua_c.luaL_Reg{
    .{ .name = "draw_rect", .func = gfxDrawRect },
    .{ .name = "draw_text", .func = gfxDrawText },
    .{ .name = "fill_screen", .func = gfxFillScreen },
    .{ .name = "present", .func = gfxPresent },
    .{ .name = null, .func = null },
};

const InputFuncs = [_]lua_c.luaL_Reg{
    .{ .name = "next_event", .func = inputNextEvent },
    .{ .name = null, .func = null },
};

const TimeFuncs = [_]lua_c.luaL_Reg{
    .{ .name = "ticks", .func = timeTicks },
    .{ .name = null, .func = null },
};

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
}
