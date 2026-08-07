const std = @import("std");
const font = @import("kernel").font;

test "glyph returns 16 rows for printable ascii" {
    for (0x20..0x7F) |c| {
        const g = font.glyph(@intCast(c));
        try std.testing.expectEqual(@as(usize, 16), g.len);
    }
}

test "glyph falls back for out-of-range codepoint" {
    const fallback = font.glyph(0x3F);
    const missing = font.glyph(0x100);
    try std.testing.expectEqualSlices(u8, &fallback, &missing);
}

test "glyph ' ' is blank" {
    const space = font.glyph(' ');
    for (space) |row| {
        try std.testing.expectEqual(@as(u8, 0), row);
    }
}

test "glyph 'A' has ink" {
    const a = font.glyph('A');
    var has_ink = false;
    for (a) |row| {
        if (row != 0) has_ink = true;
    }
    try std.testing.expect(has_ink);
}
