const std = @import("std");
const lua_c = @import("cimport.zig").c;
const sys = @import("../api/sys.zig");
const graphics = @import("../api/graphics.zig");
const api_input = @import("../api/input.zig");
const api_timer = @import("../api/timer.zig");
const api_debug = @import("../api/debug.zig");
const api_runtime = @import("../api/runtime.zig");
const api_power = @import("../api/power.zig");
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

fn gfxRoundRect(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const x = checkInteger(L, 1, "x") orelse return 2;
    const y = checkInteger(L, 2, "y") orelse return 2;
    const w = checkInteger(L, 3, "w") orelse return 2;
    const h = checkInteger(L, 4, "h") orelse return 2;
    const radius = checkInteger(L, 5, "radius") orelse return 2;
    const color = checkInteger(L, 6, "color") orelse return 2;

    const RoundRectArgs = extern struct {
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        radius: u32,
        color: u32,
    };
    var args = RoundRectArgs{
        .x = @intCast(x),
        .y = @intCast(y),
        .w = @intCast(w),
        .h = @intCast(h),
        .radius = @intCast(radius),
        .color = @intCast(color),
    };
    _ = sys.dispatch(.Graphics, .{
        .a = @intFromEnum(graphics.GraphicsOp.round_rect),
        .b = @intFromPtr(&args),
    });
    lua_c.lua_pushinteger(L, 0);
    return 1;
}

fn gfxRectBorder(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const x = checkInteger(L, 1, "x") orelse return 2;
    const y = checkInteger(L, 2, "y") orelse return 2;
    const w = checkInteger(L, 3, "w") orelse return 2;
    const h = checkInteger(L, 4, "h") orelse return 2;
    const thickness = checkInteger(L, 5, "thickness") orelse return 2;
    const color = checkInteger(L, 6, "color") orelse return 2;

    const BorderArgs = extern struct {
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        thickness: u32,
        color: u32,
    };
    var args = BorderArgs{
        .x = @intCast(x),
        .y = @intCast(y),
        .w = @intCast(w),
        .h = @intCast(h),
        .thickness = @intCast(thickness),
        .color = @intCast(color),
    };
    _ = sys.dispatch(.Graphics, .{
        .a = @intFromEnum(graphics.GraphicsOp.rect_border),
        .b = @intFromPtr(&args),
    });
    lua_c.lua_pushinteger(L, 0);
    return 1;
}

fn gfxGradientBorder(L: ?*lua_c.lua_State) callconv(.c) c_int {
    const x = checkInteger(L, 1, "x") orelse return 2;
    const y = checkInteger(L, 2, "y") orelse return 2;
    const w = checkInteger(L, 3, "w") orelse return 2;
    const h = checkInteger(L, 4, "h") orelse return 2;
    const thickness = checkInteger(L, 5, "thickness") orelse return 2;
    const color_a = checkInteger(L, 6, "color_a") orelse return 2;
    const color_b = checkInteger(L, 7, "color_b") orelse return 2;

    const GradientBorderArgs = extern struct {
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        thickness: u32,
        color_a: u32,
        color_b: u32,
    };
    var args = GradientBorderArgs{
        .x = @intCast(x),
        .y = @intCast(y),
        .w = @intCast(w),
        .h = @intCast(h),
        .thickness = @intCast(thickness),
        .color_a = @intCast(color_a),
        .color_b = @intCast(color_b),
    };
    _ = sys.dispatch(.Graphics, .{
        .a = @intFromEnum(graphics.GraphicsOp.gradient_border),
        .b = @intFromPtr(&args),
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
            setShift(key.code, key.pressed);
            if (key.code == .caps_lock) setCapsLock(key.pressed);
            setCtrl(key.code, key.pressed);
            setAlt(key.code, key.pressed);
            setAltGr(key.code, key.pressed);
            setSuper(key.code, key.pressed);
            _ = lua_c.lua_pushliteral(L, "key");
            lua_c.lua_setfield(L, -2, "type");
            lua_c.lua_pushboolean(L, if (key.pressed) 1 else 0);
            lua_c.lua_setfield(L, -2, "pressed");
            const name = api_input.eventName(key);
            const name_ptr: [*c]const u8 = @ptrCast(name.ptr);
            _ = lua_c.lua_pushlstring(L, name_ptr, name.len);
            lua_c.lua_setfield(L, -2, "code");
            lua_c.lua_pushboolean(L, if (effectiveShift()) 1 else 0);
            lua_c.lua_setfield(L, -2, "shift");
            lua_c.lua_pushboolean(L, if (ctrl_pressed) 1 else 0);
            lua_c.lua_setfield(L, -2, "ctrl");
            lua_c.lua_pushboolean(L, if (alt_pressed) 1 else 0);
            lua_c.lua_setfield(L, -2, "alt");
            lua_c.lua_pushboolean(L, if (super_pressed) 1 else 0);
            lua_c.lua_setfield(L, -2, "super");
            lua_c.lua_pushboolean(L, if (alt_gr_pressed) 1 else 0);
            lua_c.lua_setfield(L, -2, "alt_gr");
            const eff_shift = effectiveShift();
            const mapped = api_input.mapChar(key.code, .{
                .shift = eff_shift,
                .ctrl = ctrl_pressed,
                .alt = alt_pressed,
                .alt_gr = alt_gr_pressed,
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

var shift_pressed = false;
var caps_lock_on = false;
var ctrl_pressed = false;
var alt_pressed = false;
var super_pressed = false;
var alt_gr_pressed = false;

fn setShift(code: api_input.KeyCode, pressed: bool) void {
    switch (code) {
        .shift_left, .shift_right => shift_pressed = pressed,
        else => {},
    }
}

fn setAlt(code: api_input.KeyCode, pressed: bool) void {
    switch (code) {
        .alt_left => alt_pressed = pressed,
        else => {},
    }
}

fn setAltGr(code: api_input.KeyCode, pressed: bool) void {
    switch (code) {
        .alt_right => alt_gr_pressed = pressed,
        else => {},
    }
}

fn setSuper(code: api_input.KeyCode, pressed: bool) void {
    switch (code) {
        .super_left, .super_right => super_pressed = pressed,
        else => {},
    }
}

fn setCapsLock(pressed: bool) void {
    if (pressed) caps_lock_on = !caps_lock_on;
}

fn setCtrl(code: api_input.KeyCode, pressed: bool) void {
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
    .{ .name = "round_rect", .func = gfxRoundRect },
    .{ .name = "rect_border", .func = gfxRectBorder },
    .{ .name = "gradient_border", .func = gfxGradientBorder },
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

const PowerFuncs = [_]lua_c.luaL_Reg{
    .{ .name = "reboot", .func = powerReboot },
    .{ .name = null, .func = null },
};

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

fn powerReboot(L: ?*lua_c.lua_State) callconv(.c) c_int {
    _ = sys.dispatch(.Power, .{ .a = @intFromEnum(api_power.PowerOp.reboot) });
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

    lua_c.lua_createtable(L, 0, 1);
    lua_c.luaL_setfuncs(L, @ptrCast(&PowerFuncs), 0);
    lua_c.lua_setglobal(L, "power");
}
