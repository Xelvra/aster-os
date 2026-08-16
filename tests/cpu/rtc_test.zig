const std = @import("std");
const rtc = @import("kernel").rtc;

test "rtc: BCD byte converts to a plain number" {
    try std.testing.expectEqual(@as(u8, 0), rtc.fromBcd(0x00));
    try std.testing.expectEqual(@as(u8, 42), rtc.fromBcd(0x42));
    try std.testing.expectEqual(@as(u8, 59), rtc.fromBcd(0x59));
    try std.testing.expectEqual(@as(u8, 23), rtc.fromBcd(0x23));
    try std.testing.expectEqual(@as(u8, 7), rtc.fromBcd(0x07));
}
