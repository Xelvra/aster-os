const std = @import("std");
const ext2 = @import("kernel").ext2;

pub const block_size = 1024;

pub fn writeU16(buf: []u8, off: usize, v: u16) void {
    buf[off] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
}

pub fn writeU32(buf: []u8, off: usize, v: u32) void {
    buf[off] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
    buf[off + 2] = @truncate(v >> 16);
    buf[off + 3] = @truncate(v >> 24);
}

pub const Entry = struct {
    ino: u32,
    file_type: u8,
    name: []const u8,
};

/// Minimal 1 KiB-block ext2 image: one block group, inode table on block 5
/// (8 inodes x 128 B), root dir data on block 6, a file on block 7, and a
/// subdirectory on block 8. Feature bits stay within the ADR-023 subset.
pub const Image = struct {
    data: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024),

    pub fn superblock(self: *Image, features: struct { compat: u32, incompat: u32, ro_compat: u32 }) void {
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

    pub fn groupDescriptors(self: *Image) void {
        const gdt = self.data[2048 .. 2048 + 32];
        writeU32(gdt, 0, 3); // block_bitmap
        writeU32(gdt, 4, 4); // inode_bitmap
        writeU32(gdt, 8, 5); // inode_table
    }

    pub fn putInode(self: *Image, ino: u32, mode: u16, size: u32, block0: u32) void {
        const off = 5 * block_size + @as(usize, ino - 1) * 128;
        writeU16(&self.data, off, mode);
        writeU32(&self.data, off + 4, size);
        writeU32(&self.data, off + 40, block0); // i_block[0]
    }

    pub fn putDir(self: *Image, blk: u32, entries: []const Entry) void {
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
    pub fn putIndirectFile(self: *Image, size: u32) void {
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

pub fn buildImage() Image {
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
