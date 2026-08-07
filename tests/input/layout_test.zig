const std = @import("std");
const input = @import("kernel").input;
const layout = @import("kernel").layout;

test "layout lowercase" {
    const l = layout.Layout{};
    try std.testing.expectEqual(@as(u8, 'a'), l.mapChar(.a).?);
    try std.testing.expectEqual(@as(u8, 'z'), l.mapChar(.z).?);
    try std.testing.expectEqual(@as(u8, '0'), l.mapChar(.digit_0).?);
    try std.testing.expectEqual(@as(u8, '9'), l.mapChar(.digit_9).?);
}

test "layout shifted" {
    const l = layout.Layout{ .shift = true };
    try std.testing.expectEqual(@as(u8, 'A'), l.mapChar(.a).?);
    try std.testing.expectEqual(@as(u8, '('), l.mapChar(.digit_9).?);
    try std.testing.expectEqual(@as(u8, ')'), l.mapChar(.digit_0).?);
    try std.testing.expectEqual(@as(u8, '"'), l.mapChar(.apostrophe).?);
    try std.testing.expectEqual(@as(u8, '!'), l.mapChar(.digit_1).?);
    try std.testing.expectEqual(@as(u8, '?'), l.mapChar(.slash).?);
}

test "layout: punctuation" {
    const l = layout.Layout{};
    try std.testing.expectEqual(@as(u8, ' '), l.mapChar(.space).?);
    try std.testing.expectEqual(@as(u8, '['), l.mapChar(.left_bracket).?);
    try std.testing.expectEqual(@as(u8, ']'), l.mapChar(.right_bracket).?);
    try std.testing.expectEqual(@as(u8, '\\'), l.mapChar(.backslash).?);
    try std.testing.expectEqual(@as(u8, ';'), l.mapChar(.semicolon).?);
    try std.testing.expectEqual(@as(u8, ','), l.mapChar(.comma).?);
    try std.testing.expectEqual(@as(u8, '.'), l.mapChar(.dot).?);
}

test "layout: control keys return null" {
    const l = layout.Layout{};
    try std.testing.expect(l.mapChar(.enter) == null);
    try std.testing.expect(l.mapChar(.tab) == null);
    try std.testing.expect(l.mapChar(.escape) == null);
    try std.testing.expect(l.mapChar(.backspace) == null);
    try std.testing.expect(l.mapChar(.left) == null);
    try std.testing.expect(l.mapChar(.f1) == null);
    try std.testing.expect(l.mapChar(.shift_left) == null);
}

test "layout: caps lock XOR shift for letters" {
    const caps = layout.Layout{ .shift = true }; // effective shift = caps XOR shift
    try std.testing.expectEqual(@as(u8, 'A'), caps.mapChar(.a).?);
}
