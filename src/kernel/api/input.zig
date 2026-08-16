const std = @import("std");
const sys = @import("sys.zig");
const service = @import("../input/service.zig");
const validate = @import("validate.zig");

pub const Event = service.Event;
pub const KeyCode = service.KeyCode;
pub const KeyEvent = service.KeyEvent;
pub const MouseEvent = service.MouseEvent;
pub const Layout = service.Layout;
pub const Modifiers = service.Modifiers;
pub const eventName = service.eventName;
pub const mapChar = service.mapChar;
pub const layoutName = service.layoutName;
pub const setLayout = service.setLayout;
pub const modifierState = service.modifierState;
pub const setModifier = service.setModifier;
pub const setCapsLock = service.setCapsLock;
pub const capsLockOn = service.capsLockOn;
pub const superPressed = service.superPressed;
pub const effectiveShift = service.effectiveShift;

pub const InputOp = enum(u64) {
    next_event = 0,
    peek_event = 1,
    flush = 2,
    mouse_x = 3,
    mouse_y = 4,
    mouse_left = 5,
    mouse_right = 6,
    mouse_middle = 7,
    set_layout = 8,
    layout_name = 9,
    mouse_wheel = 10,
};

pub fn dispatch(args: sys.SyscallArgs) u64 {
    const op = validate.opEnum(InputOp, args.a) orelse return @intFromEnum(sys.KiStatus.NotSupported);
    return switch (op) {
        .next_event => nextEvent(args.b),
        .peek_event => peekEvent(args.b),
        .flush => flush(),
        .mouse_x => @intCast(service.mouseX()),
        .mouse_y => @intCast(service.mouseY()),
        .mouse_left => boolToU64(service.mouseLeft()),
        .mouse_right => boolToU64(service.mouseRight()),
        .mouse_middle => boolToU64(service.mouseMiddle()),
        // wheel is signed (down = negative); return the two's-complement i64
        // so a negative delta survives the u64 syscall result (a plain
        // @intCast of a negative i32 would panic in ReleaseSafe).
        .mouse_wheel => @as(u64, @bitCast(@as(i64, service.mouseWheel()))),
        .set_layout => setLayoutOp(args.b),
        .layout_name => layoutNameOp(args.b, args.c),
    };
}

/// input.set_layout(name_ptr) — switch the active keyboard layout (ADR-024).
fn setLayoutOp(name_ptr: u64) u64 {
    const checked = validate.checkPtr(name_ptr, u8) orelse return @intFromEnum(sys.KiStatus.InvalidArgument);
    const name: [*:0]const u8 = @ptrCast(checked);
    const ok = service.setLayout(std.mem.span(name));
    return if (ok) @intFromEnum(sys.KiStatus.Success) else @intFromEnum(sys.KiStatus.InvalidArgument);
}

/// input.layout_name(out_ptr, out_cap) — copy the active layout name into the
/// caller's buffer, truncating (with NUL termination) to the given capacity so
/// a longer future layout cannot overflow it (audit 2026-08-15).
fn layoutNameOp(out_ptr: u64, out_cap: u64) u64 {
    const checked = validate.checkPtrMut(out_ptr, u8) orelse return @intFromEnum(sys.KiStatus.InvalidArgument);
    if (out_cap == 0) return @intFromEnum(sys.KiStatus.InvalidArgument);
    const out: [*]u8 = @ptrCast(checked);
    const name = service.layoutName();
    const copy = @min(name.len, @as(usize, @intCast(out_cap)) - 1);
    @memcpy(out[0..copy], name[0..copy]);
    out[copy] = 0;
    return copy;
}

fn nextEvent(out_ptr: u64) u64 {
    const out = validate.checkPtrMut(out_ptr, Event) orelse return @intFromEnum(sys.KiStatus.InvalidArgument);
    return if (service.nextEvent(out)) 1 else 0;
}

fn peekEvent(out_ptr: u64) u64 {
    const out = validate.checkPtrMut(out_ptr, Event) orelse return @intFromEnum(sys.KiStatus.InvalidArgument);
    return if (service.peekEvent(out)) 1 else 0;
}

fn flush() u64 {
    service.flush();
    return @intFromEnum(sys.KiStatus.Success);
}

fn boolToU64(value: bool) u64 {
    return if (value) 1 else 0;
}
