const std = @import("std");
const bytes = @import("bytes.zig");

pub const Ext2Error = error{
    BadMagic,
    BadBlockSize,
    BadInodeSize,
    UnsupportedFeatures,
    OutOfBounds,
    NotFound,
    NotADirectory,
    BufferTooSmall,
};

pub const super_magic: u16 = 0xEF53;
pub const superblock_offset: usize = 1024;

pub const feature_compat_filetype: u32 = 0x0001;
pub const feature_compat_dir_index: u32 = 0x0002;
pub const feature_ro_compat_sparse_super: u32 = 0x0001;
pub const feature_incompat_recovery: u32 = 0x0001;

/// Feature subset per ADR-023: dir_index (HTree) is deliberately unsupported
/// (the image builder must use `mke2fs -O ^dir_index`), as is everything that
/// requires write-time or journaling semantics. Unknown bits are rejected.
pub const supported_compat: u32 = feature_compat_filetype;
pub const supported_ro_compat: u32 = feature_ro_compat_sparse_super;
pub const supported_incompat: u32 = 0;

pub const inode_type_dir: u16 = 0x4000;
pub const inode_type_reg: u16 = 0x8000;
pub const inode_block_ptr_count: usize = 15;

pub const Superblock = struct {
    inodes_count: u32,
    blocks_count: u32,
    first_data_block: u32,
    log_block_size: u32,
    blocks_per_group: u32,
    inodes_per_group: u32,
    first_ino: u32,
    inode_size: u16,
    feature_compat: u32,
    feature_incompat: u32,
    feature_ro_compat: u32,
};

pub const BlockGroup = struct {
    block_bitmap: u32,
    inode_bitmap: u32,
    inode_table: u32,
};

pub const Inode = struct {
    mode: u16,
    size_lo: u32,
    size_high: u32,
    block: [inode_block_ptr_count]u32,
};

pub const DirEntry = struct {
    inode: u32,
    file_type: u8,
    name: []const u8,
};

/// Read-only ext2 reader over a whole block-device image. Pure functions over
/// the raw bytes — no allocation, no I/O. The `name` slices of DirEntry point
/// into the image data.
pub const Ext2 = struct {
    data: []const u8,
    super: Superblock,
    block_size: usize,

    pub fn init(data: []const u8) Ext2Error!Ext2 {
        if (data.len < superblock_offset + 256) return Ext2Error.OutOfBounds;
        const sb = data[superblock_offset..];
        if (bytes.readU16(sb, 56) != super_magic) return Ext2Error.BadMagic;
        const inode_size = bytes.readU16(sb, 88);
        if (inode_size < 128) return Ext2Error.BadInodeSize;
        const log_block_size = bytes.readU32(sb, 24);
        if (log_block_size > 2) return Ext2Error.BadBlockSize;
        const feature_compat = bytes.readU32(sb, 92);
        const feature_incompat = bytes.readU32(sb, 96);
        const feature_ro_compat = bytes.readU32(sb, 100);
        if (feature_compat & ~supported_compat != 0) return Ext2Error.UnsupportedFeatures;
        if (feature_incompat & ~supported_incompat != 0) return Ext2Error.UnsupportedFeatures;
        if (feature_ro_compat & ~supported_ro_compat != 0) return Ext2Error.UnsupportedFeatures;
        return .{
            .data = data,
            .super = .{
                .inodes_count = bytes.readU32(sb, 0),
                .blocks_count = bytes.readU32(sb, 4),
                .first_data_block = bytes.readU32(sb, 20),
                .log_block_size = log_block_size,
                .blocks_per_group = bytes.readU32(sb, 32),
                .inodes_per_group = bytes.readU32(sb, 40),
                .first_ino = bytes.readU32(sb, 84),
                .inode_size = inode_size,
                .feature_compat = feature_compat,
                .feature_incompat = feature_incompat,
                .feature_ro_compat = feature_ro_compat,
            },
            .block_size = @as(usize, 1024) << @intCast(log_block_size),
        };
    }

    /// Look up inode `ino` via its block group descriptor table.
    pub fn readInode(self: Ext2, ino: u32) Ext2Error!Inode {
        if (ino == 0 or ino > self.super.inodes_count) return Ext2Error.NotFound;
        const index = ino - 1;
        const group = index / self.super.inodes_per_group;
        const index_in_group = index % self.super.inodes_per_group;
        const desc = try self.groupDescriptor(@intCast(group));
        const inode_table = try self.blockSlice(desc.inode_table);
        const off = @as(usize, index_in_group) * self.super.inode_size;
        if (off + 128 > inode_table.len) return Ext2Error.OutOfBounds;
        var block: [inode_block_ptr_count]u32 = undefined;
        for (0..inode_block_ptr_count) |i| block[i] = bytes.readU32(inode_table, off + 40 + i * 4);
        return .{
            .mode = bytes.readU16(inode_table, off),
            .size_lo = bytes.readU32(inode_table, off + 4),
            .size_high = bytes.readU32(inode_table, off + 108),
            .block = block,
        };
    }

    /// Walk the directory entries of inode `ino` into `out`. Stops at the end
    /// of the directory block (rec_len == 0 guard); unused entries (inode 0)
    /// are skipped. Returns the number of entries written.
    pub fn readDir(self: Ext2, ino: u32, out: []DirEntry) Ext2Error!usize {
        const inode = try self.readInode(ino);
        if (inode.mode & inode_type_dir == 0) return Ext2Error.NotADirectory;
        const data = try self.blockSlice(inode.block[0]);
        var off: usize = 0;
        var count: usize = 0;
        while (off + 8 <= data.len) {
            const entry_inode = bytes.readU32(data, off);
            const rec_len = bytes.readU16(data, off + 4);
            if (rec_len == 0) break;
            const name_len = data[off + 6];
            if (count == out.len) return Ext2Error.BufferTooSmall;
            if (entry_inode != 0) {
                const name_end = off + 8 + @as(usize, name_len);
                if (name_end > data.len) return Ext2Error.OutOfBounds;
                out[count] = .{
                    .inode = entry_inode,
                    .file_type = data[off + 7],
                    .name = data[off + 8 .. name_end],
                };
                count += 1;
            }
            off += rec_len;
        }
        return count;
    }

    fn blockSlice(self: Ext2, block: u32) Ext2Error![]const u8 {
        const start = @as(usize, block) * self.block_size;
        const end = start + self.block_size;
        if (end > self.data.len) return Ext2Error.OutOfBounds;
        return self.data[start..end];
    }

    fn groupDescriptor(self: Ext2, group: usize) Ext2Error!BlockGroup {
        const gdt_block = superblock_offset / self.block_size + 1;
        const gdt = try self.blockSlice(@intCast(gdt_block));
        const off = group * 32;
        if (off + 32 > gdt.len) return Ext2Error.OutOfBounds;
        return .{
            .block_bitmap = bytes.readU32(gdt, off),
            .inode_bitmap = bytes.readU32(gdt, off + 4),
            .inode_table = bytes.readU32(gdt, off + 8),
        };
    }
};
