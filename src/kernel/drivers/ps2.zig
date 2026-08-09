const io = @import("../cpu/io.zig");
const input = @import("../input/input.zig");
const input_service = @import("../input/service.zig");

const ps2_data: u16 = 0x60;
const ps2_status: u16 = 0x64;
const ps2_command: u16 = 0x64;

const status_output_full: u8 = 0x01;
const status_input_full: u8 = 0x02;
const status_mouse_data: u8 = 0x20; // bit 5: data belongs to port 2 (mouse)

const ps2_ack: u8 = 0xFA;
const ps2_resend: u8 = 0xFE;
const ps2_test_passed: u8 = 0x00;

// ─── Keyboard state ─────────────────────────────────────────────────────

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

/// Initialize both PS/2 ports: keyboard (IRQ1, port 1) and mouse (IRQ12,
/// port 2), in that order. Each command waits for the controller and for
/// its ACK, so init never stalls or corrupts the shared config byte.
pub fn init() void {
    initKeyboard();
    initMouse();
}

/// Initialize the first PS/2 port (keyboard): enable IRQ1 and translation.
///
/// Every write to the controller waits for the input buffer to be empty
/// first (status_input_full == 0). The i8042 is slow to consume bytes;
/// firing commands back-to-back without this can silently drop or corrupt
/// them, leaving the config byte -- which is shared with the mouse port --
/// in a broken state that makes both devices behave erratically.
fn initKeyboard() void {
    sendCommand(0xAD); // disable port 1 while we reconfigure it

    // Read-modify-write the config byte instead of overwriting it with a
    // hardcoded constant, so we don't clobber bits the mouse driver (or
    // firmware) already set, regardless of init order.
    sendCommand(0x20); // read config
    const cfg = waitOutput() orelse return;
    sendCommand(0x60); // write config
    sendData((cfg | 0x01 | 0x40) & ~@as(u8, 0x10)); // IRQ1 on, translation on, port1 clock on

    sendCommand(0xAE); // enable port 1
    sendData(0xF4); // enable scanning
    _ = waitOutput(); // consume its ACK explicitly instead of leaving it to be drained elsewhere
}

// ─── Mouse state ───────────────────────────────────────────────────────

var mouse_packet: [3]u8 = undefined;
var mouse_byte_idx: u8 = 0;

/// Initialize the second PS/2 port (mouse) on IRQ12. Robust against a
/// missing device: the port is tested first and every command waits for
/// its ACK with a bounded timeout, so init can never stall the controller
/// (which would freeze the keyboard that shares the same data register).
fn initMouse() void {
    // Drain any stale bytes left in the output buffer (e.g. the keyboard's
    // ACK to 0xF4 from initKeyboard) so the port-2 test result below is not
    // confused with leftover data.
    while (io.in8(ps2_status) & status_output_full != 0) {
        _ = io.in8(ps2_data);
    }

    // Test whether a device is present on port 2 before touching it.
    sendCommand(0xA9); // test port 2
    var spins: u32 = 0;
    while (io.in8(ps2_status) & status_output_full == 0) : (spins += 1) {
        if (spins > 100000) return; // no response -> no mouse
    }
    const test_result = io.in8(ps2_data);
    if (test_result != ps2_test_passed) return; // port 2 has no working device

    // Enable port 2 and set its IRQ bit in the config byte. Keep the
    // keyboard (port 1) enabled and translation on.
    sendCommand(0xA8); // enable port 2 (no response byte)
    sendCommand(0x20); // read config
    const cfg = waitOutput() orelse return;
    sendCommand(0x60); // write config (no response byte)
    sendData((cfg | 0x02) & ~@as(u8, 0x20)); // IRQ12 on, port2 clock on

    // Tell the mouse to start reporting; wait for its ACK.
    _ = mouseCommand(0xF4);
}

// ─── Shared controller helpers ──────────────────────────────────────────

fn sendCommand(cmd: u8) void {
    var spins: u32 = 0;
    while (io.in8(ps2_status) & status_input_full != 0) : (spins += 1) {
        if (spins > 100000) return;
    }
    io.out8(ps2_command, cmd);
}

fn sendData(data: u8) void {
    var spins: u32 = 0;
    while (io.in8(ps2_status) & status_input_full != 0) : (spins += 1) {
        if (spins > 100000) return;
    }
    io.out8(ps2_data, data);
}

fn waitOutput() ?u8 {
    var spins: u32 = 0;
    while (io.in8(ps2_status) & status_output_full == 0) : (spins += 1) {
        if (spins > 100000) return null;
    }
    return io.in8(ps2_data);
}

fn mouseCommand(cmd: u8) ?u8 {
    // Write a command to the mouse: prefix with 0xD4 (write to port 2).
    sendCommand(0xD4);
    sendData(cmd);
    // Wait for the ACK byte.
    var spins: u32 = 0;
    while (spins < 100000) : (spins += 1) {
        if (io.in8(ps2_status) & status_output_full != 0) {
            const b = io.in8(ps2_data);
            if (b == ps2_resend) {
                return mouseCommand(cmd); // retry once
            }
            return b;
        }
    }
    return null;
}

// ─── IRQ handlers ──────────────────────────────────────────────────────

pub fn handleIrq1() void {
    const status = io.in8(ps2_status);
    // Only consume bytes that belong to the keyboard (port 1): bit 5 of the
    // status register marks data from the mouse. Without this check, IRQ1
    // steals mouse packet bytes as bogus scancodes, desynchronizing the
    // mouse and corrupting the keyboard stream.
    if (status & status_output_full != 0 and status & status_mouse_data == 0) {
        const scancode = io.in8(ps2_data);
        if (scancode == 0x00 or scancode == 0xFF or scancode == ps2_ack) return;
        const event = mapScancode(scancode) orelse return;
        input_service.pushKeyEvent(event);
    }
}

pub fn handleIrq12() void {
    const status = io.in8(ps2_status);
    // Only consume bytes that belong to the mouse port (bit 5). Keyboard
    // scancodes share the data register; without this check a keyboard byte
    // would desynchronize the packet stream.
    if (status & status_output_full != 0 and status & status_mouse_data != 0) {
        const byte = io.in8(ps2_data);
        // The first byte of a 3-byte packet always has bit 3 (0x08) set.
        // If we expect a packet start and this bit is clear, the stream is
        // out of sync (e.g. after a dropped packet): skip the byte and
        // realign on the next one. Without this, dx/dy get garbage values
        // and the cursor "shoots" across the screen.
        if (mouse_byte_idx == 0 and byte & 0x08 == 0) return;
        mouse_packet[mouse_byte_idx] = byte;
        mouse_byte_idx +%= 1;
        if (mouse_byte_idx >= 3) {
            mouse_byte_idx = 0;
            pushMousePacket();
        }
    }
}

// ─── Keyboard scancode mapping ─────────────────────────────────────────

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
        0x5B => .super_left,
        0x5C => .super_right,
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

// ─── Mouse packet decode ───────────────────────────────────────────────

/// Decode a standard 3-byte PS/2 mouse packet (relative movement, buttons).
fn pushMousePacket() void {
    const event = input.decodeMousePacket(&mouse_packet) orelse return;
    input_service.pushMouseEvent(event);
}
