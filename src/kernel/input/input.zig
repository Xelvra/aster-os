pub const KeyCode = enum(u8) {
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    digit_0,
    digit_1,
    digit_2,
    digit_3,
    digit_4,
    digit_5,
    digit_6,
    digit_7,
    digit_8,
    digit_9,
    enter,
    escape,
    space,
    tab,
    backspace,
    grave,
    minus,
    equal,
    left_bracket,
    right_bracket,
    backslash,
    semicolon,
    apostrophe,
    comma,
    dot,
    slash,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    insert,
    delete,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    shift_left,
    shift_right,
    ctrl_left,
    ctrl_right,
    alt_left,
    alt_right,
    super_left,
    super_right,
    caps_lock,
    num_lock,
    scroll_lock,
    print_screen,
    pause,
    menu,
    numpad_0,
    numpad_1,
    numpad_2,
    numpad_3,
    numpad_4,
    numpad_5,
    numpad_6,
    numpad_7,
    numpad_8,
    numpad_9,
    numpad_add,
    numpad_subtract,
    numpad_multiply,
    numpad_divide,
    numpad_decimal,
    numpad_enter,
};

pub const KeyEvent = struct {
    code: KeyCode,
    pressed: bool,
};

/// Mouse state representation: absolute cursor position in framebuffer
/// pixels and the pressed buttons. The single live instance is owned by
/// `input/service.zig` (the subsystem boundary); the event loop writes it
/// via `service.setMouseState`, the KI reads it via `service.mouseX`/...
pub const MouseState = struct {
    x: i32 = 0,
    y: i32 = 0,
    left: bool = false,
    right: bool = false,
    middle: bool = false,
};

/// PS/2 mouse event: relative movement since the last packet plus the
/// current button state.
pub const MouseEvent = struct {
    dx: i16,
    dy: i16,
    left: bool,
    right: bool,
    middle: bool,
};

pub fn eventName(event: KeyEvent) []const u8 {
    return @tagName(event.code);
}

/// Decode a standard 3-byte PS/2 mouse packet. Pure, host-testable:
/// no IRQ, no I/O. Returns null when the packet is not a valid start
/// (bit 3 of byte 0 is always set) or the delta overflowed (bits 6/7).
pub fn decodeMousePacket(packet: *const [3]u8) ?MouseEvent {
    const b0 = packet[0];
    if (b0 & 0x08 == 0) return null; // out of sync
    if (b0 & 0xC0 != 0) return null; // delta overflowed, values meaningless

    var dx: i16 = @as(i16, packet[1]);
    var dy: i16 = @as(i16, packet[2]);
    if (b0 & 0x10 != 0) dx -= 256;
    if (b0 & 0x20 != 0) dy -= 256;

    return .{
        .dx = dx,
        .dy = -dy, // PS/2 +dy = up, screen y grows downward
        .left = b0 & 0x01 != 0,
        .right = b0 & 0x02 != 0,
        .middle = b0 & 0x04 != 0,
    };
}
