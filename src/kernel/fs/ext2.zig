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
    FileExists,
};

pub const super_magic: u16 = 0xEF53;
pub const superblock_offset: usize = 1024;

pub const feature_compat_ext_attr: u32 = 0x0008;
pub const feature_compat_resize_inode: u32 = 0x0010;
pub const feature_compat_dir_index: u32 = 0x0020; // unsupported (HTree); kept for the rejection tests
pub const feature_incompat_filetype: u32 = 0x0002;
pub const feature_incompat_recovery: u32 = 0x0004; // kept for the rejection tests
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
/// Inode block-pointer slots for the indirect chains: 12 = single, 13 =
/// double, 14 = triple indirect (ext2 layout, `inode.block[12..14]`).
pub const inode_single_indirect: usize = 12;
pub const inode_double_indirect: usize = 13;
pub const inode_triple_indirect: usize = 14;

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
        const block_size: usize = @as(usize, 1024) << @intCast(log_block_size);
        const blocks_per_group = bytes.readU32(&sb, 32);
        const inodes_per_group = bytes.readU32(&sb, 40);
        if (blocks_per_group == 0 or inodes_per_group == 0) return Ext2Error.CorruptSuperblock;
        // A bitmap is one block; per-group counts larger than its capacity
        // would make the bitmap scans read out of bounds (audit 2026-08-15).
        if (blocks_per_group > block_size * 8 or inodes_per_group > block_size * 8) return Ext2Error.CorruptSuperblock;
        const first_ino = bytes.readU32(&sb, 84);
        if (first_ino == 0) return Ext2Error.CorruptSuperblock;
        const blocks_count = bytes.readU32(&sb, 4);
        // The per-group inode table (inode_size * inodes_per_group bytes) must
        // fit inside the filesystem, so inodeTableLocation's block offset can
        // never exceed u32 (audit 2026-08-15).
        if (@as(u64, inodes_per_group) * inode_size > @as(u64, blocks_count) * block_size) return Ext2Error.CorruptSuperblock;
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
                .blocks_count = blocks_count,
                .free_blocks_count = bytes.readU32(&sb, 12),
                .first_data_block = bytes.readU32(&sb, 20),
                .log_block_size = log_block_size,
                .blocks_per_group = blocks_per_group,
                .inodes_per_group = inodes_per_group,
                .first_ino = first_ino,
                .inode_size = inode_size,
                .feature_compat = feature_compat,
                .feature_incompat = feature_incompat,
                .feature_ro_compat = feature_ro_compat,
            },
            .block_size = block_size,
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
        const block_off = @as(u64, index_in_group) * self.super.inode_size;
        const table_off = block_off / self.block_size;
        // table_off < blocks_count is guaranteed by the mount-time inode-table
        // fit check; guard anyway so the cast below cannot overflow (audit
        // 2026-08-15).
        const table_block_u64 = @as(u64, desc.inode_table) + table_off;
        if (table_block_u64 >= self.super.blocks_count) return Ext2Error.OutOfBounds;
        return .{ .block = @intCast(table_block_u64), .within = @intCast(block_off % self.block_size) };
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

    /// Initialize a freshly allocated inode slot: zero the whole 128-byte
    /// entry (no stale metadata leaking to host tools) and set the file mode,
    /// zero size and a link count of 1 so host `stat` sees a sane file.
    fn initInode(self: *Ext2, ino: u32, mode: u16) Ext2Error!void {
        const loc = try self.inodeTableLocation(ino);
        var table_buf: [4096]u8 = undefined;
        try self.readBlock(loc.block, table_buf[0..self.block_size]);
        if (loc.within + 128 > self.block_size) return Ext2Error.OutOfBounds;
        const table = table_buf[loc.within .. loc.within + 128];
        @memset(table, 0);
        bytes.writeU16(table, 0, mode);
        bytes.writeU16(table, 26, 1); // links_count
        try self.writeBlock(loc.block, table_buf[0..self.block_size]);
    }

    /// Walk the directory entries of inode `ino` into `out`. Names are copied
    /// into the fixed `name` buffer (safe after the block read buffer is
    /// dropped). Returns the number of entries written.
    pub fn readDir(self: Ext2, ino: u32, out: []DirEntry) Ext2Error!usize {
        const inode = try self.readInode(ino);
        if (inode.mode & inode_type_dir == 0) return Ext2Error.NotADirectory;
        var block_buf: [4096]u8 = undefined;
        var count: usize = 0;
        var block_index: usize = 0;
        // Walk every block of the directory (direct + single indirect) so a
        // directory spanning several blocks is fully listed; a hole (or the
        // end of the block list) ends the walk. blockForIndex treats a 0
        // pointer as a hole, so an empty directory never reads the superblock
        // as entries (audit 2026-08-15).
        while (try self.blockForIndex(inode, block_index)) |blk| {
            try self.readBlock(blk, block_buf[0..self.block_size]);
            const data = block_buf[0..self.block_size];
            var off: usize = 0;
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
            block_index += 1;
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
            const n = @min(@min(self.block_size - in_block, to_read - written), out.len - written);
            if (try self.blockForIndex(inode, block_index)) |blk| {
                var block_buf: [4096]u8 = undefined;
                try self.readBlock(blk, block_buf[0..self.block_size]);
                @memcpy(out[written .. written + n], block_buf[in_block .. in_block + n]);
            } else {
                // A hole (sparse file): the block reads as zeros.
                @memset(out[written .. written + n], 0);
            }
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
    /// (direct blocks, then single/double/triple indirect chains).
    fn blockForIndex(self: Ext2, inode: Inode, index: usize) Ext2Error!?u32 {
        if (index < inode_direct_blocks) {
            // A direct pointer of 0 is a hole (sparse file), not block 0 —
            // reading the superblock as file data would leak foreign bytes
            // (audit 2026-08-15).
            const blk = inode.block[index];
            return if (blk == 0) null else blk;
        }
        const ptrs = self.block_size / 4;
        const single_base = inode_direct_blocks;
        const double_base = single_base + ptrs;
        const triple_base = double_base + ptrs * ptrs;
        if (index < double_base) return self.indirectDataBlock(&inode, inode_single_indirect, index - single_base);
        if (index < triple_base) return self.indirectDataBlock(&inode, inode_double_indirect, index - double_base);
        if (index < triple_base + ptrs * ptrs * ptrs) return self.indirectDataBlock(&inode, inode_triple_indirect, index - triple_base);
        return Ext2Error.UnsupportedIndirect;
    }

    /// Resolve `index` (a pointer offset within an indirect chain rooted at
    /// inode slot `slot`) to a data-block number. `slot` picks the chain
    /// depth: 12 = single, 13 = double, 14 = triple indirect. A zero pointer
    /// anywhere in the chain is a hole -> null.
    fn indirectDataBlock(self: Ext2, inode: *const Inode, slot: usize, index: usize) Ext2Error!?u32 {
        const ptrs = self.block_size / 4;
        const root = inode.block[slot];
        if (root == 0) return null;
        var buf: [4096]u8 = undefined;

        if (slot == inode_single_indirect) {
            try self.readBlock(root, buf[0..self.block_size]);
            const blk = bytes.readU32(&buf, index * 4);
            return if (blk == 0) null else blk;
        }

        if (slot == inode_double_indirect) {
            try self.readBlock(root, buf[0..self.block_size]);
            const l1 = bytes.readU32(&buf, (index / ptrs) * 4);
            if (l1 == 0) return null;
            try self.readBlock(l1, buf[0..self.block_size]);
            const blk = bytes.readU32(&buf, (index % ptrs) * 4);
            return if (blk == 0) null else blk;
        }

        // Triple indirect: root -> double -> single -> data.
        try self.readBlock(root, buf[0..self.block_size]);
        const l1 = bytes.readU32(&buf, (index / (ptrs * ptrs)) * 4);
        if (l1 == 0) return null;
        try self.readBlock(l1, buf[0..self.block_size]);
        const l2 = bytes.readU32(&buf, ((index / ptrs) % ptrs) * 4);
        if (l2 == 0) return null;
        try self.readBlock(l2, buf[0..self.block_size]);
        const blk = bytes.readU32(&buf, (index % ptrs) * 4);
        return if (blk == 0) null else blk;
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

    /// Resolve logical block `index`, allocating it (and the direct block
    /// pointer or indirect chain when needed) if it does not exist yet.
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
        const ptrs = self.block_size / 4;
        const single_base = inode_direct_blocks;
        const double_base = single_base + ptrs;
        const triple_base = double_base + ptrs * ptrs;
        if (index < double_base) return self.ensureIndirect(inode, inode_single_indirect, index - single_base, 1);
        if (index < triple_base) return self.ensureIndirect(inode, inode_double_indirect, index - double_base, 2);
        if (index < triple_base + ptrs * ptrs * ptrs) return self.ensureIndirect(inode, inode_triple_indirect, index - triple_base, 3);
        return Ext2Error.UnsupportedIndirect;
    }

    /// Ensure the data block for pointer offset `index` within an indirect
    /// chain of `levels` blocks rooted at inode slot `slot` exists, allocating
    /// each missing level (zeroed) and the data block. Every modified indirect
    /// block is written back; the inode's root pointer is updated when the
    /// chain root is allocated. Returns the data-block number.
    fn ensureIndirect(self: *Ext2, inode: *Inode, slot: usize, index: usize, levels: usize) Ext2Error!u32 {
        const ptrs = self.block_size / 4;
        if (inode.block[slot] == 0) {
            inode.block[slot] = try self.allocBlock();
            var zero: [4096]u8 = undefined;
            @memset(&zero, 0);
            try self.writeBlock(inode.block[slot], zero[0..self.block_size]);
        }

        var cur_block = inode.block[slot];
        var cur_index = index;
        var cur_levels = levels;
        while (cur_levels > 1) {
            const divisor = std.math.pow(usize, ptrs, cur_levels - 1);
            const first = cur_index / divisor;
            cur_index %= divisor;
            var buf: [4096]u8 = undefined;
            try self.readBlock(cur_block, buf[0..self.block_size]);
            var next = bytes.readU32(&buf, first * 4);
            if (next == 0) {
                next = try self.allocBlock();
                var zero: [4096]u8 = undefined;
                @memset(&zero, 0);
                try self.writeBlock(next, zero[0..self.block_size]);
                try self.readBlock(cur_block, buf[0..self.block_size]);
                bytes.writeU32(&buf, first * 4, next);
                try self.writeBlock(cur_block, buf[0..self.block_size]);
            }
            cur_block = next;
            cur_levels -= 1;
        }

        // Leaf pointer table: allocate the data block if it is still a hole.
        var leaf: [4096]u8 = undefined;
        try self.readBlock(cur_block, leaf[0..self.block_size]);
        var blk = bytes.readU32(&leaf, cur_index * 4);
        if (blk == 0) {
            blk = try self.allocBlock();
            bytes.writeU32(&leaf, cur_index * 4, blk);
            try self.writeBlock(cur_block, leaf[0..self.block_size]);
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
        const groups_count = (@as(u64, self.super.blocks_count) - self.super.first_data_block + bpg - 1) / bpg;
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
        bytes.writeU16(&block_buf, off + 12, @intCast(@max(@as(i32, free) + delta, 0)));
        try self.writeBlock(gdt_block, block_buf[0..self.block_size]);

        var sb: [1024]u8 = undefined;
        try readDiskOffset(self.disk, superblock_offset, &sb);
        const sb_free = bytes.readU32(&sb, 12);
        bytes.writeU32(&sb, 12, @intCast(@max(@as(i64, sb_free) + delta, 0)));
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

    /// Delete the file at `path`: free its data blocks, free its inode, and
    /// remove its directory entry. Best-effort metadata like the existing
    /// write path (non-crash-safe, no journal); `dir_index` is unsupported so
    /// directory entries are scanned linearly.
    pub fn unlink(self: *Ext2, path: []const u8) Ext2Error!void {
        const parent_path = parentPath(path) orelse return Ext2Error.NotFound;
        const parent_ino = try self.find(parent_path);
        const name = lastComponent(path) orelse return Ext2Error.NotFound;
        const ino = (try self.lookupDir(parent_ino, name)) orelse return Ext2Error.NotFound;
        const inode = try self.readInode(ino);
        if (inode.mode & inode_type_dir != 0) return Ext2Error.NotAFile;

        try self.freeBlocks(inode);
        try self.freeInode(ino);
        try self.removeDirEntry(parent_ino, ino, name);
    }

    /// Create a regular file at `path` and return its inode. The parent
    /// directory must exist and have room in its first block (the same
    /// single-block-directory limitation as readDir/removeDirEntry). A fresh
    /// inode is allocated, initialized and linked into the parent. Like the
    /// rest of the write path the operation is non-crash-safe best-effort
    /// (ADR-023): if the directory link fails the inode stays allocated but
    /// unreferenced (no rollback, matching unlink's style).
    pub fn create(self: *Ext2, path: []const u8) Ext2Error!u32 {
        const parent_path = parentPath(path) orelse return Ext2Error.NotFound;
        const parent_ino = try self.find(parent_path);
        const name = lastComponent(path) orelse return Ext2Error.NotFound;
        const existing = self.find(path) catch |err| switch (err) {
            error.NotFound => null,
            else => return err,
        };
        if (existing != null) return Ext2Error.FileExists;
        const ino = try self.allocInode();
        try self.initInode(ino, inode_type_reg);
        try self.addDirEntry(parent_ino, ino, name, 1);
        return ino;
    }

    /// Rename `old_path` to `new_path` on the same filesystem: relink the
    /// existing inode under the new name and drop the old directory entry —
    /// no data copy, the inode and its blocks stay put. Works for regular
    /// files and directories. Non-crash-safe best-effort like create/unlink
    /// (no journal, ADR-023): the new entry is written first so a failure
    /// leaves the old name intact; the target path must not already exist.
    /// `removeDirEntry` matches the entry by inode *and* name, so the old
    /// entry is dropped even when a rename links the same inode twice in one
    /// directory.
    pub fn rename(self: *Ext2, old_path: []const u8, new_path: []const u8) Ext2Error!void {
        const old_parent_path = parentPath(old_path) orelse return Ext2Error.NotFound;
        const old_parent = try self.find(old_parent_path);
        const old_name = lastComponent(old_path) orelse return Ext2Error.NotFound;
        const ino = (try self.lookupDir(old_parent, old_name)) orelse return Ext2Error.NotFound;
        const inode = try self.readInode(ino);

        const new_parent_path = parentPath(new_path) orelse return Ext2Error.NotFound;
        const new_parent = try self.find(new_parent_path);
        const new_name = lastComponent(new_path) orelse return Ext2Error.NotFound;
        if (new_name.len > 255) return Ext2Error.NameTooLong;
        const existing = self.find(new_path) catch |err| switch (err) {
            error.NotFound => null,
            else => return err,
        };
        if (existing != null) return Ext2Error.FileExists;

        const file_type: u8 = if (inode.mode & inode_type_dir != 0) 2 else 1;
        try self.addDirEntry(new_parent, ino, new_name, file_type);
        try self.removeDirEntry(old_parent, ino, old_name);
    }

    /// Free every block of `inode` (direct + the single/double/triple indirect
    /// chains): the data blocks at the leaves plus each intermediate pointer
    /// block. A zero pointer anywhere is a hole — nothing to free.
    fn freeBlocks(self: *Ext2, inode: Inode) Ext2Error!void {
        var index: usize = 0;
        while (index < inode_direct_blocks) : (index += 1) {
            if (inode.block[index] != 0) try self.freeBlock(inode.block[index]);
        }
        if (inode.block[inode_single_indirect] != 0) try self.freeIndirectBlocks(inode.block[inode_single_indirect], 1);
        if (inode.block[inode_double_indirect] != 0) try self.freeIndirectBlocks(inode.block[inode_double_indirect], 2);
        if (inode.block[inode_triple_indirect] != 0) try self.freeIndirectBlocks(inode.block[inode_triple_indirect], 3);
    }

    /// Free every block reachable through an indirect chain of `levels` blocks
    /// rooted at `block_num` (level 1 = the block is the leaf pointer table).
    fn freeIndirectBlocks(self: *Ext2, block_num: u32, levels: usize) Ext2Error!void {
        const ptrs = self.block_size / 4;
        var buf: [4096]u8 = undefined;
        try self.readBlock(block_num, buf[0..self.block_size]);
        if (levels == 1) {
            var i: usize = 0;
            while (i < ptrs) : (i += 1) {
                const blk = bytes.readU32(&buf, i * 4);
                if (blk != 0) try self.freeBlock(blk);
            }
            try self.freeBlock(block_num);
            return;
        }
        var i: usize = 0;
        while (i < ptrs) : (i += 1) {
            const next = bytes.readU32(&buf, i * 4);
            if (next != 0) try self.freeIndirectBlocks(next, levels - 1);
        }
        try self.freeBlock(block_num);
    }

    /// Clear one block bit in its group's block bitmap and bump the free
    /// counts (inverse of allocBlock).
    fn freeBlock(self: *Ext2, block_num: u32) Ext2Error!void {
        if (block_num < self.super.first_data_block) return Ext2Error.OutOfBounds;
        const bpg = self.super.blocks_per_group;
        if (bpg == 0) return Ext2Error.CorruptSuperblock;
        const rel = @as(usize, block_num) - self.super.first_data_block;
        const group = rel / bpg;
        const idx_in_group = rel % bpg;
        const desc = try self.groupDescriptor(group);
        var bitmap_buf: [4096]u8 = undefined;
        try self.readBlock(desc.block_bitmap, bitmap_buf[0..self.block_size]);
        const byte = idx_in_group / 8;
        const mask: u8 = @as(u8, 1) << @intCast(idx_in_group % 8);
        bitmap_buf[byte] &= ~mask;
        try self.writeBlock(desc.block_bitmap, bitmap_buf[0..self.block_size]);
        try self.adjustFreeBlocks(group, 1);
    }

    /// Clear the inode bit and bump the free-inode count (inverse of
    /// inodeTableLocation/allocInode).
    fn freeInode(self: *Ext2, ino: u32) Ext2Error!void {
        if (ino == 0 or ino > self.super.inodes_count) return Ext2Error.NotFound;
        const index = ino - 1;
        const group = index / self.super.inodes_per_group;
        const idx_in_group = index % self.super.inodes_per_group;
        const desc = try self.groupDescriptor(group);
        var bitmap_buf: [4096]u8 = undefined;
        try self.readBlock(desc.inode_bitmap, bitmap_buf[0..self.block_size]);
        const byte = idx_in_group / 8;
        const mask: u8 = @as(u8, 1) << @intCast(idx_in_group % 8);
        bitmap_buf[byte] &= ~mask;
        try self.writeBlock(desc.inode_bitmap, bitmap_buf[0..self.block_size]);
        try self.adjustFreeInodes(group, 1);
    }

    /// Allocate one free inode: scan the inode bitmap of each group for a
    /// clear bit, set it, and decrement the group + superblock free counts.
    /// Reserved inodes below `first_ino` (superblock offset 84) are skipped,
    /// and the last group is capped at `inodes_count` (its bitmap may cover
    /// inodes that do not exist).
    fn allocInode(self: *Ext2) Ext2Error!u32 {
        const ipg = self.super.inodes_per_group;
        if (ipg == 0) return Ext2Error.CorruptSuperblock;
        const groups_count = (@as(u64, self.super.inodes_count) + ipg - 1) / ipg;
        const reserved = @as(u64, self.super.first_ino) - 1;
        var g: u64 = 0;
        while (g < groups_count) : (g += 1) {
            const group_start = g * ipg;
            const inodes_in_group: usize = @intCast(@min(@as(u64, ipg), @as(u64, self.super.inodes_count) - group_start));
            // The reserved inodes (below first_ino) span the start of the
            // inode space; skip them wherever they fall.
            const start: usize = if (group_start < reserved)
                @intCast(@min(@as(u64, ipg), reserved - group_start))
            else
                0;
            const desc = try self.groupDescriptor(@intCast(g));
            var bitmap_buf: [4096]u8 = undefined;
            try self.readBlock(desc.inode_bitmap, bitmap_buf[0..self.block_size]);
            var i: usize = start;
            while (i < inodes_in_group) : (i += 1) {
                const byte = i / 8;
                const mask: u8 = @as(u8, 1) << @intCast(i % 8);
                if (bitmap_buf[byte] & mask == 0) {
                    bitmap_buf[byte] |= mask;
                    try self.writeBlock(desc.inode_bitmap, bitmap_buf[0..self.block_size]);
                    try self.adjustFreeInodes(@intCast(g), -1);
                    return @intCast(group_start + i + 1);
                }
            }
        }
        return Ext2Error.OutOfSpace;
    }

    /// Remove `ino` from the directory listing of `dir_ino` by zeroing its
    /// entry's inode field (the entry stays as a dead record; readDir skips
    /// zero inodes). The entry is matched by inode *and* name so the old
    /// entry is dropped even when the same inode is linked twice (a rename
    /// that added a new entry first).
    fn removeDirEntry(self: *Ext2, dir_ino: u32, ino: u32, name: []const u8) Ext2Error!void {
        const inode = try self.readInode(dir_ino);
        if (inode.mode & inode_type_dir == 0) return Ext2Error.NotADirectory;
        var block_buf: [4096]u8 = undefined;
        try self.readBlock(inode.block[0], block_buf[0..self.block_size]);
        const data = block_buf[0..self.block_size];
        var off: usize = 0;
        while (off + 8 <= data.len) {
            const entry_inode = bytes.readU32(data, off);
            const rec_len = bytes.readU16(data, off + 4);
            if (rec_len == 0) break;
            const entry_name_len = data[off + 6];
            const name_end = off + 8 + @as(usize, entry_name_len);
            if (name_end > data.len) return Ext2Error.OutOfBounds;
            if (entry_inode == ino and entry_name_len == name.len and
                std.mem.eql(u8, data[off + 8 .. name_end], name))
            {
                bytes.writeU32(&block_buf, off, 0);
                try self.writeBlock(inode.block[0], block_buf[0..self.block_size]);
                return;
            }
            off += rec_len;
        }
        return Ext2Error.NotFound;
    }

    /// Link a new entry into a single-block directory: reuse a dead slot
    /// (zero inode) that fits, otherwise shrink the last entry to its exact
    /// aligned size and append. Entries use the mke2fs rec_len alignment
    /// (4 bytes) so the block stays host-readable.
    fn addDirEntry(self: *Ext2, dir_ino: u32, ino: u32, name: []const u8, file_type: u8) Ext2Error!void {
        const inode = try self.readInode(dir_ino);
        if (inode.mode & inode_type_dir == 0) return Ext2Error.NotADirectory;
        if (name.len > 255) return Ext2Error.NameTooLong;
        const needed = (8 + name.len + 3) & ~@as(usize, 3);
        var block_buf: [4096]u8 = undefined;
        try self.readBlock(inode.block[0], block_buf[0..self.block_size]);
        const data = block_buf[0..self.block_size];
        var off: usize = 0;
        var last_off: usize = 0;
        while (off + 8 <= data.len) {
            const rec_len = bytes.readU16(data, off + 4);
            if (rec_len == 0) break;
            if (bytes.readU32(data, off) == 0 and rec_len >= needed) {
                self.writeDirEntry(&block_buf, off, ino, name, file_type, rec_len);
                try self.writeBlock(inode.block[0], block_buf[0..self.block_size]);
                return;
            }
            last_off = off;
            off += rec_len;
        }
        if (off == 0) {
            self.writeDirEntry(&block_buf, 0, ino, name, file_type, self.block_size);
            try self.writeBlock(inode.block[0], block_buf[0..self.block_size]);
            return;
        }
        // Shrink the last entry to its exact size and append after it; the
        // last entry's rec_len covers the rest of the block (mke2fs fills the
        // final entry to the block end), so splitting it frees the room.
        const last_exact = (8 + data[last_off + 6] + 3) & ~@as(usize, 3);
        const append_at = last_off + last_exact;
        if (append_at + needed > self.block_size) return Ext2Error.OutOfSpace;
        bytes.writeU16(&block_buf, last_off + 4, @intCast(last_exact));
        self.writeDirEntry(&block_buf, append_at, ino, name, file_type, self.block_size - append_at);
        try self.writeBlock(inode.block[0], block_buf[0..self.block_size]);
    }

    fn writeDirEntry(self: *Ext2, block_buf: *[4096]u8, off: usize, ino: u32, name: []const u8, file_type: u8, rec_len: usize) void {
        const data = block_buf[0..self.block_size];
        bytes.writeU32(block_buf, off, ino);
        bytes.writeU16(block_buf, off + 4, @intCast(rec_len));
        data[off + 6] = @intCast(name.len);
        data[off + 7] = file_type;
        @memcpy(data[off + 8 .. off + 8 + name.len], name);
    }

    /// Increment the free-inode count in the group descriptor and superblock.
    fn adjustFreeInodes(self: Ext2, group: usize, delta: i32) Ext2Error!void {
        const groups_per_block: usize = self.block_size / 32;
        const gdt_block: u32 = @intCast(superblock_offset / self.block_size + 1 + group / groups_per_block);
        const off: usize = (group % groups_per_block) * 32;
        var block_buf: [4096]u8 = undefined;
        try self.readBlock(gdt_block, block_buf[0..self.block_size]);
        const free = bytes.readU16(&block_buf, off + 14);
        bytes.writeU16(&block_buf, off + 14, @intCast(@as(i32, free) + delta));
        try self.writeBlock(gdt_block, block_buf[0..self.block_size]);

        var sb: [1024]u8 = undefined;
        try readDiskOffset(self.disk, superblock_offset, &sb);
        const sb_free = bytes.readU32(&sb, 16);
        bytes.writeU32(&sb, 16, @intCast(@as(i64, sb_free) + delta));
        try writeDiskOffset(self.disk, superblock_offset, &sb);
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
        const groups_count = (@as(u64, self.super.blocks_count) - self.super.first_data_block + self.super.blocks_per_group - 1) / self.super.blocks_per_group;
        if (@as(u64, group) >= groups_count) return Ext2Error.CorruptSuperblock;

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
        const block_bitmap = bytes.readU32(desc, 0);
        const inode_bitmap = bytes.readU32(desc, 4);
        const inode_table = bytes.readU32(desc, 8);
        // All three metadata pointers must point inside the filesystem; an
        // unchecked bitmap would let a crafted GDT write "bitmap" bits over
        // real metadata (audit 2026-08-15).
        if (block_bitmap >= self.super.blocks_count or
            inode_bitmap >= self.super.blocks_count or
            inode_table >= self.super.blocks_count) return Ext2Error.OutOfBounds;
        return .{
            .block_bitmap = block_bitmap,
            .inode_bitmap = inode_bitmap,
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

/// Directory path of `path` ("/a/b" -> "/a", "/a" -> "/", "/" -> null).
fn parentPath(path: []const u8) ?[]const u8 {
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return null;
    var slash = path.len;
    while (slash > 0 and path[slash - 1] == '/') slash -= 1;
    if (slash == 0) return null;
    var i = slash;
    while (i > 0 and path[i - 1] != '/') i -= 1;
    if (i == 0) return "/";
    return path[0 .. i - 1];
}

/// Last path component ("/a/b" -> "b", "/a" -> "a", "/" -> null).
fn lastComponent(path: []const u8) ?[]const u8 {
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return null;
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    if (end == 0) return null;
    var start = end;
    while (start > 0 and path[start - 1] != '/') start -= 1;
    return path[start..end];
}
