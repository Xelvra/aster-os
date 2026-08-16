const std = @import("std");
const ext2 = @import("kernel").ext2;
const block = @import("kernel").block;
const MockDisk = @import("mock.zig").MockDisk;
const ext2_image = @import("ext2_image.zig");

const image_size = 64 * 1024;
const buildImage = ext2_image.buildImage;
const buildWriteImage = ext2_image.buildWriteImage;

fn mount(mock: *MockDisk) block.PartitionView {
    return .{
        .disk = .{ .ctx = mock, .read_fn = MockDisk.read, .write_fn = MockDisk.write },
        .first_lba = 0,
        .last_lba = image_size / 512 - 1,
        .type_guid = undefined,
    };
}

test "init accepts a valid ext2 image" {
    var img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    try std.testing.expectEqual(@as(usize, 1024), fs.block_size);
    try std.testing.expectEqual(@as(u32, 32), fs.super.inodes_count);
    try std.testing.expectEqual(@as(u32, 64), fs.super.blocks_count);
    try std.testing.expectEqual(@as(u16, 128), fs.super.inode_size);
}

test "init rejects a wrong magic" {
    var img = buildImage();
    ext2_image.writeU16(&img.data, 1024 + 56, 0);
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
    ext2_image.writeU16(&img.data, 1024 + 88, 64);
    var mock = MockDisk{ .data = &img.data };
    try std.testing.expectError(ext2.Ext2Error.BadInodeSize, ext2.Ext2.init(mount(&mock)));
}

test "init rejects an unsupported block size" {
    var img = buildImage();
    ext2_image.writeU32(&img.data, 1024 + 24, 3); // 8 KiB blocks
    var mock = MockDisk{ .data = &img.data };
    try std.testing.expectError(ext2.Ext2Error.BadBlockSize, ext2.Ext2.init(mount(&mock)));
}

test "readInode resolves the root directory" {
    var img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    const inode = try fs.readInode(2);
    try std.testing.expectEqual(ext2.inode_type_dir, inode.mode & ext2.inode_type_dir);
    try std.testing.expectEqual(@as(u32, 6), inode.block[0]);
}

test "init rejects inodes_per_group of zero" {
    var img = buildImage();
    ext2_image.writeU32(&img.data, 1024 + 40, 0);
    var mock = MockDisk{ .data = &img.data };
    try std.testing.expectError(ext2.Ext2Error.CorruptSuperblock, ext2.Ext2.init(mount(&mock)));
}

test "init rejects blocks_per_group of zero" {
    var img = buildImage();
    ext2_image.writeU32(&img.data, 1024 + 32, 0);
    var mock = MockDisk{ .data = &img.data };
    try std.testing.expectError(ext2.Ext2Error.CorruptSuperblock, ext2.Ext2.init(mount(&mock)));
}

test "groupDescriptor resolves a group beyond the first GDT block" {
    var img = buildImage();
    // Endow the superblock with enough inodes/groups to overflow one GDT
    // block: block_size 1024 / 32 B descriptor = 32 groups per block.
    ext2_image.writeU32(&img.data, 1024 + 0, 270); // inodes_count
    ext2_image.writeU32(&img.data, 1024 + 4, 300); // blocks_count
    // Group 32's descriptor lives in the second GDT block (block 3): inode
    // table on block 20. The inode for index 256 lands at its start.
    const gdt2 = img.data[3 * 1024 .. 3 * 1024 + 32];
    ext2_image.writeU32(gdt2, 0, 18); // block_bitmap
    ext2_image.writeU32(gdt2, 4, 19); // inode_bitmap
    ext2_image.writeU32(gdt2, 8, 20); // inode_table
    ext2_image.writeU16(&img.data, 20 * 1024, ext2.inode_type_reg);
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    const inode = try fs.readInode(257);
    try std.testing.expectEqual(ext2.inode_type_reg, inode.mode & ext2.inode_type_reg);
}

test "readInode rejects an inode in a group beyond the descriptor table" {
    var img = buildImage();
    // 64 blocks / 8 blocks per group = 8 groups; inode 65 lives in group 8,
    // one past the table.
    ext2_image.writeU32(&img.data, 1024 + 0, 100); // inodes_count
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    try std.testing.expectError(ext2.Ext2Error.CorruptSuperblock, fs.readInode(65));
}

test "readInode rejects inode 0 and out-of-range inodes" {
    var img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    try std.testing.expectError(ext2.Ext2Error.NotFound, fs.readInode(0));
    try std.testing.expectError(ext2.Ext2Error.NotFound, fs.readInode(33));
}

test "readDir walks the root directory" {
    var img = buildImage();
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
    var img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    var out: [8]ext2.DirEntry = undefined;
    const count = try fs.readDir(4, &out);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expect(std.mem.eql(u8, "inner.txt", out[2].name[0..out[2].name_len]));
}

test "readDir rejects a regular file inode" {
    var img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    var out: [8]ext2.DirEntry = undefined;
    try std.testing.expectError(ext2.Ext2Error.NotADirectory, fs.readDir(3, &out));
}

test "readDir reports a too-small output buffer" {
    var img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    var out: [1]ext2.DirEntry = undefined;
    try std.testing.expectError(ext2.Ext2Error.BufferTooSmall, fs.readDir(2, &out));
}

test "readFile reads a regular file" {
    var img = buildImage();
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

test "readFile reads through a double-indirect chain" {
    // Logical block 300 (past single indirect) resolved through inode
    // block[13]: 300 - 12 - 256 = 32 -> double table[0] -> single table[32].
    var img = buildImage();
    img.putDoubleIndirectFile(300, 0x33);
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    // The file's only real data block sits at logical block 300; everything
    // before it is a hole (zeros).
    var out: [1024]u8 = undefined;
    const n = try fs.readAt(6, 300 * 1024, &out);
    try std.testing.expectEqual(@as(usize, 1024), n);
    for (out) |b| try std.testing.expectEqual(@as(u8, 0x33), b);
    const inode = try fs.readInode(6);
    try std.testing.expect(inode.block[ext2.inode_double_indirect] != 0);
}

test "readFile reads through a triple-indirect chain" {
    // Logical block 70000 (past double indirect) resolved through inode
    // block[14]. 70000 - 12 - 256 - 65536 = 4196 -> triple[0] -> double[16]
    // (4196/256) -> single[100] (4196%256) -> data.
    var img = buildImage();
    img.putTripleIndirectFile(70000, 0x44);
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    var out: [1024]u8 = undefined;
    const n = try fs.readAt(7, 70000 * 1024, &out);
    try std.testing.expectEqual(@as(usize, 1024), n);
    for (out) |b| try std.testing.expectEqual(@as(u8, 0x44), b);
    const inode = try fs.readInode(7);
    try std.testing.expect(inode.block[ext2.inode_triple_indirect] != 0);
}

test "readFile rejects a directory inode" {
    var img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    var out: [64]u8 = undefined;
    try std.testing.expectError(ext2.Ext2Error.NotAFile, fs.readFile(2, &out));
}

test "find resolves absolute paths" {
    var img = buildImage();
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    try std.testing.expectEqual(@as(u32, 3), try fs.find("/hello.txt"));
    try std.testing.expectEqual(@as(u32, 3), try fs.find("/sub/inner.txt"));
    try std.testing.expectError(ext2.Ext2Error.NotFound, fs.find("/nope"));
}

test "writeAt overwrites an existing file in place (M7.1.3)" {
    var img = buildWriteImage();
    var mock = MockDisk{ .data = &img.data };
    var fs = try ext2.Ext2.init(mount(&mock));
    // Replacing a file's content is truncate + write (writeAt never shrinks
    // the size by itself — partial overwrites keep the longer length).
    try fs.truncate(3, 0);
    try fs.writeAt(3, 0, "hey!");
    var out: [64]u8 = undefined;
    const n = try fs.readFile(3, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expect(std.mem.eql(u8, "hey!", out[0..4]));
}

test "writeAt grows a file into a freshly allocated block (M7.1.2/3)" {
    var img = buildWriteImage();
    var mock = MockDisk{ .data = &img.data };
    var fs = try ext2.Ext2.init(mount(&mock));
    // 2000 bytes needs two 1024-byte blocks: the original block 7 plus one
    // allocated block (the bitmap marks 0..8 used, so 9 is the first free).
    var content = [_]u8{0xAB} ** 2000;
    try fs.writeAt(3, 0, &content);
    var out: [2000]u8 = undefined;
    const n = try fs.readFile(3, &out);
    try std.testing.expectEqual(@as(usize, 2000), n);
    try std.testing.expect(std.mem.eql(u8, &content, &out));
    // Block 9 allocated and freed count dropped by one.
    const inode = try fs.readInode(3);
    try std.testing.expectEqual(@as(u32, 9), inode.block[1]);
    const fresh = try ext2.Ext2.init(mount(&mock));
    try std.testing.expectEqual(@as(u32, 55), fresh.super.free_blocks_count);
}

test "writeAt allocates the single-indirect table for large writes (M7.1.2/3)" {
    var img = buildWriteImage();
    var mock = MockDisk{ .data = &img.data };
    var fs = try ext2.Ext2.init(mount(&mock));
    // 13 * 1024 bytes spans the 12 direct blocks plus one indirect entry.
    var content = [_]u8{0x77} ** (13 * 1024);
    try fs.writeAt(3, 0, &content);
    var out: [13 * 1024]u8 = undefined;
    const n = try fs.readFile(3, &out);
    try std.testing.expectEqual(@as(usize, 13 * 1024), n);
    try std.testing.expect(std.mem.eql(u8, &content, &out));
    const inode = try fs.readInode(3);
    try std.testing.expect(inode.block[ext2.inode_direct_blocks] != 0);
}

test "truncate shrinks a file size (M7.1.3)" {
    var img = buildWriteImage();
    var mock = MockDisk{ .data = &img.data };
    var fs = try ext2.Ext2.init(mount(&mock));
    try fs.truncate(3, 2);
    var out: [64]u8 = undefined;
    const n = try fs.readFile(3, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expect(std.mem.eql(u8, "he", out[0..2]));
}

test "regression: groupDescriptor survives an overflowing blocks_count (fuzz C1)" {
    // Fuzz regression: a corrupt superblock with a huge blocks_count and a
    // small blocks_per_group used to overflow the u32 groups_count arithmetic
    // (integer overflow panic in ext2.zig). The group table of the 64 KiB
    // fixture fits in one GDT block, so a valid descriptor is still readable.
    var img = buildWriteImage();
    ext2_image.writeU32(&img.data, 1024 + 4, 0xFFFF_FFFF); // blocks_count
    ext2_image.writeU32(&img.data, 1024 + 32, 8); // blocks_per_group
    var mock = MockDisk{ .data = &img.data };
    const fs = try ext2.Ext2.init(mount(&mock));
    _ = fs.readInode(2) catch |err| switch (err) {
        // A huge blocks_count may legitimately fail bounds checks downstream;
        // the invariant is only that the arithmetic does not panic.
        else => {},
    };
}

test "regression: adjustFreeBlocks saturates a zero free_blocks_count (fuzz C2)" {
    // Fuzz regression: a corrupt group descriptor with free_blocks == 0 made
    // the decrement underflow past u16 (integer overflow panic in ext2.zig).
    // The count must saturate at zero instead of crashing the kernel.
    var img = buildWriteImage();
    ext2_image.writeU32(&img.data, 2048 + 12, 0); // GDT free_blocks_count = 0
    var mock = MockDisk{ .data = &img.data };
    var fs = try ext2.Ext2.init(mount(&mock));
    fs.writeAt(3, 4096, "grow into a fresh block") catch |err| switch (err) {
        else => {},
    };
}
