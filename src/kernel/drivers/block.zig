/// Block-device interface. The filesystem layer (gpt.zig, ext2.zig) depends
/// on this thin interface, not on a concrete driver (spec/roadmap.md M6.1.1).
pub const BlockError = error{ IoError, OutOfBounds };

pub const BlockDevice = struct {
    read_fn: *const fn (ctx: *anyopaque, sector: u64, out: []u8) BlockError!void,
    ctx: *anyopaque,

    /// Read one 512-byte sector (sector 0 = first sector of the device).
    pub fn read(self: BlockDevice, sector: u64, out: []u8) BlockError!void {
        return self.read_fn(self.ctx, sector, out);
    }
};

/// A partition expressed as a block-device view: sector `i` of the view is
/// sector `first_lba + i` of the disk (spec/roadmap.md M6.1.2).
pub const PartitionView = struct {
    disk: BlockDevice,
    first_lba: u64,
    last_lba: u64,

    /// Read a 512-byte sector by partition-local index.
    pub fn readSector(self: PartitionView, index: u64, out: []u8) BlockError!void {
        if (index > self.last_lba - self.first_lba) return error.OutOfBounds;
        return self.disk.read(self.first_lba + index, out);
    }
};
