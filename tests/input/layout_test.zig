const std = @import("std");
const layout = @import("kernel").layout;

/// Switch the active layout for a test and always restore US afterwards.
fn withLayout(comptime name: []const u8, f: anytype) !void {
    defer _ = layout.setLayout("us");
    if (!layout.setLayout(name)) @panic("unknown test layout");
    try f();
}

test "layout: lowercase" {
    try withLayout("us", struct {
        fn run() !void {
            try expectC(.a, 'a');
            try expectC(.z, 'z');
            try expectC(.digit_0, '0');
            try expectC(.digit_9, '9');
        }
    }.run);
}

test "layout: shifted" {
    try withLayout("us", struct {
        fn run() !void {
            try expectShifted(.a, 'A');
            try expectShifted(.digit_9, '(');
            try expectShifted(.digit_0, ')');
            try expectShifted(.apostrophe, '"');
            try expectShifted(.digit_1, '!');
            try expectShifted(.slash, '?');
        }
    }.run);
}

test "layout: punctuation" {
    try withLayout("us", struct {
        fn run() !void {
            try expectC(.space, ' ');
            try expectC(.left_bracket, '[');
            try expectC(.right_bracket, ']');
            try expectC(.backslash, '\\');
            try expectC(.semicolon, ';');
            try expectC(.comma, ',');
            try expectC(.dot, '.');
        }
    }.run);
}

test "layout: control keys return null" {
    try withLayout("us", struct {
        fn run() !void {
            try std.testing.expect(map(.enter) == null);
            try std.testing.expect(map(.tab) == null);
            try std.testing.expect(map(.escape) == null);
            try std.testing.expect(map(.backspace) == null);
            try std.testing.expect(map(.left) == null);
            try std.testing.expect(map(.f1) == null);
            try std.testing.expect(map(.shift_left) == null);
            try std.testing.expect(map(.super_left) == null);
            try std.testing.expect(map(.up) == null);
            try std.testing.expect(map(.delete) == null);
        }
    }.run);
}

test "layout: numpad digits" {
    try withLayout("us", struct {
        fn run() !void {
            try expectC(.numpad_7, '7');
            try expectC(.numpad_0, '0');
            try expectC(.numpad_add, '+');
            try expectC(.numpad_subtract, '-');
            try expectC(.numpad_multiply, '*');
            try expectC(.numpad_divide, '/');
            try expectC(.numpad_decimal, '.');
            try expectC(.numpad_enter, '\n');
        }
    }.run);
}

test "layout: alt does not affect printable characters" {
    try withLayout("us", struct {
        fn run() !void {
            try expectC(.a, 'a');
            try expectC(.digit_1, '1');
            try expectC(.space, ' ');
        }
    }.run);
}

test "layout: setLayout switches US <-> CZ at runtime" {
    try std.testing.expect(layout.setLayout("cz"));
    try std.testing.expectEqualStrings("cz", layout.layoutName());
    try std.testing.expectEqual(@as(u8, 'z'), map(.y).?); // Czech QWERTZ: Y key -> z
    try std.testing.expectEqual(@as(u8, 'y'), map(.z).?); // Z key -> y
    try std.testing.expectEqual(@as(u8, 'Z'), mapShifted(.y).?);
    try std.testing.expect(layout.setLayout("us"));
    try std.testing.expectEqualStrings("us", layout.layoutName());
    try std.testing.expectEqual(@as(u8, 'y'), map(.y).?);
    try std.testing.expect(!layout.setLayout("nope"));
}

test "layout: unknown layout is rejected" {
    try std.testing.expect(!layout.setLayout("de"));
    try std.testing.expectEqualStrings("us", layout.layoutName());
}

test "layout: CZ AltGr produces the Czech alternate symbols" {
    try withLayout("cz", struct {
        fn run() !void {
            try expectAltGr(.q, '\\');
            try expectAltGr(.w, '|');
            try expectAltGr(.x, '#');
            try expectAltGr(.c, '&');
            try expectAltGr(.v, '@');
            try expectAltGr(.z, '%');
            try expectAltGr(.b, '{');
            try expectAltGr(.n, '}');
            try expectAltGr(.m, '$');
            try expectAltGr(.digit_1, '~');
        }
    }.run);
}

test "layout: CZ AltGr falls back to plain for keys without an AltGr symbol" {
    try withLayout("cz", struct {
        fn run() !void {
            try expectAltGr(.a, 'a');
            try expectAltGr(.digit_2, '2');
            try expectAltGr(.space, ' ');
        }
    }.run);
}

test "layout: US AltGr falls back to the plain character" {
    try withLayout("us", struct {
        fn run() !void {
            try std.testing.expectEqual(@as(u8, 'q'), mapAltGr(.q).?);
            try std.testing.expectEqual(@as(u8, 'v'), mapAltGr(.v).?);
        }
    }.run);
}

fn map(code: layout.KeyCode) ?u8 {
    return layout.mapChar(code, .{});
}

fn mapShifted(code: layout.KeyCode) ?u8 {
    return layout.mapChar(code, .{ .shift = true });
}

fn mapAltGr(code: layout.KeyCode) ?u8 {
    return layout.mapChar(code, .{ .alt_gr = true });
}

fn expectC(code: layout.KeyCode, expected: u8) !void {
    try std.testing.expectEqual(expected, map(code).?);
}

fn expectShifted(code: layout.KeyCode, expected: u8) !void {
    try std.testing.expectEqual(expected, mapShifted(code).?);
}

fn expectAltGr(code: layout.KeyCode, expected: u8) !void {
    try std.testing.expectEqual(expected, mapAltGr(code).?);
}
