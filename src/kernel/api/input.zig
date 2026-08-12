const std = @import("std");
const sys = @import("sys.zig");
const service = @import("../input/service.zig");

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
};

pub fn dispatch(args: sys.SyscallArgs) u64 {
    const op: InputOp = @enumFromInt(args.a);
    return switch (op) {
        .next_event => nextEvent(args.b),
        .peek_event => peekEvent(args.b),
        .flush => flush(),
        .mouse_x => @intCast(service.mouseX()),
        .mouse_y => @intCast(service.mouseY()),
        .mouse_left => boolToU64(service.mouseLeft()),
        .mouse_right => boolToU64(service.mouseRight()),
        .mouse_middle => boolToU64(service.mouseMiddle()),
        .set_layout => setLayoutOp(args.b),
        .layout_name => layoutNameOp(args.b),
    };
}

/// input.set_layout(name_ptr) — switch the active keyboard layout (ADR-024).
fn setLayoutOp(name_ptr: u64) u64 {
    const name: [*:0]const u8 = @ptrFromInt(@as(usize, @intCast(name_ptr)));
    const ok = service.setLayout(std.mem.span(name));
    return if (ok) @intFromEnum(sys.KiStatus.Success) else @intFromEnum(sys.KiStatus.InvalidArgument);
}

/// input.layout_name(out_ptr) — copy the active layout name into the buffer.
fn layoutNameOp(out_ptr: u64) u64 {
    const out: [*]u8 = @ptrFromInt(@as(usize, @intCast(out_ptr)));
    const name = service.layoutName();
    @memcpy(out[0..name.len], name);
    out[name.len] = 0;
    return name.len;
}

fn nextEvent(out_ptr: u64) u64 {
    const out: *Event = @ptrFromInt(@as(usize, @intCast(out_ptr)));
    return if (service.nextEvent(out)) 1 else 0;
}

fn peekEvent(out_ptr: u64) u64 {
    const out: *Event = @ptrFromInt(@as(usize, @intCast(out_ptr)));
    return if (service.peekEvent(out)) 1 else 0;
}

fn flush() u64 {
    service.flush();
    return @intFromEnum(sys.KiStatus.Success);
}

fn boolToU64(value: bool) u64 {
    return if (value) 1 else 0;
}
