const std = @import("std");
const input = @import("../input.zig");
const input_queue = @import("../input_queue.zig");

const ps2_data: u16 = 0x60;
const ps2_status: u16 = 0x64;
const ps2_command: u16 = 0x64;

const status_output_full: u8 = 0x01;

const set1_to_keycode: [0x60]?input.KeyCode = blk: {
    var table: [0x60]?input.KeyCode = [_]?input.KeyCode{null} ** 0x60;
    table[0x01] = .escape;
    table[0x02] = .digit_1;
    table[0x03] = .digit_2;
    table[0x04] = .digit_3;
    table[0x05] = .digit_4;
    table[0x06] = .digit_5;
    table[0x07] = .digit_6;
    table[0x08] = .digit_7;
    table[0x09] = .digit_8;
    table[0x0A] = .digit_9;
    table[0x0B] = .digit_0;
    table[0x0C] = .minus;
    table[0x0D] = .equal;
    table[0x0E] = .backspace;
    table[0x0F] = .tab;
    table[0x10] = .q;
    table[0x11] = .w;
    table[0x12] = .e;
    table[0x13] = .r;
    table[0x14] = .t;
    table[0x15] = .y;
    table[0x16] = .u;
    table[0x17] = .i;
    table[0x18] = .o;
    table[0x19] = .p;
    table[0x1A] = .left_bracket;
    table[0x1B] = .right_bracket;
    table[0x1C] = .enter;
    table[0x1D] = .ctrl_left;
    table[0x1E] = .a;
    table[0x1F] = .s;
    table[0x20] = .d;
    table[0x21] = .f;
    table[0x22] = .g;
    table[0x23] = .h;
    table[0x24] = .j;
    table[0x25] = .k;
    table[0x26] = .l;
    table[0x27] = .semicolon;
    table[0x28] = .apostrophe;
    table[0x29] = .grave;
    table[0x2A] = .shift_left;
    table[0x2B] = .backslash;
    table[0x2C] = .z;
    table[0x2D] = .x;
    table[0x2E] = .c;
    table[0x2F] = .v;
    table[0x30] = .b;
    table[0x31] = .n;
    table[0x32] = .m;
    table[0x33] = .comma;
    table[0x34] = .dot;
    table[0x35] = .slash;
    table[0x36] = .shift_right;
    table[0x37] = .numpad_multiply;
    table[0x38] = .alt_left;
    table[0x39] = .space;
    table[0x3A] = .caps_lock;
    table[0x3B] = .f1;
    table[0x3C] = .f2;
    table[0x3D] = .f3;
    table[0x3E] = .f4;
    table[0x3F] = .f5;
    table[0x40] = .f6;
    table[0x41] = .f7;
    table[0x42] = .f8;
    table[0x43] = .f9;
    table[0x44] = .f10;
    table[0x45] = .num_lock;
    table[0x46] = .scroll_lock;
    table[0x47] = .numpad_7;
    table[0x48] = .numpad_8;
    table[0x49] = .numpad_9;
    table[0x4A] = .numpad_subtract;
    table[0x4B] = .numpad_4;
    table[0x4C] = .numpad_5;
    table[0x4D] = .numpad_6;
    table[0x4E] = .numpad_add;
    table[0x4F] = .numpad_1;
    table[0x50] = .numpad_2;
    table[0x51] = .numpad_3;
    table[0x52] = .numpad_0;
    table[0x53] = .numpad_decimal;
    table[0x57] = .f11;
    table[0x58] = .f12;
    break :blk table;
};

var extended: bool = false;
var num_lock_on: bool = false;

pub fn init() void {
    out8(ps2_command, 0xAD);
    out8(ps2_command, 0x20);
    _ = in8(ps2_data);
    out8(ps2_command, 0x60);
    out8(ps2_data, 0x41);
    out8(ps2_command, 0xAE);
    out8(ps2_data, 0xF4);
}

pub fn handleIrq1() void {
    if (in8(ps2_status) & status_output_full != 0) {
        const scancode = in8(ps2_data);
        if (scancode == 0x00 or scancode == 0xFF or scancode == 0xFA) return;
        const event = mapScancode(scancode) orelse return;
        input_queue.global.push(.{ .key = event });
    }
}

/// Maps a set-1 scancode to a key event, handling the extended (0xE0)
/// prefix and the numpad keypad navigation split (numlock-dependent).
fn mapScancode(scancode: u8) ?input.KeyEvent {
    if (scancode == 0xE0) {
        extended = true;
        return null;
    }
    if (scancode == 0xE1) {
        extended = false;
        return null;
    }

    const released = scancode & 0x80 != 0;
    const code = scancode & 0x7F;

    const pressed = !released;

    const keycode: input.KeyCode = if (extended) extCode(code) orelse {
        extended = false;
        return null;
    } else if (code >= set1_to_keycode.len) return null else base: {
        extended = false;
        const base_code = set1_to_keycode[code] orelse return null;
        break :base base_code;
    };
    extended = false;

    if (keycode == .num_lock and pressed) {
        num_lock_on = !num_lock_on;
    }

    const mapped = keypadOrNav(keycode) orelse return null;
    return .{ .code = mapped, .pressed = pressed };
}

/// Extended (0xE0-prefixed) key codes: the navigation cluster, the right
/// Ctrl/Alt modifiers and the numpad Enter/Divide keys.
fn extCode(code: u8) ?input.KeyCode {
    return switch (code) {
        0x1C => .numpad_enter,
        0x1D => .ctrl_right,
        0x35 => .numpad_divide,
        0x38 => .alt_right,
        0x47 => .home,
        0x48 => .up,
        0x49 => .page_up,
        0x4B => .left,
        0x4D => .right,
        0x4F => .end,
        0x50 => .down,
        0x51 => .page_down,
        0x52 => .insert,
        0x53 => .delete,
        else => null,
    };
}

/// With numlock on, the keypad produces digits/operators; with numlock off
/// it duplicates the navigation cluster (the base map already holds the
/// digit codes, so only the nav keys need swapping back). The center key
/// (numpad_5) has no navigation twin and produces nothing.
fn keypadOrNav(code: input.KeyCode) ?input.KeyCode {
    if (num_lock_on) return code;
    return switch (code) {
        .numpad_7 => .home,
        .numpad_8 => .up,
        .numpad_9 => .page_up,
        .numpad_4 => .left,
        .numpad_5 => null,
        .numpad_6 => .right,
        .numpad_1 => .end,
        .numpad_2 => .down,
        .numpad_3 => .page_down,
        .numpad_0 => .insert,
        .numpad_decimal => .delete,
        else => code,
    };
}

fn out8(port: u16, value: u8) void {
    asm volatile (
        \\outb %[val], %[port]
        :
        : [val] "{al}" (value),
          [port] "{dx}" (port),
        : .{ .memory = true });
}

fn in8(port: u16) u8 {
    return asm volatile (
        \\inb %[port], %[val]
        : [val] "={al}" (-> u8),
        : [port] "{dx}" (port),
        : .{ .memory = true });
}
