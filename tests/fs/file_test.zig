const std = @import("std");
const ext2 = @import("kernel").ext2;
const block = @import("kernel").block;
const file = @import("kernel").file;
const MockDisk = @import("mock.zig").MockDisk;
const ext2_image = @import("ext2_image.zig");

const image_size = 64 * 1024;
const buildImage = ext2_image.buildImage;

fn mount(mock: *MockDisk) block.PartitionView {
    return .{
        .disk = .{ .ctx = mock, .read_fn = MockDisk.read },
        .first_lba = 0,
        .last_lba = image_size / 512 - 1,
        .type_guid = undefined,
    };
}

test "open reads a whole file" {
    const img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    var f = try file.File.open(&fs, "/hello.txt");
    defer f.close();
    var buf: [64]u8 = undefined;
    const n = try f.read(&buf);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expect(std.mem.eql(u8, "hello", buf[0..5]));
    try std.testing.expectEqual(@as(usize, 0), try f.read(&buf));
    try std.testing.expect(f.eof());
    try std.testing.expectEqual(@as(u64, 5), f.fileSize());
}

test "open reads in chunks across the offset" {
    const img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    var f = try file.File.open(&fs, "/hello.txt");
    defer f.close();
    var buf: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try f.read(&buf));
    try std.testing.expect(std.mem.eql(u8, "he", buf[0..2]));
    try std.testing.expectEqual(@as(usize, 2), try f.read(&buf));
    try std.testing.expect(std.mem.eql(u8, "ll", buf[0..2]));
    try std.testing.expectEqual(@as(usize, 1), try f.read(&buf));
    try std.testing.expect(std.mem.eql(u8, "o", buf[0..1]));
    try std.testing.expect(f.eof());
}

test "open resolves nested paths" {
    const img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    var f = try file.File.open(&fs, "/sub/inner.txt");
    defer f.close();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try f.read(&buf));
    try std.testing.expect(std.mem.eql(u8, "hello", buf[0..5]));
}

test "open rejects a directory and a missing file" {
    const img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    try std.testing.expectError(ext2.Ext2Error.NotAFile, file.File.open(&fs, "/"));
    try std.testing.expectError(ext2.Ext2Error.NotFound, file.File.open(&fs, "/nope"));
}
