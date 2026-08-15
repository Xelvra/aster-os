const std = @import("std");
const ext2 = @import("kernel").ext2;
const block = @import("kernel").block;
const MockDisk = @import("mock.zig").MockDisk;
const ext2_image = @import("ext2_image.zig");

const image_size = 64 * 1024;
const buildImage = ext2_image.buildWriteImage;

/// SplitMix64 — small, deterministic PRNG for the fuzz seed stream. No
/// external dependency and identical output across runs and hosts, so a
/// failing seed reproduces exactly.
const SplitMix64 = struct {
    state: u64,

    fn next(self: *SplitMix64) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }
};

fn mount(mock: *MockDisk) block.PartitionView {
    return .{
        .disk = .{ .ctx = mock, .read_fn = MockDisk.read, .write_fn = MockDisk.write },
        .first_lba = 0,
        .last_lba = image_size / 512 - 1,
        .type_guid = undefined,
    };
}

/// Corrupt a structured field of the superblock (block 1, offset 1024).
/// The chosen offsets match the writer in `ext2_image.zig` so mutations hit
/// real on-disk semantics rather than random noise.
fn corruptSuperblock(rng: *SplitMix64, data: []u8) void {
    const offsets = [_]u32{ 0, 4, 12, 16, 20, 24, 32, 40, 76, 84 };
    const off: u32 = offsets[rng.next() % offsets.len];
    const value: u32 = switch (rng.next() % 5) {
        0 => 0,
        1 => std.math.maxInt(u32),
        2 => 1,
        3 => @truncate(rng.next()),
        else => 0x100000,
    };
    ext2_image.writeU32(data, 1024 + off, value);
}

fn corruptMagic(rng: *SplitMix64, data: []u8) void {
    const value: u16 = switch (rng.next() % 3) {
        0 => 0,
        1 => ext2.super_magic +% 1,
        else => @truncate(rng.next()),
    };
    ext2_image.writeU16(data, 1024 + 56, value);
}

fn corruptInodeSize(rng: *SplitMix64, data: []u8) void {
    const value: u16 = switch (rng.next() % 4) {
        0 => 0,
        1 => 64,
        2 => 129,
        else => @truncate(rng.next()),
    };
    ext2_image.writeU16(data, 1024 + 88, value);
}

fn corruptFeatures(rng: *SplitMix64, data: []u8) void {
    const offsets = [_]u32{ 92, 96, 100 };
    const off: u32 = offsets[rng.next() % offsets.len];
    const value: u32 = switch (rng.next() % 4) {
        0 => 0,
        1 => 0xFFFFFFFF,
        2 => @as(u32, @truncate(rng.next())),
        else => @as(u32, @truncate(rng.next())),
    };
    ext2_image.writeU32(data, 1024 + off, value);
}

/// Corrupt one field of the group descriptor table (block 2, offset 2048).
fn corruptGroupDescriptor(rng: *SplitMix64, data: []u8) void {
    const offsets = [_]u32{ 0, 4, 8, 12, 14 };
    const off: u32 = offsets[rng.next() % offsets.len];
    const value: u32 = switch (rng.next() % 4) {
        0 => 0,
        1 => std.math.maxInt(u32),
        2 => @as(u32, @truncate(rng.next())),
        else => 5 + @as(u32, @truncate(rng.next() % 16)),
    };
    ext2_image.writeU32(data, 2048 + off, value);
}

/// Corrupt the inode table (block 5): mode, size, or one block pointer.
fn corruptInodeTable(rng: *SplitMix64, data: []u8) void {
    const ino = 1 + (rng.next() % 8);
    const base = 5 * 1024 + @as(usize, ino - 1) * 128;
    switch (rng.next() % 3) {
        0 => ext2_image.writeU16(data, base, @truncate(rng.next())), // mode
        1 => ext2_image.writeU32(data, base + 4, switch (rng.next() % 4) {
            0 => 0,
            1 => std.math.maxInt(u32),
            else => @as(u32, @truncate(rng.next())),
        }), // size_lo
        else => ext2_image.writeU32(data, base + 40 + (rng.next() % 15) * 4, switch (rng.next() % 3) {
            0 => 0,
            1 => std.math.maxInt(u32),
            else => @as(u32, @truncate(rng.next())),
        }), // block pointer
    }
}

/// Corrupt a directory entry in the root directory data block (block 6):
/// rec_len, name_len, or the inode number.
fn corruptDirEntry(rng: *SplitMix64, data: []u8) void {
    const off = 6 * 1024 + (rng.next() % 256);
    switch (rng.next() % 3) {
        0 => ext2_image.writeU16(data, off + 4, switch (rng.next() % 3) {
            0 => 0,
            1 => std.math.maxInt(u16),
            else => @truncate(rng.next()),
        }), // rec_len
        1 => data[off + 6] = 255, // name_len
        else => ext2_image.writeU32(data, off, switch (rng.next() % 3) {
            0 => 0,
            1 => std.math.maxInt(u32),
            else => @as(u32, @truncate(rng.next())),
        }), // inode
    }
}

/// Corrupt the block or inode bitmap (blocks 3 and 4).
fn corruptBitmap(rng: *SplitMix64, data: []u8) void {
    const base = if (rng.next() % 2 == 0) @as(usize, 3) else 4;
    const byte = base * 1024 + (rng.next() % 1024);
    data[byte] = @truncate(rng.next());
}

/// Corrupt several superblock counts together (blocks_count, inodes_count,
/// blocks_per_group, inodes_per_group). The bitmap-OOB / inode-table-overflow
/// bugs need such paired extremes, which single-field mutations cannot reach
/// (audit 2026-08-15).
fn corruptSuperblockPaired(rng: *SplitMix64, data: []u8) void {
    for ([_]u32{ 0, 4, 32, 40 }) |off| {
        const value: u32 = switch (rng.next() % 4) {
            0 => 0,
            1 => std.math.maxInt(u32),
            2 => 1,
            else => 0x100000,
        };
        ext2_image.writeU32(data, 1024 + off, value);
    }
}

/// Apply 1..4 structured mutations to a copy of a valid image.
fn mutate(rng: *SplitMix64, img: *ext2_image.Image) void {
    const count = 1 + (rng.next() % 4);
    for (0..count) |_| {
        switch (rng.next() % 9) {
            0 => corruptSuperblock(rng, &img.data),
            1 => corruptMagic(rng, &img.data),
            2 => corruptInodeSize(rng, &img.data),
            3 => corruptFeatures(rng, &img.data),
            4 => corruptGroupDescriptor(rng, &img.data),
            5 => corruptInodeTable(rng, &img.data),
            6 => corruptDirEntry(rng, &img.data),
            7 => corruptBitmap(rng, &img.data),
            else => corruptSuperblockPaired(rng, &img.data),
        }
    }
}

/// Exercise the read-only surface on a mutated image. Every call must either
/// succeed or return an Ext2Error; a panic, UB or hang would fail the test.
fn exerciseRead(rng: *SplitMix64, img: *ext2_image.Image) void {
    var mock = MockDisk{ .data = &img.data };
    const fs = ext2.Ext2.init(mount(&mock)) catch return;
    _ = fs.readInode(ext2.root_inode) catch return;
    var dir_buf: [8]ext2.DirEntry = undefined;
    _ = fs.readDir(ext2.root_inode, &dir_buf) catch return;
    var file_buf: [128]u8 = undefined;
    _ = fs.readFile(3, &file_buf) catch return;
    // Follow find() results into readInode so a mutated directory-entry inode
    // number reaches inodeTableLocation (the overflow class that was not
    // exercised before, audit 2026-08-15).
    if (fs.find("/hello.txt")) |ino| {
        _ = fs.readInode(ino) catch return;
    } else |_| {}
    if (fs.find("/sub/inner.txt")) |ino| {
        _ = fs.readInode(ino) catch return;
    } else |_| {}
    // Exercise the single-indirect read path (block 13 is past the 12 direct
    // blocks) when the mutated inode points at an indirect block.
    _ = fs.readAt(3, 13 * 1024, &file_buf) catch return;
    // Exercise a second mount from the (possibly write-mutated) image when the
    // RNG picks an extra pass — cheap extra coverage of re-init on dirty data.
    if (rng.next() % 3 == 0) {
        var mock2 = MockDisk{ .data = &img.data };
        const fs2 = ext2.Ext2.init(mount(&mock2)) catch return;
        var out2: [8]ext2.DirEntry = undefined;
        _ = fs2.readDir(ext2.root_inode, &out2) catch return;
    }
}

/// Exercise the write surface (writeAt/truncate) on a mutated image. The
/// write path mutates the image, so each iteration starts from a fresh copy.
fn exerciseWrite(rng: *SplitMix64, img: *ext2_image.Image) void {
    var mock = MockDisk{ .data = &img.data };
    var fs = ext2.Ext2.init(mount(&mock)) catch return;
    const payload = [_]u8{0x5A} ** 64;
    fs.writeAt(3, 0, &payload) catch return;
    fs.truncate(3, 32) catch return;
    if (rng.next() % 2 == 0) {
        fs.writeAt(3, 4096, &payload) catch return;
    }
    // Exercise the single-indirect write path (block 13 is past the 12 direct
    // blocks); the indirect allocator was never covered (audit 2026-08-15).
    fs.writeAt(3, 13 * 1024, &payload) catch return;
}

test "fuzz: structured corruption never crashes the ext2 parser (read path)" {
    const seed: u64 = 0xA5E2_F0D0_C0DE_0001;
    var rng = SplitMix64{ .state = seed };
    for (0..400) |i| {
        var img = buildImage();
        mutate(&rng, &img);
        exerciseRead(&rng, &img);
        _ = i;
    }
}

test "fuzz: structured corruption never crashes the ext2 parser (write path)" {
    const seed: u64 = 0xA5E2_F0D0_C0DE_0002;
    var rng = SplitMix64{ .state = seed };
    for (0..200) |i| {
        var img = buildImage();
        mutate(&rng, &img);
        exerciseWrite(&rng, &img);
        _ = i;
    }
}
