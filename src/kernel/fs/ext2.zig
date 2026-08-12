const std = @import("std");
const bytes = @import("bytes.zig");
const block = @import("../drivers/block.zig");

pub const Ext2Error = error{
    BadMagic,
    BadBlockSize,
    CorruptSuperblock,
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
    OutOfSpace,
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
    free_blocks_count: u32,
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

/// ext2 reader/writer over a partition view. Every block read or write goes
/// through the block device — no in-memory image, no allocation, no I/O
/// beyond the device requests (spec/roadmap.md M6.1.3, M7.1.2, M7.1.3). The
/// write path is non-crash-safe (no journal): data blocks are written before
/// the inode metadata, block allocation updates the bitmap and the free counts
/// best-effort (spec/adr/023, roadmap M7.1).
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
        const blocks_per_group = bytes.readU32(&sb, 32);
        const inodes_per_group = bytes.readU32(&sb, 40);
        if (blocks_per_group == 0 or inodes_per_group == 0) return Ext2Error.CorruptSuperblock;
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
                .free_blocks_count = bytes.readU32(&sb, 12),
                .first_data_block = bytes.readU32(&sb, 20),
                .log_block_size = log_block_size,
                .blocks_per_group = blocks_per_group,
                .inodes_per_group = inodes_per_group,
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
        const loc = try self.inodeTableLocation(ino);
        var table_buf: [4096]u8 = undefined;
        try self.readBlock(loc.block, table_buf[0..self.block_size]);
        if (loc.within + 128 > self.block_size) return Ext2Error.OutOfBounds;
        const table = table_buf[loc.within .. loc.within + 128];
        var blocks: [inode_block_ptr_count]u32 = undefined;
        for (0..inode_block_ptr_count) |i| blocks[i] = bytes.readU32(table, 40 + i * 4);
        return .{
            .mode = bytes.readU16(table, 0),
            .size_lo = bytes.readU32(table, 4),
            .size_high = bytes.readU32(table, 108),
            .block = blocks,
        };
    }

    /// Resolve where inode `ino` lives in its inode-table block (M7.1.3).
    fn inodeTableLocation(self: Ext2, ino: u32) Ext2Error!struct { block: u32, within: usize } {
        if (ino == 0 or ino > self.super.inodes_count) return Ext2Error.NotFound;
        if (self.super.inodes_per_group == 0) return Ext2Error.CorruptSuperblock;
        const index = ino - 1;
        const group = index / self.super.inodes_per_group;
        const index_in_group = index % self.super.inodes_per_group;
        const desc = try self.groupDescriptor(group);
        const block_off = @as(usize, index_in_group) * self.super.inode_size;
        const table_block = desc.inode_table + @as(u32, @intCast(block_off / self.block_size));
        return .{ .block = table_block, .within = block_off % self.block_size };
    }

    /// Write inode `ino` back to its inode-table block. The raw 128-byte table
    /// entry is patched (mode, size, block pointers) so untouched metadata
    /// (uid/gid/times) is preserved — those fields are never interpreted
    /// (ADR-023 non-POSIX).
    fn writeInode(self: Ext2, ino: u32, inode: Inode) Ext2Error!void {
        const loc = try self.inodeTableLocation(ino);
        var table_buf: [4096]u8 = undefined;
        try self.readBlock(loc.block, table_buf[0..self.block_size]);
        if (loc.within + 128 > self.block_size) return Ext2Error.OutOfBounds;
        const table = table_buf[loc.within .. loc.within + 128];
        bytes.writeU16(table, 0, inode.mode);
        bytes.writeU32(table, 4, inode.size_lo);
        bytes.writeU32(table, 108, inode.size_high);
        for (0..inode_block_ptr_count) |i| bytes.writeU32(table, 40 + i * 4, inode.block[i]);
        try self.writeBlock(loc.block, table_buf[0..self.block_size]);
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

    /// Read a regular file's data from `offset` into `out` (direct blocks +
    /// the single indirect block; double/triple indirect are rejected).
    /// Returns the number of bytes written, capped by `out.len` and the file
    /// size. Offset past the end returns 0.
    pub fn readAt(self: Ext2, ino: u32, offset: usize, out: []u8) Ext2Error!usize {
        const inode = try self.readInode(ino);
        if (inode.mode & inode_type_reg == 0) return Ext2Error.NotAFile;
        const size: usize = @intCast(inode.size_lo);
        if (offset >= size) return 0;
        const to_read = @min(size - offset, out.len);
        var written: usize = 0;
        var block_index = offset / self.block_size;
        var in_block = offset % self.block_size;
        while (written < to_read) {
            const blk = try self.blockForIndex(inode, block_index) orelse break;
            var block_buf: [4096]u8 = undefined;
            try self.readBlock(blk, block_buf[0..self.block_size]);
            const n = @min(@min(self.block_size - in_block, to_read - written), out.len - written);
            @memcpy(out[written .. written + n], block_buf[in_block .. in_block + n]);
            written += n;
            in_block = 0;
            block_index += 1;
        }
        return written;
    }

    /// Read a whole regular file into `out`.
    pub fn readFile(self: Ext2, ino: u32, out: []u8) Ext2Error!usize {
        return self.readAt(ino, 0, out);
    }

    /// Resolve logical block `index` of `inode` to a physical block number
    /// (direct blocks, then the single-indirect table).
    fn blockForIndex(self: Ext2, inode: Inode, index: usize) Ext2Error!?u32 {
        if (index < inode_direct_blocks) return inode.block[index];
        const indirect_index = index - inode_direct_blocks;
        if (indirect_index >= self.block_size / 4) return Ext2Error.UnsupportedIndirect;
        if (inode.block[inode_direct_blocks] == 0) return null;
        var ptr_buf: [4096]u8 = undefined;
        try self.readBlock(inode.block[inode_direct_blocks], ptr_buf[0..self.block_size]);
        const blk = bytes.readU32(&ptr_buf, indirect_index * 4);
        if (blk == 0) return null;
        return blk;
    }

    /// Write `data` into regular-file `ino` starting at `offset`, growing the
    /// file (block allocation, direct + single indirect) and the inode size as
    /// needed. Data blocks are written before the inode metadata (M7.1.3).
    pub fn writeAt(self: *Ext2, ino: u32, offset: usize, data: []const u8) Ext2Error!void {
        var inode = try self.readInode(ino);
        if (inode.mode & inode_type_reg == 0) return Ext2Error.NotAFile;
        const end = offset + data.len;
        if (end == 0) return;
        const first_block = offset / self.block_size;

        var written: usize = 0;
        var block_index = first_block;
        while (written < data.len) : (block_index += 1) {
            const blk = try self.ensureBlock(&inode, block_index);
            const in_block = (offset + written) % self.block_size;
            const chunk = @min(self.block_size - in_block, data.len - written);
            var block_buf: [4096]u8 = undefined;
            if (chunk != self.block_size or in_block != 0) {
                try self.readBlock(blk, block_buf[0..self.block_size]);
            }
            @memcpy(block_buf[in_block .. in_block + chunk], data[written .. written + chunk]);
            try self.writeBlock(blk, block_buf[0..self.block_size]);
            written += chunk;
        }

        if (end > @as(usize, @intCast(inode.size_lo))) {
            inode.size_lo = @intCast(end);
        }
        try self.writeInode(ino, inode);
    }

    /// Set a regular file's size. Shrinking drops the tail (blocks stay
    /// allocated — never freed on the non-crash-safe write path); growing only
    /// updates the size field, the new range must be filled by `writeAt`.
    pub fn truncate(self: *Ext2, ino: u32, new_size: usize) Ext2Error!void {
        var inode = try self.readInode(ino);
        if (inode.mode & inode_type_reg == 0) return Ext2Error.NotAFile;
        inode.size_lo = @intCast(new_size);
        try self.writeInode(ino, inode);
    }

    /// Resolve logical block `index`, allocating it (and the single-indirect
    /// table when needed) if it does not exist yet.
    fn ensureBlock(self: *Ext2, inode: *Inode, index: usize) Ext2Error!u32 {
        if (index < inode_direct_blocks) {
            if (inode.block[index] != 0) return inode.block[index];
            const blk = try self.allocBlock();
            inode.block[index] = blk;
            var zero_buf: [4096]u8 = undefined;
            @memset(&zero_buf, 0);
            try self.writeBlock(blk, zero_buf[0..self.block_size]);
            return blk;
        }
        const indirect_index = index - inode_direct_blocks;
        if (indirect_index >= self.block_size / 4) return Ext2Error.UnsupportedIndirect;
        if (inode.block[inode_direct_blocks] == 0) {
            const ind_blk = try self.allocBlock();
            inode.block[inode_direct_blocks] = ind_blk;
            var zero_buf: [4096]u8 = undefined;
            @memset(&zero_buf, 0);
            try self.writeBlock(ind_blk, zero_buf[0..self.block_size]);
        }
        var ptr_buf: [4096]u8 = undefined;
        try self.readBlock(inode.block[inode_direct_blocks], ptr_buf[0..self.block_size]);
        var blk = bytes.readU32(&ptr_buf, indirect_index * 4);
        if (blk == 0) {
            blk = try self.allocBlock();
            bytes.writeU32(&ptr_buf, indirect_index * 4, blk);
            try self.writeBlock(inode.block[inode_direct_blocks], ptr_buf[0..self.block_size]);
            var zero_buf: [4096]u8 = undefined;
            @memset(&zero_buf, 0);
            try self.writeBlock(blk, zero_buf[0..self.block_size]);
        }
        return blk;
    }

    /// Allocate one free block: scan the block bitmap of each group for a
    /// clear bit, set it, and decrement the group + superblock free counts.
    /// Block numbering follows the on-disk layout: group 0 starts at
    /// `first_data_block` (1 for 1 KiB blocks), so bit `i` of group `g` maps
    /// to block `g*blocks_per_group + i + first_data_block` — verified against
    /// a real `mke2fs -t ext2` image (1 KiB blocks, `first_data_block` = 1).
    fn allocBlock(self: *Ext2) Ext2Error!u32 {
        const bpg = self.super.blocks_per_group;
        if (bpg == 0) return Ext2Error.CorruptSuperblock;
        const groups_count = (self.super.blocks_count - self.super.first_data_block + bpg - 1) / bpg;
        var g: usize = 0;
        while (g < groups_count) : (g += 1) {
            const desc = try self.groupDescriptor(g);
            const group_start = @as(usize, g) * bpg;
            const blocks_in_group = @min(bpg, self.super.blocks_count - @as(u32, @intCast(group_start)));
            var bitmap_buf: [4096]u8 = undefined;
            try self.readBlock(desc.block_bitmap, bitmap_buf[0..self.block_size]);
            var i: usize = 0;
            while (i < blocks_in_group) : (i += 1) {
                const byte = i / 8;
                const mask: u8 = @as(u8, 1) << @intCast(i % 8);
                if (bitmap_buf[byte] & mask == 0) {
                    bitmap_buf[byte] |= mask;
                    try self.writeBlock(desc.block_bitmap, bitmap_buf[0..self.block_size]);
                    try self.adjustFreeBlocks(g, -1);
                    const first_data: usize = self.super.first_data_block;
                    return @intCast(group_start + i + first_data);
                }
            }
        }
        return Ext2Error.OutOfSpace;
    }

    /// Decrement/increment the free-block counts in the group descriptor and
    /// the superblock by `delta` (metadata, non-crash-safe best-effort).
    fn adjustFreeBlocks(self: Ext2, group: usize, delta: i32) Ext2Error!void {
        const groups_per_block: usize = self.block_size / 32;
        const gdt_block: u32 = @intCast(superblock_offset / self.block_size + 1 + group / groups_per_block);
        const off: usize = (group % groups_per_block) * 32;
        var block_buf: [4096]u8 = undefined;
        try self.readBlock(gdt_block, block_buf[0..self.block_size]);
        const free = bytes.readU16(&block_buf, off + 12);
        bytes.writeU16(&block_buf, off + 12, @intCast(@as(i32, free) + delta));
        try self.writeBlock(gdt_block, block_buf[0..self.block_size]);

        var sb: [1024]u8 = undefined;
        try readDiskOffset(self.disk, superblock_offset, &sb);
        const sb_free = bytes.readU32(&sb, 12);
        bytes.writeU32(&sb, 12, @intCast(@as(i64, sb_free) + delta));
        try writeDiskOffset(self.disk, superblock_offset, &sb);
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
        var entries: [32]DirEntry = undefined;
        const count = try self.readDir(dir_ino, &entries);
        for (entries[0..count]) |e| {
            if (e.name_len == name.len and std.mem.eql(u8, e.name[0..e.name_len], name))
                return e.inode;
        }
        return null;
    }

    fn groupDescriptor(self: Ext2, group: usize) Ext2Error!BlockGroup {
        if (self.super.blocks_per_group == 0) return Ext2Error.CorruptSuperblock;
        if (self.super.blocks_count < self.super.first_data_block) return Ext2Error.CorruptSuperblock;
        const groups_count = (self.super.blocks_count - self.super.first_data_block + self.super.blocks_per_group - 1) / self.super.blocks_per_group;
        if (group >= groups_count) return Ext2Error.CorruptSuperblock;

        // The group descriptor table can span several blocks (one 32-byte
        // descriptor per group). The group's descriptor lives in the table
        // block that contains its index, at the remainder offset within it.
        const groups_per_block: usize = self.block_size / 32;
        const gdt_block: u32 = @intCast(superblock_offset / self.block_size + 1 + group / groups_per_block);
        const off: usize = (group % groups_per_block) * 32;
        var block_buf: [4096]u8 = undefined;
        try self.readBlock(gdt_block, block_buf[0..self.block_size]);
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

    fn writeBlock(self: Ext2, block_num: u32, data: []const u8) Ext2Error!void {
        if (@as(u64, block_num) >= self.super.blocks_count) return Ext2Error.OutOfBounds;
        if (data.len != self.block_size) return Ext2Error.IoError;
        const sectors_per_block: u64 = @intCast(self.block_size / 512);
        const start = @as(u64, block_num) * sectors_per_block;
        var offset: usize = 0;
        var i: u64 = 0;
        while (offset < data.len) : (i += 1) {
            var sector_buf: [512]u8 = undefined;
            @memcpy(&sector_buf, data[offset .. offset + @min(@as(usize, 512), data.len - offset)]);
            self.disk.writeSector(start + i, &sector_buf) catch return Ext2Error.IoError;
            offset += @min(@as(usize, 512), data.len - offset);
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

fn writeDiskOffset(disk: block.PartitionView, offset: usize, data: []const u8) Ext2Error!void {
    var buf_offset: usize = 0;
    var lba: u64 = @intCast(offset / 512);
    var skip: usize = offset % 512;
    while (buf_offset < data.len) : (lba += 1) {
        var sector_buf: [512]u8 = undefined;
        if (skip != 0 or data.len - buf_offset < 512) {
            disk.readSector(lba, &sector_buf) catch return Ext2Error.IoError;
        }
        const from = skip;
        skip = 0;
        const n = @min(@as(usize, 512) - from, data.len - buf_offset);
        @memcpy(sector_buf[from .. from + n], data[buf_offset .. buf_offset + n]);
        disk.writeSector(lba, &sector_buf) catch return Ext2Error.IoError;
        buf_offset += n;
    }
}
