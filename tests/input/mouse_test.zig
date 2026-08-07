const std = @import("std");
const input = @import("kernel").input;

test "mouse: simple rightward movement" {
    // b0=0x08 (start), dx=3, dy=0 -> no buttons
    const packet = [3]u8{ 0x08, 3, 0 };
    const m = input.decodeMousePacket(&packet).?;
    try std.testing.expectEqual(@as(i16, 3), m.dx);
    try std.testing.expectEqual(@as(i16, 0), m.dy);
    try std.testing.expect(!m.left and !m.right and !m.middle);
}

test "mouse: dy is inverted (PS/2 up = screen down)" {
    // b0=0x08, dx=0, dy=5 -> PS/2 +5 is up, screen y should be -5
    const packet = [3]u8{ 0x08, 0, 5 };
    const m = input.decodeMousePacket(&packet).?;
    try std.testing.expectEqual(@as(i16, 0), m.dx);
    try std.testing.expectEqual(@as(i16, -5), m.dy);
}

test "mouse: buttons decoded from byte 0" {
    // b0=0x09 = start + left
    const left = input.decodeMousePacket(&[3]u8{ 0x09, 0, 0 }).?;
    try std.testing.expect(left.left);
    try std.testing.expect(!left.right and !left.middle);
    // b0=0x0A = start + right
    const right = input.decodeMousePacket(&[3]u8{ 0x0A, 0, 0 }).?;
    try std.testing.expect(right.right);
    // b0=0x0C = start + middle
    const middle = input.decodeMousePacket(&[3]u8{ 0x0C, 0, 0 }).?;
    try std.testing.expect(middle.middle);
}

test "mouse: negative delta sign extension" {
    // b0 bit 4 set + dx 0xFF = -1; bit 5 set + dy 0xFF = -1 (inverted to +1)
    const p = input.decodeMousePacket(&[3]u8{ 0x38, 0xFF, 0xFF }).?;
    try std.testing.expectEqual(@as(i16, -1), p.dx);
    try std.testing.expectEqual(@as(i16, 1), p.dy);
}

test "mouse: out-of-sync packet rejected" {
    try std.testing.expect(input.decodeMousePacket(&[3]u8{ 0x00, 0, 0 }) == null);
    try std.testing.expect(input.decodeMousePacket(&[3]u8{ 0x01, 0, 0 }) == null);
}

test "mouse: overflowed delta rejected" {
    // Bits 6/7 of byte 0 mean the delta overflowed -> meaningless.
    try std.testing.expect(input.decodeMousePacket(&[3]u8{ 0x48, 0xFF, 0x00 }) == null);
    try std.testing.expect(input.decodeMousePacket(&[3]u8{ 0x88, 0x00, 0xFF }) == null);
}
