const std = @import("std");
const input = @import("kernel").input;

test "letters map to lowercase by default" {
    try std.testing.expectEqual(@as(?u8, 'a'), input.keyToCodepoint(.a, false));
    try std.testing.expectEqual(@as(?u8, 'z'), input.keyToCodepoint(.z, false));
}

test "letters map to uppercase with shift" {
    try std.testing.expectEqual(@as(?u8, 'A'), input.keyToCodepoint(.a, true));
    try std.testing.expectEqual(@as(?u8, 'Z'), input.keyToCodepoint(.z, true));
}

test "digits map to digits by default" {
    try std.testing.expectEqual(@as(?u8, '0'), input.keyToCodepoint(.digit_0, false));
    try std.testing.expectEqual(@as(?u8, '9'), input.keyToCodepoint(.digit_9, false));
}

test "digits map to symbols with shift" {
    try std.testing.expectEqual(@as(?u8, '!'), input.keyToCodepoint(.digit_1, true));
    try std.testing.expectEqual(@as(?u8, '@'), input.keyToCodepoint(.digit_2, true));
    try std.testing.expectEqual(@as(?u8, ')'), input.keyToCodepoint(.digit_0, true));
}

test "space maps to space" {
    try std.testing.expectEqual(@as(?u8, ' '), input.keyToCodepoint(.space, false));
}

test "punctiation maps with shift" {
    try std.testing.expectEqual(@as(?u8, '-'), input.keyToCodepoint(.minus, false));
    try std.testing.expectEqual(@as(?u8, '_'), input.keyToCodepoint(.minus, true));
    try std.testing.expectEqual(@as(?u8, '?'), input.keyToCodepoint(.slash, true));
    try std.testing.expectEqual(@as(?u8, ':'), input.keyToCodepoint(.semicolon, true));
}

test "control keys map to null" {
    try std.testing.expectEqual(@as(?u8, null), input.keyToCodepoint(.enter, false));
    try std.testing.expectEqual(@as(?u8, null), input.keyToCodepoint(.escape, false));
    try std.testing.expectEqual(@as(?u8, null), input.keyToCodepoint(.backspace, false));
    try std.testing.expectEqual(@as(?u8, null), input.keyToCodepoint(.shift_left, false));
}
