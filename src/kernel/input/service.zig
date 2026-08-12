const std = @import("std");
const input = @import("input.zig");
const queue = @import("queue.zig");
const layout = @import("layout.zig");

/// Input subsystem boundary (middle layer). The event queues, mouse state
/// and layout registry live behind this module; kernel orchestration
/// (main event loop), the KI (`api/input`) and IRQ producers (PS/2, APIC
/// timer) all reach the subsystem through it. The subsystem knows nothing
/// about graphics — mouse events are handed to the event loop, which
/// applies them to the cursor overlay (spec/input.md, kernel-interface.md
/// §4.7).
pub const Event = queue.Event;
pub const KeyCode = input.KeyCode;
pub const KeyEvent = input.KeyEvent;
pub const MouseEvent = input.MouseEvent;
pub const MouseState = input.MouseState;
pub const Layout = layout.Layout;
pub const Modifiers = layout.Modifiers;
pub const eventName = input.eventName;
pub const decodeMousePacket = input.decodeMousePacket;

var mouse_state: input.MouseState = .{};

// ─── keyboard modifier state ─────────────────────────────────────────
//
// Tracked here beside mouse_state: the key event producer and the KI
// bindings update it, the layout module reads it as a plain Modifiers
// value. caps_lock and super have no place in Modifiers (which feeds
// mapChar), so they live as their own flags next to it.

var modifiers: layout.Modifiers = .{};
var caps_lock_on: bool = false;
var super_pressed: bool = false;

// ─── producers (IRQ / driver context) ─────────────────────────────────

pub fn pushKeyEvent(event: input.KeyEvent) void {
    queue.global.push(.{ .key = event });
}

pub fn pushMouseEvent(event: input.MouseEvent) void {
    queue.mouse.push(.{ .mouse = event });
}

pub fn pushTimerTick(tick: u64) void {
    queue.global.push(.{ .timer_tick = tick });
}

// ─── kernel / event-loop-facing ───────────────────────────────────────

/// Peek the shared keyboard/timer queue (any event kind). The event loop
/// decides what to consume; it never leaves a mouse packet here.
pub fn peekKernelEvent() ?Event {
    return queue.global.peek();
}

pub fn popKernelEvent() ?Event {
    return queue.global.pop();
}

pub fn peekMouseEvent() ?Event {
    return queue.mouse.peek();
}

pub fn popMouseEvent() ?Event {
    return queue.mouse.pop();
}

/// Replace the whole mouse state. The event loop computes the cursor
/// position and applies the packet's buttons; the service only stores it.
pub fn setMouseState(ms: input.MouseState) void {
    mouse_state = ms;
}

pub fn mouseState() input.MouseState {
    return mouse_state;
}

// ─── KI-facing ────────────────────────────────────────────────────────

/// Pop the next keyboard/timer event into the caller's buffer. Mouse
/// packets are skipped: the kernel cursor overlay consumes them in the
/// event loop, and a busy mouse must not flood the Lua event stream.
pub fn nextEvent(out: *Event) bool {
    while (queue.global.pop()) |event| {
        switch (event) {
            .mouse => continue,
            else => {
                out.* = event;
                return true;
            },
        }
    }
    return false;
}

/// Like nextEvent but leaves the event in the queue. A mouse packet at the
/// head is reported as absent (never consumes; advisory only).
pub fn peekEvent(out: *Event) bool {
    const event = queue.global.peek() orelse return false;
    switch (event) {
        .mouse => return false,
        else => {
            out.* = event;
            return true;
        },
    }
}

pub fn flush() void {
    while (queue.global.pop()) |_| {}
}

pub fn mouseX() i32 {
    return mouse_state.x;
}

pub fn mouseY() i32 {
    return mouse_state.y;
}

pub fn mouseLeft() bool {
    return mouse_state.left;
}

pub fn mouseRight() bool {
    return mouse_state.right;
}

pub fn mouseMiddle() bool {
    return mouse_state.middle;
}

/// Update the keyboard modifier that a key code maps to. Modifiers are
/// separate KeyCodes (left/right); caps lock toggles through setCapsLock.
pub fn setModifier(code: input.KeyCode, pressed: bool) void {
    switch (code) {
        .shift_left, .shift_right => modifiers.shift = pressed,
        .ctrl_left, .ctrl_right => modifiers.ctrl = pressed,
        .alt_left => modifiers.alt = pressed,
        .alt_right => modifiers.alt_gr = pressed,
        .super_left, .super_right => super_pressed = pressed,
        else => {},
    }
}

/// Caps lock toggles on a key-down edge.
pub fn setCapsLock(pressed: bool) void {
    if (pressed) caps_lock_on = !caps_lock_on;
}

pub fn modifierState() layout.Modifiers {
    return modifiers;
}

pub fn capsLockOn() bool {
    return caps_lock_on;
}

pub fn superPressed() bool {
    return super_pressed;
}

/// Effective shift for letters: shift XOR caps lock (letters are
/// uppercase when exactly one of the two is active).
pub fn effectiveShift() bool {
    return modifiers.shift != caps_lock_on;
}

pub fn setLayout(name: []const u8) bool {
    return layout.setLayout(name);
}

pub fn layoutName() []const u8 {
    return layout.layoutName();
}

pub fn mapChar(code: input.KeyCode, mod: layout.Modifiers) ?u8 {
    return layout.mapChar(code, mod);
}
