const std = @import("std");
const ext2 = @import("kernel").ext2;

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

    fn putDir(self: *Image, block: u32, entries: []const Entry) void {
        const base = @as(usize, block) * block_size;
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
};

fn buildImage() Image {
    var img = Image{};
    img.superblock(.{ .compat = ext2.feature_compat_filetype, .incompat = 0, .ro_compat = 0 });
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

test "init accepts a valid ext2 image" {
    const img = buildImage();
    const fs = try ext2.Ext2.init(&img.data);
    try std.testing.expectEqual(@as(usize, 1024), fs.block_size);
    try std.testing.expectEqual(@as(u32, 32), fs.super.inodes_count);
    try std.testing.expectEqual(@as(u32, 64), fs.super.blocks_count);
    try std.testing.expectEqual(@as(u16, 128), fs.super.inode_size);
}

test "init rejects a wrong magic" {
    var img = buildImage();
    writeU16(&img.data, 1024 + 56, 0);
    try std.testing.expectError(ext2.Ext2Error.BadMagic, ext2.Ext2.init(&img.data));
}

test "init rejects dir_index (HTree) via feature_compat" {
    var img = buildImage();
    img.superblock(.{ .compat = ext2.feature_compat_dir_index, .incompat = 0, .ro_compat = 0 });
    try std.testing.expectError(ext2.Ext2Error.UnsupportedFeatures, ext2.Ext2.init(&img.data));
}

test "init rejects needs-recovery via feature_incompat" {
    var img = buildImage();
    img.superblock(.{ .compat = 0, .incompat = ext2.feature_incompat_recovery, .ro_compat = 0 });
    try std.testing.expectError(ext2.Ext2Error.UnsupportedFeatures, ext2.Ext2.init(&img.data));
}

test "init rejects an unknown feature_ro_compat bit" {
    var img = buildImage();
    img.superblock(.{ .compat = 0, .incompat = 0, .ro_compat = 0x2 });
    try std.testing.expectError(ext2.Ext2Error.UnsupportedFeatures, ext2.Ext2.init(&img.data));
}

test "init accepts sparse_super (ro_compat 0x1)" {
    var img = buildImage();
    img.superblock(.{ .compat = ext2.feature_compat_filetype, .incompat = 0, .ro_compat = ext2.feature_ro_compat_sparse_super });
    const fs = try ext2.Ext2.init(&img.data);
    try std.testing.expectEqual(@as(usize, 1024), fs.block_size);
}

test "init rejects an inode size below 128 bytes" {
    var img = buildImage();
    writeU16(&img.data, 1024 + 88, 64);
    try std.testing.expectError(ext2.Ext2Error.BadInodeSize, ext2.Ext2.init(&img.data));
}

test "init rejects an unsupported block size" {
    var img = buildImage();
    writeU32(&img.data, 1024 + 24, 3); // 8 KiB blocks
    try std.testing.expectError(ext2.Ext2Error.BadBlockSize, ext2.Ext2.init(&img.data));
}

test "readInode resolves the root directory" {
    const img = buildImage();
    const fs = try ext2.Ext2.init(&img.data);
    const inode = try fs.readInode(2);
    try std.testing.expectEqual(ext2.inode_type_dir, inode.mode & ext2.inode_type_dir);
    try std.testing.expectEqual(@as(u32, 6), inode.block[0]);
}

test "readInode rejects inode 0 and out-of-range inodes" {
    const img = buildImage();
    const fs = try ext2.Ext2.init(&img.data);
    try std.testing.expectError(ext2.Ext2Error.NotFound, fs.readInode(0));
    try std.testing.expectError(ext2.Ext2Error.NotFound, fs.readInode(33));
}

test "readDir walks the root directory" {
    const img = buildImage();
    const fs = try ext2.Ext2.init(&img.data);
    var out: [8]ext2.DirEntry = undefined;
    const count = try fs.readDir(2, &out);
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(@as(u32, 2), out[0].inode);
    try std.testing.expect(std.mem.eql(u8, ".", out[0].name));
    try std.testing.expect(std.mem.eql(u8, "hello.txt", out[2].name));
    try std.testing.expectEqual(@as(u32, 3), out[2].inode);
    try std.testing.expectEqual(@as(u8, 1), out[2].file_type);
    try std.testing.expect(std.mem.eql(u8, "sub", out[3].name));
    try std.testing.expectEqual(@as(u32, 4), out[3].inode);
}

test "readDir walks a subdirectory" {
    const img = buildImage();
    const fs = try ext2.Ext2.init(&img.data);
    var out: [8]ext2.DirEntry = undefined;
    const count = try fs.readDir(4, &out);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expect(std.mem.eql(u8, "inner.txt", out[2].name));
}

test "readDir rejects a regular file inode" {
    const img = buildImage();
    const fs = try ext2.Ext2.init(&img.data);
    var out: [8]ext2.DirEntry = undefined;
    try std.testing.expectError(ext2.Ext2Error.NotADirectory, fs.readDir(3, &out));
}

test "readDir reports a too-small output buffer" {
    const img = buildImage();
    const fs = try ext2.Ext2.init(&img.data);
    var out: [1]ext2.DirEntry = undefined;
    try std.testing.expectError(ext2.Ext2Error.BufferTooSmall, fs.readDir(2, &out));
}
