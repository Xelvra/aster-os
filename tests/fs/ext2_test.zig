const std = @import("std");
const ext2 = @import("kernel").ext2;
const block = @import("kernel").block;
const MockDisk = @import("mock.zig").MockDisk;

const image_size = 64 * 1024;
const block_size = 1024;

fn writeU16(buf: []u8, off: usize, v: u16) void {
    buf[off] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
}

fn writeU32(buf: []u8, off: usize, v: u32) void {
    buf[off] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
    buf[off + 2] = @truncate(v >> 16);
    buf[off + 3] = @truncate(v >> 24);
}

const Entry = struct {
    ino: u32,
    file_type: u8,
    name: []const u8,
};

/// Minimal 1 KiB-block ext2 image: one block group, inode table on block 5
/// (8 inodes x 128 B), root dir data on block 6, a file on block 7, and a
/// subdirectory on block 8. Feature bits stay within the ADR-023 subset.
const Image = struct {
    data: [image_size]u8 = [_]u8{0} ** image_size,

    fn superblock(self: *Image, features: struct { compat: u32, incompat: u32, ro_compat: u32 }) void {
        const sb = self.data[1024 .. 1024 + 256];
        writeU32(sb, 0, 32); // inodes_count
        writeU32(sb, 4, 64); // blocks_count
        writeU32(sb, 20, 1); // first_data_block
        writeU32(sb, 24, 0); // log_block_size (1024 B)
        writeU32(sb, 32, 8); // blocks_per_group
        writeU32(sb, 40, 8); // inodes_per_group
        writeU32(sb, 84, 11); // first_ino
        writeU16(sb, 56, ext2.super_magic);
        writeU32(sb, 76, 0); // rev_level
        writeU16(sb, 88, 128); // inode_size
        writeU32(sb, 92, features.compat);
        writeU32(sb, 96, features.incompat);
        writeU32(sb, 100, features.ro_compat);
    }

    fn groupDescriptors(self: *Image) void {
        const gdt = self.data[2048 .. 2048 + 32];
        writeU32(gdt, 0, 3); // block_bitmap
        writeU32(gdt, 4, 4); // inode_bitmap
        writeU32(gdt, 8, 5); // inode_table
    }

    fn putInode(self: *Image, ino: u32, mode: u16, size: u32, block0: u32) void {
        const off = 5 * block_size + @as(usize, ino - 1) * 128;
        writeU16(&self.data, off, mode);
        writeU32(&self.data, off + 4, size);
        writeU32(&self.data, off + 40, block0); // i_block[0]
    }

    fn putDir(self: *Image, blk: u32, entries: []const Entry) void {
        const base = @as(usize, blk) * block_size;
        var off: usize = 0;
        for (entries, 0..) |e, i| {
            const is_last = i == entries.len - 1;
            const rec_len: usize = if (is_last)
                block_size - off
            else
                ((8 + e.name.len + 3) & ~@as(usize, 3));
            writeU32(&self.data, base + off, e.ino);
            writeU16(&self.data, base + off + 4, @intCast(rec_len));
            self.data[base + off + 6] = @intCast(e.name.len);
            self.data[base + off + 7] = e.file_type;
            @memcpy(self.data[base + off + 8 .. base + off + 8 + e.name.len], e.name);
            off += rec_len;
        }
    }

    /// A regular file (inode 5) spanning 13 blocks: 12 direct (40..51) plus
    /// one block (52) reached through a single-indirect table (block 60).
    fn putIndirectFile(self: *Image, size: u32) void {
        const off = 5 * block_size + 4 * 128;
        writeU16(&self.data, off, ext2.inode_type_reg);
        writeU32(&self.data, off + 4, size);
        for (0..12) |i| writeU32(&self.data, off + 40 + i * 4, 40 + @as(u32, @intCast(i)));
        writeU32(&self.data, off + 40 + 12 * 4, 60);
        for (0..12) |i| {
            const base = (40 + i) * block_size;
            for (0..block_size) |j| self.data[base + j] = 0x11;
        }
        const ind_base = 52 * block_size;
        for (0..block_size) |j| self.data[ind_base + j] = 0x22;
        writeU32(&self.data, 60 * block_size, 52);
    }
};

fn buildImage() Image {
    var img = Image{};
    img.superblock(.{ .compat = 0, .incompat = ext2.feature_incompat_filetype, .ro_compat = 0 });
    img.groupDescriptors();
    img.putInode(2, ext2.inode_type_dir, 64, 6); // root
    img.putInode(3, ext2.inode_type_reg, 5, 7); // hello.txt
    img.putInode(4, ext2.inode_type_dir, 64, 8); // sub
    img.putDir(6, &.{
        .{ .ino = 2, .file_type = 2, .name = "." },
        .{ .ino = 2, .file_type = 2, .name = ".." },
        .{ .ino = 3, .file_type = 1, .name = "hello.txt" },
        .{ .ino = 4, .file_type = 2, .name = "sub" },
    });
    @memcpy(img.data[7 * block_size .. 7 * block_size + 5], "hello");
    img.putDir(8, &.{
        .{ .ino = 4, .file_type = 2, .name = "." },
        .{ .ino = 4, .file_type = 2, .name = ".." },
        .{ .ino = 3, .file_type = 1, .name = "inner.txt" },
    });
    return img;
}

fn mount(mock: *MockDisk) block.PartitionView {
    return .{
        .disk = .{ .ctx = mock, .read_fn = MockDisk.read },
        .first_lba = 0,
        .last_lba = image_size / 512 - 1,
        .type_guid = undefined,
    };
}

test "init accepts a valid ext2 image" {
    const img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    try std.testing.expectEqual(@as(usize, 1024), fs.block_size);
    try std.testing.expectEqual(@as(u32, 32), fs.super.inodes_count);
    try std.testing.expectEqual(@as(u32, 64), fs.super.blocks_count);
    try std.testing.expectEqual(@as(u16, 128), fs.super.inode_size);
}

test "init rejects a wrong magic" {
    var img = buildImage();
    writeU16(&img.data, 1024 + 56, 0);
    var mock = MockDisk{ .data = &img.data };
    try std.testing.expectError(ext2.Ext2Error.BadMagic, ext2.Ext2.init(mount(&mock)));
}

test "init rejects dir_index (HTree) via feature_compat" {
    var img = buildImage();
    img.superblock(.{ .compat = ext2.feature_compat_dir_index, .incompat = 0, .ro_compat = 0 });
    var mock = MockDisk{ .data = &img.data };
    try std.testing.expectError(ext2.Ext2Error.UnsupportedFeatures, ext2.Ext2.init(mount(&mock)));
}

test "init rejects needs-recovery via feature_incompat" {
    var img = buildImage();
    img.superblock(.{ .compat = 0, .incompat = ext2.feature_incompat_recovery, .ro_compat = 0 });
    var mock = MockDisk{ .data = &img.data };
    try std.testing.expectError(ext2.Ext2Error.UnsupportedFeatures, ext2.Ext2.init(mount(&mock)));
}

test "init rejects an unknown feature_ro_compat bit" {
    var img = buildImage();
    img.superblock(.{ .compat = 0, .incompat = 0, .ro_compat = 0x4 });
    var mock = MockDisk{ .data = &img.data };
    try std.testing.expectError(ext2.Ext2Error.UnsupportedFeatures, ext2.Ext2.init(mount(&mock)));
}

test "init accepts sparse_super (ro_compat 0x1)" {
    var img = buildImage();
    img.superblock(.{ .compat = 0, .incompat = ext2.feature_incompat_filetype, .ro_compat = ext2.feature_ro_compat_sparse_super });
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    try std.testing.expectEqual(@as(usize, 1024), fs.block_size);
}

test "init accepts a typical mke2fs -t ext2 feature set" {
    var img = buildImage();
    img.superblock(.{
        .compat = ext2.feature_compat_ext_attr | ext2.feature_compat_resize_inode,
        .incompat = ext2.feature_incompat_filetype,
        .ro_compat = ext2.feature_ro_compat_sparse_super | ext2.feature_ro_compat_large_file,
    });
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    try std.testing.expectEqual(@as(usize, 1024), fs.block_size);
}

test "init rejects an inode size below 128 bytes" {
    var img = buildImage();
    writeU16(&img.data, 1024 + 88, 64);
    var mock = MockDisk{ .data = &img.data };
    try std.testing.expectError(ext2.Ext2Error.BadInodeSize, ext2.Ext2.init(mount(&mock)));
}

test "init rejects an unsupported block size" {
    var img = buildImage();
    writeU32(&img.data, 1024 + 24, 3); // 8 KiB blocks
    var mock = MockDisk{ .data = &img.data };
    try std.testing.expectError(ext2.Ext2Error.BadBlockSize, ext2.Ext2.init(mount(&mock)));
}

test "readInode resolves the root directory" {
    const img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    const inode = try fs.readInode(2);
    try std.testing.expectEqual(ext2.inode_type_dir, inode.mode & ext2.inode_type_dir);
    try std.testing.expectEqual(@as(u32, 6), inode.block[0]);
}

test "readInode rejects inode 0 and out-of-range inodes" {
    const img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    try std.testing.expectError(ext2.Ext2Error.NotFound, fs.readInode(0));
    try std.testing.expectError(ext2.Ext2Error.NotFound, fs.readInode(33));
}

test "readDir walks the root directory" {
    const img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    var out: [8]ext2.DirEntry = undefined;
    const count = try fs.readDir(2, &out);
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(@as(u32, 2), out[0].inode);
    try std.testing.expect(std.mem.eql(u8, ".", out[0].name[0..out[0].name_len]));
    try std.testing.expect(std.mem.eql(u8, "hello.txt", out[2].name[0..out[2].name_len]));
    try std.testing.expectEqual(@as(u32, 3), out[2].inode);
    try std.testing.expectEqual(@as(u8, 1), out[2].file_type);
    try std.testing.expect(std.mem.eql(u8, "sub", out[3].name[0..out[3].name_len]));
    try std.testing.expectEqual(@as(u32, 4), out[3].inode);
}

test "readDir walks a subdirectory" {
    const img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    var out: [8]ext2.DirEntry = undefined;
    const count = try fs.readDir(4, &out);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expect(std.mem.eql(u8, "inner.txt", out[2].name[0..out[2].name_len]));
}

test "readDir rejects a regular file inode" {
    const img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    var out: [8]ext2.DirEntry = undefined;
    try std.testing.expectError(ext2.Ext2Error.NotADirectory, fs.readDir(3, &out));
}

test "readDir reports a too-small output buffer" {
    const img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    var out: [1]ext2.DirEntry = undefined;
    try std.testing.expectError(ext2.Ext2Error.BufferTooSmall, fs.readDir(2, &out));
}

test "readFile reads a regular file" {
    const img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    var out: [64]u8 = undefined;
    const n = try fs.readFile(3, &out);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expect(std.mem.eql(u8, "hello", out[0..5]));
}

test "readFile reads through the single-indirect block" {
    var img = buildImage();
    img.putIndirectFile(13 * 1024);
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    var out: [14 * 1024]u8 = undefined;
    const n = try fs.readFile(5, &out);
    try std.testing.expectEqual(@as(usize, 13 * 1024), n);
    try std.testing.expectEqual(@as(u8, 0x11), out[0]);
    try std.testing.expectEqual(@as(u8, 0x22), out[12 * 1024]);
}

test "readFile rejects a directory inode" {
    const img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    var out: [64]u8 = undefined;
    try std.testing.expectError(ext2.Ext2Error.NotAFile, fs.readFile(2, &out));
}

test "find resolves absolute paths" {
    const img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    try std.testing.expectEqual(@as(u32, 3), try fs.find("/hello.txt"));
    try std.testing.expectEqual(@as(u32, 3), try fs.find("/sub/inner.txt"));
    try std.testing.expectError(ext2.Ext2Error.NotFound, fs.find("/nope"));
}
