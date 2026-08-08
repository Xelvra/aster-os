const std = @import("std");
const sys = @import("sys.zig");
const input_queue = @import("../input_queue.zig");
const input = @import("../input.zig");
const layout = @import("../input/layout.zig");

pub const Event = input_queue.Event;
pub const KeyCode = input.KeyCode;
pub const KeyEvent = input.KeyEvent;
pub const MouseEvent = input.MouseEvent;
pub const Layout = layout.Layout;
pub const eventName = input.eventName;

pub const InputOp = enum(u64) {
    next_event = 0,
    peek_event = 1,
    flush = 2,
    mouse_x = 3,
    mouse_y = 4,
    mouse_left = 5,
    mouse_right = 6,
    mouse_middle = 7,
};

pub fn dispatch(args: sys.SyscallArgs) u64 {
    const op: InputOp = @enumFromInt(args.a);
    return switch (op) {
        .next_event => nextEvent(args.b),
        .peek_event => peekEvent(args.b),
        .flush => flush(),
        .mouse_x => @intCast(input.mouse_state.x),
        .mouse_y => @intCast(input.mouse_state.y),
        .mouse_left => boolToU64(input.mouse_state.left),
        .mouse_right => boolToU64(input.mouse_state.right),
        .mouse_middle => boolToU64(input.mouse_state.middle),
    };
}

/// Pop the next keyboard/timer event into the caller's buffer. Mouse
/// packets are skipped here: the kernel cursor overlay consumes them in
/// poll(), and a busy mouse must not flood the Lua event stream.
fn nextEvent(out_ptr: u64) u64 {
    const out: *Event = @ptrFromInt(@as(usize, @intCast(out_ptr)));
    while (true) {
        const event = input_queue.global.pop() orelse return 0;
        switch (event) {
            .mouse => continue,
            else => {
                out.* = event;
                return 1;
            },
        }
    }
}

/// Like nextEvent but leaves the event in the queue. A mouse packet at the
/// head is reported as absent (never consumes; advisory only).
fn peekEvent(out_ptr: u64) u64 {
    const out: *Event = @ptrFromInt(@as(usize, @intCast(out_ptr)));
    const event = input_queue.global.peek() orelse return 0;
    switch (event) {
        .mouse => return 0,
        else => {
            out.* = event;
            return 1;
        },
    }
}

fn flush() u64 {
    while (input_queue.global.pop()) |_| {}
    return @intFromEnum(sys.KiStatus.Success);
}

fn boolToU64(value: bool) u64 {
    return if (value) 1 else 0;
}
