const std = @import("std");
const bytes = @import("bytes.zig");
const block = @import("../drivers/block.zig");

pub const Ext2Error = error{
    BadMagic,
    BadBlockSize,
    BadInodeSize,
    UnsupportedFeatures,
    OutOfBounds,
    IoError,
    NotFound,
    NotADirectory,
    NotAFile,
    UnsupportedIndirect,
    BufferTooSmall,
    NameTooLong,
};

pub const super_magic: u16 = 0xEF53;
pub const superblock_offset: usize = 1024;

pub const feature_compat_ext_attr: u32 = 0x0008;
pub const feature_compat_resize_inode: u32 = 0x0010;
pub const feature_compat_dir_index: u32 = 0x0020;
pub const feature_incompat_filetype: u32 = 0x0002;
pub const feature_incompat_recovery: u32 = 0x0004;
pub const feature_ro_compat_sparse_super: u32 = 0x0001;
pub const feature_ro_compat_large_file: u32 = 0x0002;

/// Feature subset per ADR-023: dir_index (HTree) is deliberately unsupported
/// (the image builder must use `mke2fs -O ^dir_index`); the remaining default
/// mke2fs -t ext2 features (filetype, ext_attr, resize_inode, sparse_super,
/// large_file) are safe for read-only data reads. Unknown bits are rejected.
pub const supported_compat: u32 = feature_compat_ext_attr | feature_compat_resize_inode;
pub const supported_incompat: u32 = feature_incompat_filetype;
pub const supported_ro_compat: u32 = feature_ro_compat_sparse_super | feature_ro_compat_large_file;

pub const inode_type_dir: u16 = 0x4000;
pub const inode_type_reg: u16 = 0x8000;
pub const inode_direct_blocks: usize = 12;
pub const inode_block_ptr_count: usize = 15;

pub const root_inode: u32 = 2;

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
    name: [255]u8,
    name_len: u8,
};

/// Read-only ext2 reader over a partition view. Every block read goes through
/// the block device — no in-memory image, no allocation, no I/O beyond the
/// device reads (spec/roadmap.md M6.1.3).
pub const Ext2 = struct {
    disk: block.PartitionView,
    super: Superblock,
    block_size: usize,

    /// Mount a partition: read and validate the superblock (magic, feature
    /// subset per ADR-023, inode/block size) and derive the block size.
    pub fn init(disk: block.PartitionView) Ext2Error!Ext2 {
        var sb: [1024]u8 = undefined;
        try readDiskOffset(disk, superblock_offset, &sb);
        if (bytes.readU16(&sb, 56) != super_magic) return Ext2Error.BadMagic;
        const inode_size = bytes.readU16(&sb, 88);
        if (inode_size < 128) return Ext2Error.BadInodeSize;
        const log_block_size = bytes.readU32(&sb, 24);
        if (log_block_size > 2) return Ext2Error.BadBlockSize;
        const feature_compat = bytes.readU32(&sb, 92);
        const feature_incompat = bytes.readU32(&sb, 96);
        const feature_ro_compat = bytes.readU32(&sb, 100);
        if (feature_compat & ~supported_compat != 0) return Ext2Error.UnsupportedFeatures;
        if (feature_incompat & ~supported_incompat != 0) return Ext2Error.UnsupportedFeatures;
        if (feature_ro_compat & ~supported_ro_compat != 0) return Ext2Error.UnsupportedFeatures;
        return .{
            .disk = disk,
            .super = .{
                .inodes_count = bytes.readU32(&sb, 0),
                .blocks_count = bytes.readU32(&sb, 4),
                .first_data_block = bytes.readU32(&sb, 20),
                .log_block_size = log_block_size,
                .blocks_per_group = bytes.readU32(&sb, 32),
                .inodes_per_group = bytes.readU32(&sb, 40),
                .first_ino = bytes.readU32(&sb, 84),
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
        const desc = try self.groupDescriptor(group);
        const block_off = @as(usize, index_in_group) * self.super.inode_size;
        const table_block = desc.inode_table + @as(u32, @intCast(block_off / self.block_size));
        const within = block_off % self.block_size;
        var table_buf: [4096]u8 = undefined;
        try self.readBlock(table_block, table_buf[0..self.block_size]);
        if (within + 128 > self.block_size) return Ext2Error.OutOfBounds;
        const table = table_buf[within .. within + 128];
        var blocks: [inode_block_ptr_count]u32 = undefined;
        for (0..inode_block_ptr_count) |i| blocks[i] = bytes.readU32(table, 40 + i * 4);
        return .{
            .mode = bytes.readU16(table, 0),
            .size_lo = bytes.readU32(table, 4),
            .size_high = bytes.readU32(table, 108),
            .block = blocks,
        };
    }

    /// Walk the directory entries of inode `ino` into `out`. Names are copied
    /// into the fixed `name` buffer (safe after the block read buffer is
    /// dropped). Returns the number of entries written.
    pub fn readDir(self: Ext2, ino: u32, out: []DirEntry) Ext2Error!usize {
        const inode = try self.readInode(ino);
        if (inode.mode & inode_type_dir == 0) return Ext2Error.NotADirectory;
        var block_buf: [4096]u8 = undefined;
        try self.readBlock(inode.block[0], block_buf[0..self.block_size]);
        const data = block_buf[0..self.block_size];
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
                @memcpy(out[count].name[0..name_len], data[off + 8 .. name_end]);
                out[count].name_len = name_len;
                out[count].inode = entry_inode;
                out[count].file_type = data[off + 7];
                count += 1;
            }
            off += rec_len;
        }
        return count;
    }

    /// Read a regular file's data into `out` (direct blocks + the single
    /// indirect block; double/triple indirect are rejected). Returns the
    /// number of bytes written, capped by `out.len`.
    pub fn readFile(self: Ext2, ino: u32, out: []u8) Ext2Error!usize {
        const inode = try self.readInode(ino);
        if (inode.mode & inode_type_reg == 0) return Ext2Error.NotAFile;
        const size: usize = @intCast(inode.size_lo);
        var written: usize = 0;
        var direct: usize = 0;
        while (direct < inode_direct_blocks and written < size and written < out.len) : (direct += 1) {
            const blk = inode.block[direct];
            if (blk == 0) break;
            const n = try self.readDataBlock(blk, out[written..], size - written);
            written += n;
            if (n < self.block_size) break;
        }
        if (written < size and written < out.len and direct == inode_direct_blocks) {
            const indirect = inode.block[inode_direct_blocks];
            if (indirect != 0) {
                var ptr_buf: [4096]u8 = undefined;
                try self.readBlock(indirect, ptr_buf[0..self.block_size]);
                var i: usize = 0;
                while (i < self.block_size / 4 and written < size and written < out.len) : (i += 1) {
                    const blk = bytes.readU32(&ptr_buf, i * 4);
                    if (blk == 0) break;
                    const n = try self.readDataBlock(blk, out[written..], size - written);
                    written += n;
                }
                if (written < size and written < out.len)
                    return Ext2Error.UnsupportedIndirect;
            }
        }
        return written;
    }

    /// Resolve an absolute path to an inode number (spec/roadmap.md M6.1.3,
    /// exit: "výpis souborů").
    pub fn find(self: Ext2, path: []const u8) Ext2Error!u32 {
        var ino: u32 = root_inode;
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            ino = (try self.lookupDir(ino, seg)) orelse return Ext2Error.NotFound;
        }
        return ino;
    }

    fn lookupDir(self: Ext2, dir_ino: u32, name: []const u8) Ext2Error!?u32 {
        var entries: [64]DirEntry = undefined;
        const count = try self.readDir(dir_ino, &entries);
        for (entries[0..count]) |e| {
            if (e.name_len == name.len and std.mem.eql(u8, e.name[0..e.name_len], name))
                return e.inode;
        }
        return null;
    }

    fn readDataBlock(self: Ext2, blk: u32, out: []u8, remaining: usize) Ext2Error!usize {
        var block_buf: [4096]u8 = undefined;
        try self.readBlock(blk, block_buf[0..self.block_size]);
        const n = @min(@min(self.block_size, remaining), out.len);
        @memcpy(out[0..n], block_buf[0..n]);
        return n;
    }

    fn groupDescriptor(self: Ext2, group: usize) Ext2Error!BlockGroup {
        const gdt_block: u32 = @intCast(superblock_offset / self.block_size + 1);
        var block_buf: [4096]u8 = undefined;
        try self.readBlock(gdt_block, block_buf[0..self.block_size]);
        const off = group * 32;
        if (off + 32 > self.block_size) return Ext2Error.OutOfBounds;
        const desc = block_buf[off .. off + 32];
        const inode_table = bytes.readU32(desc, 8);
        if (inode_table >= self.super.blocks_count) return Ext2Error.OutOfBounds;
        return .{
            .block_bitmap = bytes.readU32(desc, 0),
            .inode_bitmap = bytes.readU32(desc, 4),
            .inode_table = inode_table,
        };
    }

    fn readBlock(self: Ext2, block_num: u32, out: []u8) Ext2Error!void {
        if (@as(u64, block_num) >= self.super.blocks_count) return Ext2Error.OutOfBounds;
        const sectors_per_block: u64 = @intCast(self.block_size / 512);
        const start = @as(u64, block_num) * sectors_per_block;
        var offset: usize = 0;
        var i: u64 = 0;
        while (offset < out.len) : (i += 1) {
            var sector_buf: [512]u8 = undefined;
            self.disk.readSector(start + i, &sector_buf) catch return Ext2Error.IoError;
            const n = @min(@as(usize, 512), out.len - offset);
            @memcpy(out[offset .. offset + n], sector_buf[0..n]);
            offset += n;
        }
    }
};

fn readDiskOffset(disk: block.PartitionView, offset: usize, out: []u8) Ext2Error!void {
    var buf_offset: usize = 0;
    var lba: u64 = @intCast(offset / 512);
    var skip: usize = offset % 512;
    while (buf_offset < out.len) : (lba += 1) {
        var sector_buf: [512]u8 = undefined;
        disk.readSector(lba, &sector_buf) catch return Ext2Error.IoError;
        const from = skip;
        skip = 0;
        const n = @min(@as(usize, 512) - from, out.len - buf_offset);
        @memcpy(out[buf_offset .. buf_offset + n], sector_buf[from .. from + n]);
        buf_offset += n;
    }
}
