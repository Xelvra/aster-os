const std = @import("std");
const bytes = @import("bytes.zig");
const block = @import("../drivers/block.zig");

pub const GptError = error{
    TooShort,
    BadSignature,
    BadRevision,
    BadHeaderCrc,
    BadEntryArrayCrc,
    BadEntrySize,
    BufferTooSmall,
};

pub const DiscoveryError = GptError || error{ OutOfMemory, IoError, OutOfBounds };

pub const header_signature = "EFI PART";
pub const header_min_size: usize = 92;
pub const entry_size_default: u32 = 128;

/// Linux filesystem partition type GUID (0FC63DAF-8483-4772-8E79-3D69D8477DE4),
/// stored in the GPT on-disk (mixed-endian) byte order.
pub const type_guid_linux_fs = [16]u8{
    0xaf, 0x3d, 0xc6, 0x0f, 0x83, 0x84, 0x72, 0x47,
    0x8e, 0x79, 0x3d, 0x69, 0xd8, 0x47, 0x7d, 0xe4,
};

pub const PartitionEntry = struct {
    type_guid: [16]u8,
    unique_guid: [16]u8,
    first_lba: u64,
    last_lba: u64,
    attributes: u64,
    name: [36]u16,
};

pub const GptHeader = struct {
    current_lba: u64,
    backup_lba: u64,
    first_usable_lba: u64,
    last_usable_lba: u64,
    disk_guid: [16]u8,
    partition_entry_lba: u64,
    num_entries: u32,
    entry_size: u32,
    entry_array_crc32: u32,
};

/// Parse and validate the GPT header (LBA 1, typically a 512-byte sector).
/// Pure function over the raw bytes — no allocation, no I/O.
pub fn parseHeader(buf: []const u8) GptError!GptHeader {
    if (buf.len < header_min_size) return GptError.TooShort;
    if (!std.mem.eql(u8, buf[0..8], header_signature)) return GptError.BadSignature;
    if (bytes.readU32(buf, 8) != 0x00010000) return GptError.BadRevision;
    const header_size = bytes.readU32(buf, 12);
    if (header_size < header_min_size or @as(usize, header_size) > buf.len) return GptError.TooShort;
    const stored_crc = bytes.readU32(buf, 16);
    var crc = std.hash.crc.Crc32IsoHdlc.init();
    crc.update(buf[0..16]);
    crc.update(&[4]u8{ 0, 0, 0, 0 });
    crc.update(buf[20..header_size]);
    if (crc.final() != stored_crc) return GptError.BadHeaderCrc;
    return .{
        .current_lba = bytes.readU64(buf, 24),
        .backup_lba = bytes.readU64(buf, 32),
        .first_usable_lba = bytes.readU64(buf, 40),
        .last_usable_lba = bytes.readU64(buf, 48),
        .disk_guid = readGuid(buf, 56),
        .partition_entry_lba = bytes.readU64(buf, 72),
        .num_entries = bytes.readU32(buf, 80),
        .entry_size = bytes.readU32(buf, 84),
        .entry_array_crc32 = bytes.readU32(buf, 88),
    };
}

/// Parse the partition entry array into `out`. Validates the entry array CRC;
/// stops at the first unused (zero type GUID) entry. Returns the number of
/// partitions written. Pure function — no allocation, no I/O.
pub fn parseEntries(buf: []const u8, header: GptHeader, out: []PartitionEntry) GptError!usize {
    if (header.entry_size < entry_size_default) return GptError.BadEntrySize;
    const entry_size = @as(usize, header.entry_size);
    const array_bytes = @as(usize, header.num_entries) * entry_size;
    if (array_bytes > buf.len) return GptError.TooShort;
    if (std.hash.crc.Crc32IsoHdlc.hash(buf[0..array_bytes]) != header.entry_array_crc32)
        return GptError.BadEntryArrayCrc;

    var count: usize = 0;
    var i: usize = 0;
    while (i < header.num_entries) : (i += 1) {
        if (count == out.len) return GptError.BufferTooSmall;
        const entry = buf[i * entry_size .. i * entry_size + entry_size];
        if (allZero(entry[0..16])) break;
        var type_guid: [16]u8 = undefined;
        var unique_guid: [16]u8 = undefined;
        for (0..16) |j| {
            type_guid[j] = entry[j];
            unique_guid[j] = entry[16 + j];
        }
        out[count] = .{
            .type_guid = type_guid,
            .unique_guid = unique_guid,
            .first_lba = bytes.readU64(entry, 32),
            .last_lba = bytes.readU64(entry, 40),
            .attributes = bytes.readU64(entry, 48),
            .name = readName(entry[56..128]),
        };
        count += 1;
    }
    return count;
}

pub fn eqlGuid(a: [16]u8, b: [16]u8) bool {
    return std.mem.eql(u8, &a, &b);
}

/// Read the primary GPT (header on LBA 1 + the partition entry array) from a
/// block device and return the partitions as block-device views
/// (spec/roadmap.md M6.1.2). The entry array is heap-allocated for the read.
pub fn discover(alloc: std.mem.Allocator, disk: block.BlockDevice, out: []block.PartitionView) DiscoveryError!usize {
    var header_sector: [512]u8 = undefined;
    try disk.read(1, &header_sector);
    const header = try parseHeader(&header_sector);
    const entry_size = @as(usize, header.entry_size);
    const array_bytes = @as(usize, header.num_entries) * entry_size;
    const buf = try alloc.alloc(u8, array_bytes);
    defer alloc.free(buf);
    try readDiskBytes(disk, header.partition_entry_lba, buf);

    var entries: [256]PartitionEntry = undefined;
    const count = try parseEntries(buf, header, &entries);
    var written: usize = 0;
    for (entries[0..count]) |e| {
        if (written == out.len) return GptError.BufferTooSmall;
        out[written] = .{
            .disk = disk,
            .first_lba = e.first_lba,
            .last_lba = e.last_lba,
        };
        written += 1;
    }
    return written;
}

fn readDiskBytes(disk: block.BlockDevice, start_lba: u64, out: []u8) DiscoveryError!void {
    var offset: usize = 0;
    var lba = start_lba;
    while (offset < out.len) : (lba += 1) {
        var sector_buf: [512]u8 = undefined;
        try disk.read(lba, &sector_buf);
        const n = @min(@as(usize, 512), out.len - offset);
        @memcpy(out[offset .. offset + n], sector_buf[0..n]);
        offset += n;
    }
}

fn readGuid(buf: []const u8, off: usize) [16]u8 {
    var out: [16]u8 = undefined;
    for (0..16) |i| out[i] = buf[off + i];
    return out;
}

fn readName(raw: []const u8) [36]u16 {
    var out: [36]u16 = undefined;
    for (0..36) |i| out[i] = bytes.readU16(raw, i * 2);
    return out;
}

fn allZero(slice: []const u8) bool {
    for (slice) |b| if (b != 0) return false;
    return true;
}
