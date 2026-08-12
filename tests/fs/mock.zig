const std = @import("std");
const block = @import("kernel").block;

/// In-memory block device for host tests: every sector read comes from the
/// backing `data` slice; writes land back in it. The mock must outlive the
/// BlockDevice that points at it.
pub const MockDisk = struct {
    data: []u8,

    pub fn read(ctx: *anyopaque, sector: u64, out: []u8) block.BlockError!void {
        const self: *MockDisk = @ptrCast(@alignCast(ctx));
        const off = @as(usize, sector) * 512;
        if (off + out.len > self.data.len) return error.OutOfBounds;
        @memcpy(out, self.data[off .. off + out.len]);
    }

    pub fn write(ctx: *anyopaque, sector: u64, in: []const u8) block.BlockError!void {
        const self: *MockDisk = @ptrCast(@alignCast(ctx));
        const off = @as(usize, sector) * 512;
        if (off + in.len > self.data.len) return error.OutOfBounds;
        @memcpy(self.data[off .. off + in.len], in);
    }
};
