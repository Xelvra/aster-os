const std = @import("std");

// Home-wasm import surface (spec/adr/026): extern functions import from the
// "env" module, named after the symbol, with a stable signature. Text crosses
// the boundary as an offset into linear memory; a pointer in wasm IS the
// linear offset, so @intFromPtr is the marshalling.
extern fn draw_rect(x: i32, y: i32, w: u32, h: u32, color: u32) void;
extern fn draw_text(offset: u32, x: i32, y: i32, color: u32) void;
extern fn input_mouse_x() i32;
extern fn input_mouse_y() i32;
extern fn input_mouse_left() i32;
extern fn input_key() i32;

const surface_w: i32 = 224;
const surface_h: i32 = 160;

// Colors are hardcoded (theme import is a future, not Phase B).
const color_background: u32 = 0x101827;
const color_display_bg: u32 = 0x182545;
const color_display_text: u32 = 0xE8E8E8;
const color_button: u32 = 0x1E3050;
const color_button_text: u32 = 0xD0D0D0;
const color_operator: u32 = 0x24395F;
const color_equals: u32 = 0x82DCCC;
const color_equals_text: u32 = 0x101827;
const color_clear: u32 = 0x8A3B3B;

const max_digits: u8 = 15;

const display_w: i32 = 200;
const display_h: i32 = 24;
const display_x: i32 = 12;
const display_y: i32 = 8;

// 5 columns (spec/adr/026: fixed 224x160 surface) so the decimal point gets
// its own key, narrower than the original 4-column layout to still fit.
const grid_cols: u8 = 5;
const grid_rows: u8 = 4;
const col_w: i32 = 38;
const col_gap: i32 = 3;
const row_h: i32 = 24;
const row_gap: i32 = 6;
const grid_x: i32 = 12;
const grid_y: i32 = 44;

const glyph_w: i32 = 8;
const glyph_h: i32 = 16;

const State = struct {
    display: [24]u8 = undefined,
    entry: f64 = 0,
    acc: f64 = 0,
    op: u8 = 0,
    digit_count: u8 = 0,
    has_decimal: bool = false,
    decimal_scale: f64 = 0.1,
    fresh: bool = true,
    has_error: bool = false,
    prev_left: bool = false,
};

var bump_mem: [1024]u8 align(8) = undefined;
var bump_offset: usize = 0;

/// Tiny bump allocator over a static buffer: the phase-B pattern for state that
/// lives for the program's lifetime without a heap.
fn bumpAlloc(comptime T: type) *T {
    const aligned = (bump_offset + @alignOf(T) - 1) & ~(@as(usize, @alignOf(T)) - 1);
    bump_offset = aligned + @sizeOf(T);
    return @ptrCast(@alignCast(&bump_mem[aligned]));
}

var state: *State = undefined;

const Button = struct { row: u8, col: u8, label: u8 };

const button_layout = [_]Button{
    .{ .row = 0, .col = 0, .label = '7' },
    .{ .row = 0, .col = 1, .label = '8' },
    .{ .row = 0, .col = 2, .label = '9' },
    .{ .row = 0, .col = 3, .label = '+' },
    .{ .row = 1, .col = 0, .label = '4' },
    .{ .row = 1, .col = 1, .label = '5' },
    .{ .row = 1, .col = 2, .label = '6' },
    .{ .row = 1, .col = 3, .label = '-' },
    .{ .row = 2, .col = 0, .label = '1' },
    .{ .row = 2, .col = 1, .label = '2' },
    .{ .row = 2, .col = 2, .label = '3' },
    .{ .row = 2, .col = 3, .label = '*' },
    .{ .row = 3, .col = 0, .label = 'C' },
    .{ .row = 3, .col = 1, .label = '0' },
    .{ .row = 3, .col = 2, .label = '=' },
    .{ .row = 3, .col = 3, .label = '/' },
    .{ .row = 3, .col = 4, .label = '.' },
};

fn buttonRect(button: Button) struct { x: i32, y: i32, w: i32, h: i32 } {
    return .{
        .x = grid_x + @as(i32, button.col) * (col_w + col_gap),
        .y = grid_y + @as(i32, button.row) * (row_h + row_gap),
        .w = col_w,
        .h = row_h,
    };
}

fn buttonColor(label: u8) u32 {
    return switch (label) {
        'C' => color_clear,
        '=' => color_equals,
        '+', '-', '*', '/' => color_operator,
        else => color_button,
    };
}

fn buttonTextColor(label: u8) u32 {
    return if (label == '=') color_equals_text else color_button_text;
}

/// NUL-terminate and draw a string from linear memory at (x, y).
fn drawTextSlice(text: []const u8, x: i32, y: i32, color: u32) void {
    const offset: u32 = @intCast(@intFromPtr(text.ptr));
    draw_text(offset, x, y, color);
}

/// Format an i64 into decimal into `buf` (NUL-terminated), returning the length
/// excluding the NUL. The magnitude is computed in u64 so minInt cannot
/// overflow.
fn formatInt(buf: *[17]u8, value: i64) u8 {
    var end: usize = 16;
    const mag: u64 = if (value < 0)
        (0 -% @as(u64, @bitCast(value)))
    else
        @intCast(value);
    var n = mag;
    if (n == 0) {
        end -= 1;
        buf[end] = '0';
    } else {
        while (n != 0) : (n /= 10) {
            end -= 1;
            buf[end] = @intCast('0' + n % 10);
        }
    }
    if (value < 0) {
        end -= 1;
        buf[end] = '-';
    }
    buf[16] = 0;
    return @intCast(16 - end);
}

/// Format an f64 left-aligned into `buf` (e.g. "2.5", "-14"), returning the
/// length written. Truncates (not rounds) to at most 6 fractional digits and
/// drops the fractional part entirely when it is ~0 — a whole-number result
/// (the common case) reads as a plain integer, not "14.000000".
fn formatFloat(buf: []u8, value: f64) usize {
    const int_part: i64 = @intFromFloat(@trunc(value));
    var int_buf: [17]u8 = undefined;
    const int_len = formatInt(&int_buf, int_part);
    @memcpy(buf[0..int_len], int_buf[16 - int_len .. 16]);
    var n: usize = int_len;
    var frac = value - @trunc(value);
    if (frac < 0) frac = -frac;
    const epsilon = 1e-9;
    if (frac > epsilon) {
        buf[n] = '.';
        n += 1;
        var i: u8 = 0;
        while (i < 6 and frac > epsilon) : (i += 1) {
            frac *= 10;
            const d: u8 = @intFromFloat(@floor(frac));
            buf[n] = '0' + d;
            n += 1;
            frac -= @floor(frac);
        }
    }
    return n;
}

fn pressDigit(d: u8) void {
    if (state.has_error) pressClear();
    if (state.fresh) {
        state.entry = 0;
        state.digit_count = 0;
        state.has_decimal = false;
        state.decimal_scale = 0.1;
        state.fresh = false;
    }
    if (state.digit_count < max_digits) {
        if (state.has_decimal) {
            state.entry += @as(f64, @floatFromInt(d)) * state.decimal_scale;
            state.decimal_scale *= 0.1;
        } else {
            state.entry = state.entry * 10 + @as(f64, @floatFromInt(d));
        }
        state.digit_count += 1;
    }
}

/// The decimal point starts (or continues) the fractional part of the entry
/// being typed; a second press is a no-op (already past the point).
fn pressDecimal() void {
    if (state.has_error) pressClear();
    if (state.fresh) {
        state.entry = 0;
        state.digit_count = 0;
        state.fresh = false;
    }
    state.has_decimal = true;
    state.decimal_scale = 0.1;
}

fn pressClear() void {
    state.entry = 0;
    state.acc = 0;
    state.op = 0;
    state.fresh = true;
    state.has_error = false;
    state.digit_count = 0;
    state.has_decimal = false;
    state.decimal_scale = 0.1;
}

fn pressOperator(op: u8) void {
    if (state.op != 0) {
        evaluate();
    } else {
        state.acc = state.entry;
    }
    state.op = op;
    state.fresh = true;
}

fn pressEquals() void {
    if (state.op != 0) evaluate();
}

fn evaluate() void {
    switch (state.op) {
        '+' => state.acc = state.acc + state.entry,
        '-' => state.acc = state.acc - state.entry,
        '*' => state.acc = state.acc * state.entry,
        '/' => {
            if (state.entry == 0) {
                state.has_error = true;
                state.op = 0;
                state.fresh = true;
                state.entry = 0;
                return;
            }
            state.acc = state.acc / state.entry;
        },
        else => {},
    }
    state.op = 0;
    state.entry = state.acc;
    state.fresh = true;
    state.digit_count = 0;
    state.has_decimal = false;
    state.decimal_scale = 0.1;
}

fn press(label: u8) void {
    switch (label) {
        '0'...'9' => pressDigit(label - '0'),
        '.' => pressDecimal(),
        'C' => pressClear(),
        '=' => pressEquals(),
        else => pressOperator(label),
    }
}

fn hitButton(mx: i32, my: i32) ?u8 {
    for (button_layout) |button| {
        const rect = buttonRect(button);
        if (mx >= rect.x and mx < rect.x + rect.w and my >= rect.y and my < rect.y + rect.h) {
            return button.label;
        }
    }
    return null;
}

export fn start() void {
    state = bumpAlloc(State);
    state.* = .{};
}

/// Map a forwarded key character (input.lua: ev.char, or CR/BS/Esc for
/// Enter/Backspace/Escape) to the same button labels the mouse path presses.
/// Keys with no calculator meaning are ignored.
fn keyToLabel(key: u8) ?u8 {
    return switch (key) {
        '0'...'9', '+', '-', '*', '/', '=', '.' => key,
        13, 10 => '=', // Enter (main keyboard: CR) / numpad Enter (LF, layout.zig numpad_enter mapping)
        8, 27, 'c', 'C' => 'C', // Backspace, Escape, c/C
        else => null,
    };
}

export fn update() void {
    const mx = input_mouse_x();
    const my = input_mouse_y();
    const left = input_mouse_left() != 0;
    if (left and !state.prev_left) {
        if (hitButton(mx, my)) |label| press(label);
    }
    state.prev_left = left;

    const key: u8 = @intCast(input_key());
    if (keyToLabel(key)) |label| press(label);
}

export fn render() void {
    draw_rect(0, 0, @intCast(surface_w), @intCast(surface_h), color_background);
    draw_rect(display_x, display_y, display_w, display_h, color_display_bg);
    if (state.has_error) {
        drawTextSlice("error", display_x + 4, display_y + 4, color_display_text);
    } else {
        const len = formatFloat(&state.display, state.entry);
        const tx = display_x + display_w - @as(i32, @intCast(len)) * glyph_w;
        drawTextSlice(state.display[0..len], tx, display_y + @divTrunc(display_h - glyph_h, 2), color_display_text);
        // The pending operator on the left (a real calculator's "what am I
        // doing" indicator): visible from the moment an operator is pressed
        // until '=' resolves it, so the operand being entered has context.
        if (state.op != 0) {
            var op_glyph: [2]u8 = .{ state.op, 0 };
            const op_offset: u32 = @intCast(@intFromPtr(&op_glyph));
            draw_text(op_offset, display_x + 4, display_y + @divTrunc(display_h - glyph_h, 2), color_display_text);
        }
    }
    for (button_layout) |button| {
        const rect = buttonRect(button);
        draw_rect(rect.x, rect.y, @intCast(rect.w), @intCast(rect.h), buttonColor(button.label));
        var label: [2]u8 = .{ button.label, 0 };
        const label_offset: u32 = @intCast(@intFromPtr(&label));
        draw_text(label_offset, rect.x + @divTrunc(rect.w - glyph_w, 2), rect.y + @divTrunc(rect.h - glyph_h, 2), buttonTextColor(button.label));
    }
}
