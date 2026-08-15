const std = @import("std");
const gpt = @import("kernel").gpt;
const block = @import("kernel").block;

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

fn writeU64(buf: []u8, off: usize, v: u64) void {
    writeU32(buf, off, @truncate(v));
    writeU32(buf, off + 4, @truncate(v >> 32));
}

const TestGpt = struct {
    header: [512]u8,
    entries: [256]u8,

    fn build() TestGpt {
        var self = TestGpt{ .header = [_]u8{0} ** 512, .entries = [_]u8{0} ** 256 };
        @memcpy(self.header[0..8], "EFI PART");
        writeU32(&self.header, 8, 0x00010000);
        writeU32(&self.header, 12, 92);
        writeU64(&self.header, 24, 1);
        writeU64(&self.header, 32, 3);
        writeU64(&self.header, 40, 34);
        writeU64(&self.header, 48, 100);
        writeU64(&self.header, 72, 2);
        writeU32(&self.header, 80, 2);
        writeU32(&self.header, 84, 128);
        return self;
    }

    fn finalize(self: *TestGpt) void {
        const array_crc = std.hash.crc.Crc32IsoHdlc.hash(self.entries[0 .. 2 * 128]);
        writeU32(&self.header, 88, array_crc);
        var crc = std.hash.crc.Crc32IsoHdlc.init();
        crc.update(self.header[0..16]);
        crc.update(&[4]u8{ 0, 0, 0, 0 });
        crc.update(self.header[20..92]);
        writeU32(&self.header, 16, crc.final());
    }

    fn putEntry(self: *TestGpt, index: usize, type_guid: [16]u8, first_lba: u64, last_lba: u64, name: []const u16) void {
        const off = index * 128;
        @memcpy(self.entries[off .. off + 16], &type_guid);
        writeU64(&self.entries, off + 32, first_lba);
        writeU64(&self.entries, off + 40, last_lba);
        for (name, 0..) |c, i| writeU16(&self.entries, off + 56 + i * 2, c);
    }
};

test "parseHeader accepts a valid GPT header" {
    var gpt_data = TestGpt.build();
    gpt_data.finalize();
    const header = try gpt.parseHeader(&gpt_data.header);
    try std.testing.expectEqual(@as(u64, 1), header.current_lba);
    try std.testing.expectEqual(@as(u64, 3), header.backup_lba);
    try std.testing.expectEqual(@as(u64, 34), header.first_usable_lba);
    try std.testing.expectEqual(@as(u64, 100), header.last_usable_lba);
    try std.testing.expectEqual(@as(u64, 2), header.partition_entry_lba);
    try std.testing.expectEqual(@as(u32, 2), header.num_entries);
    try std.testing.expectEqual(@as(u32, 128), header.entry_size);
}

test "parseHeader rejects a wrong signature" {
    var gpt_data = TestGpt.build();
    gpt_data.finalize();
    gpt_data.header[0] = 'X';
    try std.testing.expectError(gpt.GptError.BadSignature, gpt.parseHeader(&gpt_data.header));
}

test "parseHeader rejects a wrong revision" {
    var gpt_data = TestGpt.build();
    gpt_data.finalize();
    std.mem.writeInt(u32, gpt_data.header[8..12], 0x00010001, .little);
    try std.testing.expectError(gpt.GptError.BadRevision, gpt.parseHeader(&gpt_data.header));
}

test "parseHeader rejects a corrupt header CRC" {
    var gpt_data = TestGpt.build();
    gpt_data.finalize();
    gpt_data.header[24] ^= 0xFF;
    try std.testing.expectError(gpt.GptError.BadHeaderCrc, gpt.parseHeader(&gpt_data.header));
}

test "parseHeader rejects a buffer that is too short" {
    var gpt_data = TestGpt.build();
    try std.testing.expectError(gpt.GptError.TooShort, gpt.parseHeader(gpt_data.header[0..10]));
}

test "parseEntries returns partitions in order" {
    var gpt_data = TestGpt.build();
    gpt_data.putEntry(0, gpt.type_guid_linux_fs, 2048, 4095, &[_]u16{ 'b', 'o', 'o', 't' });
    gpt_data.putEntry(1, gpt.type_guid_linux_fs, 4096, 8191, &[_]u16{ 'r', 'o', 'o', 't' });
    gpt_data.finalize();
    const header = try gpt.parseHeader(&gpt_data.header);
    var out: [4]gpt.PartitionEntry = undefined;
    const count = try gpt.parseEntries(&gpt_data.entries, header, &out);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u64, 2048), out[0].first_lba);
    try std.testing.expectEqual(@as(u64, 4095), out[0].last_lba);
    try std.testing.expectEqual(@as(u64, 4096), out[1].first_lba);
    try std.testing.expect(gpt.eqlGuid(out[0].type_guid, gpt.type_guid_linux_fs));
    try std.testing.expectEqual(@as(u16, 'b'), out[0].name[0]);
    try std.testing.expectEqual(@as(u16, 't'), out[0].name[3]);
}

test "parseEntries stops at the first unused entry" {
    var gpt_data = TestGpt.build();
    gpt_data.putEntry(0, gpt.type_guid_linux_fs, 2048, 4095, &[_]u16{ 'b', 'o', 'o', 't' });
    gpt_data.finalize();
    const header = try gpt.parseHeader(&gpt_data.header);
    var out: [4]gpt.PartitionEntry = undefined;
    const count = try gpt.parseEntries(&gpt_data.entries, header, &out);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "parseEntries rejects a corrupt entry array CRC" {
    var gpt_data = TestGpt.build();
    gpt_data.putEntry(0, gpt.type_guid_linux_fs, 2048, 4095, &[_]u16{ 'b', 'o', 'o', 't' });
    gpt_data.finalize();
    gpt_data.entries[40] ^= 0xFF;
    const header = try gpt.parseHeader(&gpt_data.header);
    var out: [4]gpt.PartitionEntry = undefined;
    try std.testing.expectError(gpt.GptError.BadEntryArrayCrc, gpt.parseEntries(&gpt_data.entries, header, &out));
}

test "parseEntries reports a too-small output buffer" {
    var gpt_data = TestGpt.build();
    gpt_data.putEntry(0, gpt.type_guid_linux_fs, 2048, 4095, &[_]u16{ 'b', 'o', 'o', 't' });
    gpt_data.putEntry(1, gpt.type_guid_linux_fs, 4096, 8191, &[_]u16{ 'r', 'o', 'o', 't' });
    gpt_data.finalize();
    const header = try gpt.parseHeader(&gpt_data.header);
    var out: [1]gpt.PartitionEntry = undefined;
    try std.testing.expectError(gpt.GptError.BufferTooSmall, gpt.parseEntries(&gpt_data.entries, header, &out));
}

test "type_guid_linux_fs matches the on-disk byte order" {
    // 0FC63DAF-8483-4772-8E79-3D69D8477DE4 in mixed-endian disk order.
    const expected = [16]u8{ 0xaf, 0x3d, 0xc6, 0x0f, 0x83, 0x84, 0x72, 0x47, 0x8e, 0x79, 0x3d, 0x69, 0xd8, 0x47, 0x7d, 0xe4 };
    try std.testing.expect(gpt.eqlGuid(gpt.type_guid_linux_fs, expected));
}

const MockDisk = struct {
    data: []u8,

    fn read(ctx: *anyopaque, sector: u64, out: []u8) block.BlockError!void {
        const self: *MockDisk = @ptrCast(@alignCast(ctx));
        const off = @as(usize, sector) * 512;
        if (off + out.len > self.data.len) return error.OutOfBounds;
        @memcpy(out, self.data[off .. off + out.len]);
    }

    fn write(ctx: *anyopaque, sector: u64, in: []const u8) block.BlockError!void {
        const self: *MockDisk = @ptrCast(@alignCast(ctx));
        const off = @as(usize, sector) * 512;
        if (off + in.len > self.data.len) return error.OutOfBounds;
        @memcpy(self.data[off .. off + in.len], in);
    }
};

/// Build a mock disk image: sector 0 empty, sector 1 = GPT header, sector 2
/// = partition entry array (256 B used), with one partition [first_lba..last_lba]
/// inside the usable area (TestGpt: 34..100).
fn buildMockDisk(first_lba: u64, last_lba: u64) [64 * 512]u8 {
    var disk = [_]u8{0} ** (64 * 512);
    var gpt_data = TestGpt.build();
    gpt_data.putEntry(0, gpt.type_guid_linux_fs, first_lba, last_lba, &[_]u16{ 'p', 'a', 'r', 't' });
    gpt_data.finalize();
    @memcpy(disk[512..1024], &gpt_data.header);
    @memcpy(disk[1024..1280], gpt_data.entries[0..256]);
    return disk;
}

test "discover finds partitions as block-device views" {
    var disk_data = buildMockDisk(40, 90);
    @memcpy(disk_data[40 * 512 .. 40 * 512 + 4], "DATA");
    var mock = MockDisk{ .data = &disk_data };
    const dev = block.BlockDevice{ .ctx = &mock, .read_fn = MockDisk.read, .write_fn = MockDisk.write };
    var views: [4]block.PartitionView = undefined;
    const count = try gpt.discover(std.testing.allocator, dev, &views);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u64, 40), views[0].first_lba);
    try std.testing.expectEqual(@as(u64, 90), views[0].last_lba);
    try std.testing.expect(gpt.eqlGuid(views[0].type_guid, gpt.type_guid_linux_fs));
    var sector: [512]u8 = undefined;
    try views[0].readSector(0, &sector);
    try std.testing.expect(std.mem.eql(u8, "DATA", sector[0..4]));
}

test "discover rejects a disk without a GPT" {
    var disk_data = [_]u8{0} ** 2048;
    var mock = MockDisk{ .data = &disk_data };
    const dev = block.BlockDevice{ .ctx = &mock, .read_fn = MockDisk.read, .write_fn = MockDisk.write };
    var views: [4]block.PartitionView = undefined;
    try std.testing.expectError(gpt.GptError.BadSignature, gpt.discover(std.testing.allocator, dev, &views));
}

test "discover reports a too-small output buffer" {
    var disk_data = buildMockDisk(40, 41);
    var mock = MockDisk{ .data = &disk_data };
    const dev = block.BlockDevice{ .ctx = &mock, .read_fn = MockDisk.read, .write_fn = MockDisk.write };
    var views: [0]block.PartitionView = undefined;
    try std.testing.expectError(gpt.GptError.BufferTooSmall, gpt.discover(std.testing.allocator, dev, &views));
}

test "discover rejects an inverted partition LBA range" {
    var disk_data = buildMockDisk(90, 40); // first > last
    var mock = MockDisk{ .data = &disk_data };
    const dev = block.BlockDevice{ .ctx = &mock, .read_fn = MockDisk.read, .write_fn = MockDisk.write };
    var views: [4]block.PartitionView = undefined;
    try std.testing.expectError(error.OutOfBounds, gpt.discover(std.testing.allocator, dev, &views));
}
