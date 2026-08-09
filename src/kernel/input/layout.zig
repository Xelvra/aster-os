const std = @import("std");
const input = @import("input.zig");

/// Keyboard layout registry (ADR-024). A layout is a registered mapping table
/// `KeyCode × modifiers → char`; the active layout can be switched at runtime
/// through KI `input.set_layout`. This is the single place that knows the
/// layout — the kernel, KI bindings, and Lua shell all go through it.
pub const KeyCode = input.KeyCode;

pub const key_count = @typeInfo(KeyCode).@"enum".fields.len;

pub const KeyMapping = struct {
    plain: u8 = 0,
    shift: u8 = 0,
    altgr: u8 = 0,
};

pub const Layout = struct {
    name: []const u8,
    table: [key_count]KeyMapping,
};

pub const Modifiers = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    alt_gr: bool = false,
};

/// Active layout, a configuration state of the input subsystem (ADR-024);
/// changed only through KI `input.set_layout`.
pub var active_index: usize = 0;

fn mapping(key: KeyCode, plain: u8, shift: u8) KeyMapping {
    _ = key;
    return .{ .plain = plain, .shift = shift };
}

fn altMapping(key: KeyCode, plain: u8, shift: u8, altgr: u8) KeyMapping {
    _ = key;
    return .{ .plain = plain, .shift = shift, .altgr = altgr };
}

pub const us_layout = Layout{
    .name = "us",
    .table = blk: {
        var t = [_]KeyMapping{.{}} ** key_count;
        t[@intFromEnum(KeyCode.a)] = mapping(.a, 'a', 'A');
        t[@intFromEnum(KeyCode.b)] = mapping(.b, 'b', 'B');
        t[@intFromEnum(KeyCode.c)] = mapping(.c, 'c', 'C');
        t[@intFromEnum(KeyCode.d)] = mapping(.d, 'd', 'D');
        t[@intFromEnum(KeyCode.e)] = mapping(.e, 'e', 'E');
        t[@intFromEnum(KeyCode.f)] = mapping(.f, 'f', 'F');
        t[@intFromEnum(KeyCode.g)] = mapping(.g, 'g', 'G');
        t[@intFromEnum(KeyCode.h)] = mapping(.h, 'h', 'H');
        t[@intFromEnum(KeyCode.i)] = mapping(.i, 'i', 'I');
        t[@intFromEnum(KeyCode.j)] = mapping(.j, 'j', 'J');
        t[@intFromEnum(KeyCode.k)] = mapping(.k, 'k', 'K');
        t[@intFromEnum(KeyCode.l)] = mapping(.l, 'l', 'L');
        t[@intFromEnum(KeyCode.m)] = mapping(.m, 'm', 'M');
        t[@intFromEnum(KeyCode.n)] = mapping(.n, 'n', 'N');
        t[@intFromEnum(KeyCode.o)] = mapping(.o, 'o', 'O');
        t[@intFromEnum(KeyCode.p)] = mapping(.p, 'p', 'P');
        t[@intFromEnum(KeyCode.q)] = mapping(.q, 'q', 'Q');
        t[@intFromEnum(KeyCode.r)] = mapping(.r, 'r', 'R');
        t[@intFromEnum(KeyCode.s)] = mapping(.s, 's', 'S');
        t[@intFromEnum(KeyCode.t)] = mapping(.t, 't', 'T');
        t[@intFromEnum(KeyCode.u)] = mapping(.u, 'u', 'U');
        t[@intFromEnum(KeyCode.v)] = mapping(.v, 'v', 'V');
        t[@intFromEnum(KeyCode.w)] = mapping(.w, 'w', 'W');
        t[@intFromEnum(KeyCode.x)] = mapping(.x, 'x', 'X');
        t[@intFromEnum(KeyCode.y)] = mapping(.y, 'y', 'Y');
        t[@intFromEnum(KeyCode.z)] = mapping(.z, 'z', 'Z');

        t[@intFromEnum(KeyCode.digit_0)] = mapping(.digit_0, '0', ')');
        t[@intFromEnum(KeyCode.digit_1)] = mapping(.digit_1, '1', '!');
        t[@intFromEnum(KeyCode.digit_2)] = mapping(.digit_2, '2', '@');
        t[@intFromEnum(KeyCode.digit_3)] = mapping(.digit_3, '3', '#');
        t[@intFromEnum(KeyCode.digit_4)] = mapping(.digit_4, '4', '$');
        t[@intFromEnum(KeyCode.digit_5)] = mapping(.digit_5, '5', '%');
        t[@intFromEnum(KeyCode.digit_6)] = mapping(.digit_6, '6', '^');
        t[@intFromEnum(KeyCode.digit_7)] = mapping(.digit_7, '7', '&');
        t[@intFromEnum(KeyCode.digit_8)] = mapping(.digit_8, '8', '*');
        t[@intFromEnum(KeyCode.digit_9)] = mapping(.digit_9, '9', '(');

        t[@intFromEnum(KeyCode.space)] = mapping(.space, ' ', ' ');
        t[@intFromEnum(KeyCode.grave)] = mapping(.grave, '`', '~');
        t[@intFromEnum(KeyCode.minus)] = mapping(.minus, '-', '_');
        t[@intFromEnum(KeyCode.equal)] = mapping(.equal, '=', '+');
        t[@intFromEnum(KeyCode.left_bracket)] = mapping(.left_bracket, '[', '{');
        t[@intFromEnum(KeyCode.right_bracket)] = mapping(.right_bracket, ']', '}');
        t[@intFromEnum(KeyCode.backslash)] = mapping(.backslash, '\\', '|');
        t[@intFromEnum(KeyCode.semicolon)] = mapping(.semicolon, ';', ':');
        t[@intFromEnum(KeyCode.apostrophe)] = mapping(.apostrophe, '\'', '"');
        t[@intFromEnum(KeyCode.comma)] = mapping(.comma, ',', '<');
        t[@intFromEnum(KeyCode.dot)] = mapping(.dot, '.', '>');
        t[@intFromEnum(KeyCode.slash)] = mapping(.slash, '/', '?');

        t[@intFromEnum(KeyCode.numpad_0)] = mapping(.numpad_0, '0', '0');
        t[@intFromEnum(KeyCode.numpad_1)] = mapping(.numpad_1, '1', '1');
        t[@intFromEnum(KeyCode.numpad_2)] = mapping(.numpad_2, '2', '2');
        t[@intFromEnum(KeyCode.numpad_3)] = mapping(.numpad_3, '3', '3');
        t[@intFromEnum(KeyCode.numpad_4)] = mapping(.numpad_4, '4', '4');
        t[@intFromEnum(KeyCode.numpad_5)] = mapping(.numpad_5, '5', '5');
        t[@intFromEnum(KeyCode.numpad_6)] = mapping(.numpad_6, '6', '6');
        t[@intFromEnum(KeyCode.numpad_7)] = mapping(.numpad_7, '7', '7');
        t[@intFromEnum(KeyCode.numpad_8)] = mapping(.numpad_8, '8', '8');
        t[@intFromEnum(KeyCode.numpad_9)] = mapping(.numpad_9, '9', '9');
        t[@intFromEnum(KeyCode.numpad_add)] = mapping(.numpad_add, '+', '+');
        t[@intFromEnum(KeyCode.numpad_subtract)] = mapping(.numpad_subtract, '-', '-');
        t[@intFromEnum(KeyCode.numpad_multiply)] = mapping(.numpad_multiply, '*', '*');
        t[@intFromEnum(KeyCode.numpad_divide)] = mapping(.numpad_divide, '/', '/');
        t[@intFromEnum(KeyCode.numpad_decimal)] = mapping(.numpad_decimal, '.', '.');
        t[@intFromEnum(KeyCode.numpad_enter)] = mapping(.numpad_enter, '\n', '\n');
        break :blk t;
    },
};

/// Czech QWERTZ (ADR-024). Letters follow the Czech physical layout (y/z
/// swapped); digits and symbols are an ASCII fallback because the 8x16 bitmap
/// font cannot render the Czech diacritics (ě š č ř ž ý á í é) — wider font is
/// future work. AltGr carries the Czech alternate symbols.
pub const cz_layout = Layout{
    .name = "cz",
    .table = blk: {
        var t = us_layout.table;
        // Czech QWERTZ: the Y key produces 'z', the Z key produces 'y'.
        t[@intFromEnum(KeyCode.y)] = mapping(.y, 'z', 'Z');
        t[@intFromEnum(KeyCode.z)] = mapping(.z, 'y', 'Y');
        // Czech AltGr layer (ASCII subset).
        t[@intFromEnum(KeyCode.q)] = altMapping(.q, 'q', 'Q', '\\');
        t[@intFromEnum(KeyCode.w)] = altMapping(.w, 'w', 'W', '|');
        t[@intFromEnum(KeyCode.x)] = altMapping(.x, 'x', 'X', '#');
        t[@intFromEnum(KeyCode.c)] = altMapping(.c, 'c', 'C', '&');
        t[@intFromEnum(KeyCode.v)] = altMapping(.v, 'v', 'V', '@');
        t[@intFromEnum(KeyCode.z)] = altMapping(.z, 'y', 'Y', '%');
        t[@intFromEnum(KeyCode.b)] = altMapping(.b, 'b', 'B', '{');
        t[@intFromEnum(KeyCode.n)] = altMapping(.n, 'n', 'N', '}');
        t[@intFromEnum(KeyCode.m)] = altMapping(.m, 'm', 'M', '$');
        t[@intFromEnum(KeyCode.digit_1)] = altMapping(.digit_1, '1', '!', '~');
        break :blk t;
    },
};

pub const layouts = [_]Layout{ us_layout, cz_layout };

/// Map a key code to a printable character under the active layout, or null
/// when the key produces no character (control keys, modifiers, F-keys, ...).
pub fn mapChar(code: KeyCode, mod: Modifiers) ?u8 {
    if (mod.ctrl) return null;
    const mapping_entry = layouts[active_index].table[@intFromEnum(code)];
    if (mod.alt_gr) {
        if (mapping_entry.altgr != 0) return mapping_entry.altgr;
        if (mapping_entry.plain != 0) return mapping_entry.plain;
        return null;
    }
    if (mod.shift) {
        if (mapping_entry.shift != 0) return mapping_entry.shift;
        return null;
    }
    if (mapping_entry.plain != 0) return mapping_entry.plain;
    return null;
}

pub fn layoutName() []const u8 {
    return layouts[active_index].name;
}

/// Switch the active layout by name; returns false when unknown.
pub fn setLayout(name: []const u8) bool {
    for (layouts, 0..) |layout, i| {
        if (std.mem.eql(u8, layout.name, name)) {
            active_index = i;
            return true;
        }
    }
    return false;
}
