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
        .disk = .{ .ctx = mock, .read_fn = MockDisk.read, .write_fn = MockDisk.write },
        .first_lba = 0,
        .last_lba = image_size / 512 - 1,
        .type_guid = undefined,
    };
}

test "open reads a whole file" {
    var img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    var fs = try ext2.Ext2.init(mount(&mock));
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
    var img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    var fs = try ext2.Ext2.init(mount(&mock));
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
    var img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    var fs = try ext2.Ext2.init(mount(&mock));
    var f = try file.File.open(&fs, "/sub/inner.txt");
    defer f.close();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try f.read(&buf));
    try std.testing.expect(std.mem.eql(u8, "hello", buf[0..5]));
}

test "open rejects a directory and a missing file" {
    var img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    var fs = try ext2.Ext2.init(mount(&mock));
    try std.testing.expectError(ext2.Ext2Error.NotAFile, file.File.open(&fs, "/"));
    try std.testing.expectError(ext2.Ext2Error.NotFound, file.File.open(&fs, "/nope"));
}

test "write replaces a file's content in place (M7.1.4)" {
    const buildWriteImage = ext2_image.buildWriteImage;
    var img = buildWriteImage();
    var mock = MockDisk{ .data = &img.data };
    var fs = try ext2.Ext2.init(mount(&mock));
    {
        var f = try file.File.open(&fs, "/hello.txt");
        defer f.close();
        try f.truncate(0);
        try f.write("hey!");
        try std.testing.expectEqual(@as(u64, 4), f.fileSize());
    }
    var rf = try file.File.open(&fs, "/hello.txt");
    defer rf.close();
    var buf: [64]u8 = undefined;
    const n = try rf.read(&buf);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expect(std.mem.eql(u8, "hey!", buf[0..4]));
}

test "write grows a file beyond its first block (M7.1.4)" {
    const buildWriteImage = ext2_image.buildWriteImage;
    var img = buildWriteImage();
    var mock = MockDisk{ .data = &img.data };
    var fs = try ext2.Ext2.init(mount(&mock));
    {
        var f = try file.File.open(&fs, "/hello.txt");
        defer f.close();
        try f.truncate(0);
        var content = [_]u8{0xAB} ** 2000;
        try f.write(&content);
        try std.testing.expectEqual(@as(u64, 2000), f.fileSize());
    }
    var rf = try file.File.open(&fs, "/hello.txt");
    defer rf.close();
    var buf: [2000]u8 = undefined;
    const n = try rf.read(&buf);
    try std.testing.expectEqual(@as(usize, 2000), n);
    try std.testing.expectEqual(@as(u8, 0xAB), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), buf[1999]);
}

test "unlink removes a file: dir entry gone, inode and blocks freed (M7.1.9)" {
    var img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    var fs = try ext2.Ext2.init(mount(&mock));

    try std.testing.expectEqual(@as(u32, 3), try fs.find("/hello.txt"));

    try file.File.delete(&fs, "/hello.txt");

    // The file is gone from the path resolution.
    try std.testing.expectError(ext2.Ext2Error.NotFound, fs.find("/hello.txt"));

    // Its dir entry is gone and the file resolves to nothing; the freed data
    // block (7) is cleared in the block bitmap on disk (bit 6 of block 3).
    var entries: [16]ext2.DirEntry = undefined;
    const count = try fs.readDir(ext2.root_inode, &entries);
    var found = false;
    for (entries[0..count]) |e| {
        if (e.name_len == 9 and std.mem.eql(u8, e.name[0..9], "hello.txt")) found = true;
    }
    try std.testing.expect(!found);

    const bitmap_byte = img.data[3 * 1024 + 6 / 8];
    try std.testing.expect(bitmap_byte & (@as(u8, 1) << 6) == 0);
}
