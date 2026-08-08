const input = @import("../input.zig");

/// Keyboard layout: maps a `KeyCode` (plus shift/ctrl state) to a printable
/// character, or `null` for control keys. This is the single place that knows
/// the layout; the kernel, KI bindings, and Lua shell all use it. Adding a
/// different layout (e.g. a national one) is a new data table here, with no
/// logic changes downstream.
///
/// Layout: US QWERTY, 105+ keys. Covers letters, digits, punctuation,
/// whitespace; control keys (Enter, Tab, arrows, F-keys) return null.
pub const Layout = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    alt_gr: bool = false,

    /// Map a key code to a printable character (US layout), or null when the
    /// key produces no character (Enter, Tab, arrows, modifiers, F-keys, ...).
    pub fn mapChar(self: Layout, code: input.KeyCode) ?u8 {
        if (self.ctrl) return ctrlChar(code);
        if (self.alt_gr) return altGrChar(code);
        return switch (code) {
            .a => if (self.shift) 'A' else 'a',
            .b => if (self.shift) 'B' else 'b',
            .c => if (self.shift) 'C' else 'c',
            .d => if (self.shift) 'D' else 'd',
            .e => if (self.shift) 'E' else 'e',
            .f => if (self.shift) 'F' else 'f',
            .g => if (self.shift) 'G' else 'g',
            .h => if (self.shift) 'H' else 'h',
            .i => if (self.shift) 'I' else 'i',
            .j => if (self.shift) 'J' else 'j',
            .k => if (self.shift) 'K' else 'k',
            .l => if (self.shift) 'L' else 'l',
            .m => if (self.shift) 'M' else 'm',
            .n => if (self.shift) 'N' else 'n',
            .o => if (self.shift) 'O' else 'o',
            .p => if (self.shift) 'P' else 'p',
            .q => if (self.shift) 'Q' else 'q',
            .r => if (self.shift) 'R' else 'r',
            .s => if (self.shift) 'S' else 's',
            .t => if (self.shift) 'T' else 't',
            .u => if (self.shift) 'U' else 'u',
            .v => if (self.shift) 'V' else 'v',
            .w => if (self.shift) 'W' else 'w',
            .x => if (self.shift) 'X' else 'x',
            .y => if (self.shift) 'Y' else 'y',
            .z => if (self.shift) 'Z' else 'z',

            .digit_0 => if (self.shift) ')' else '0',
            .digit_1 => if (self.shift) '!' else '1',
            .digit_2 => if (self.shift) '@' else '2',
            .digit_3 => if (self.shift) '#' else '3',
            .digit_4 => if (self.shift) '$' else '4',
            .digit_5 => if (self.shift) '%' else '5',
            .digit_6 => if (self.shift) '^' else '6',
            .digit_7 => if (self.shift) '&' else '7',
            .digit_8 => if (self.shift) '*' else '8',
            .digit_9 => if (self.shift) '(' else '9',

            .space => ' ',
            .grave => if (self.shift) '~' else '`',
            .minus => if (self.shift) '_' else '-',
            .equal => if (self.shift) '+' else '=',
            .left_bracket => if (self.shift) '{' else '[',
            .right_bracket => if (self.shift) '}' else ']',
            .backslash => if (self.shift) '|' else '\\',
            .semicolon => if (self.shift) ':' else ';',
            .apostrophe => if (self.shift) '"' else '\'',
            .comma => if (self.shift) '<' else ',',
            .dot => if (self.shift) '>' else '.',
            .slash => if (self.shift) '?' else '/',

            .numpad_0 => '0',
            .numpad_1 => '1',
            .numpad_2 => '2',
            .numpad_3 => '3',
            .numpad_4 => '4',
            .numpad_5 => '5',
            .numpad_6 => '6',
            .numpad_7 => '7',
            .numpad_8 => '8',
            .numpad_9 => '9',
            .numpad_add => '+',
            .numpad_subtract => '-',
            .numpad_multiply => '*',
            .numpad_divide => '/',
            .numpad_decimal => '.',
            .numpad_enter => '\n',

            .enter,
            .escape,
            .tab,
            .backspace,
            .left,
            .right,
            .up,
            .down,
            .home,
            .end,
            .page_up,
            .page_down,
            .insert,
            .delete,
            .f1,
            .f2,
            .f3,
            .f4,
            .f5,
            .f6,
            .f7,
            .f8,
            .f9,
            .f10,
            .f11,
            .f12,
            .shift_left,
            .shift_right,
            .ctrl_left,
            .ctrl_right,
            .alt_left,
            .alt_right,
            .super_left,
            .super_right,
            .caps_lock,
            .num_lock,
            .scroll_lock,
            .print_screen,
            .pause,
            .menu,
            => null,
        };
    }

    /// Characters produced with Ctrl held. Reserved for future shell
    /// shortcuts (e.g. Ctrl+C); today no printable character is produced.
    fn ctrlChar(code: input.KeyCode) ?u8 {
        _ = code;
        return null;
    }

    /// Czech AltGr (right Alt) layer: alternative characters on ASCII keys
    /// that the bitmap font can render. Keys without an AltGr symbol return
    /// their plain character.
    fn altGrChar(code: input.KeyCode) ?u8 {
        return switch (code) {
            .q => '\\',
            .w => '|',
            .x => '#',
            .c => '&',
            .v => '@',
            .z => '%',
            .b => '{',
            .n => '}',
            .m => '$',
            .digit_1 => '~',
            else => mapPlain(code),
        };
    }

    /// The plain (unshifted) character for a key, used by the AltGr layer
    /// when a key has no AltGr symbol of its own.
    fn mapPlain(code: input.KeyCode) ?u8 {
        return switch (code) {
            .a => 'a',
            .b => 'b',
            .c => 'c',
            .d => 'd',
            .e => 'e',
            .f => 'f',
            .g => 'g',
            .h => 'h',
            .i => 'i',
            .j => 'j',
            .k => 'k',
            .l => 'l',
            .m => 'm',
            .n => 'n',
            .o => 'o',
            .p => 'p',
            .q => 'q',
            .r => 'r',
            .s => 's',
            .t => 't',
            .u => 'u',
            .v => 'v',
            .w => 'w',
            .x => 'x',
            .y => 'y',
            .z => 'z',
            .digit_0 => '0',
            .digit_1 => '1',
            .digit_2 => '2',
            .digit_3 => '3',
            .digit_4 => '4',
            .digit_5 => '5',
            .digit_6 => '6',
            .digit_7 => '7',
            .digit_8 => '8',
            .digit_9 => '9',
            .space => ' ',
            .minus => '-',
            .equal => '=',
            .left_bracket => '[',
            .right_bracket => ']',
            .backslash => '\\',
            .semicolon => ';',
            .apostrophe => '\'',
            .comma => ',',
            .dot => '.',
            .slash => '/',
            .grave => '`',
            else => null,
        };
    }
};
