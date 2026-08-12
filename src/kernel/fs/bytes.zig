/// Little-endian reads shared by the on-disk format parsers (gpt.zig,
/// ext2.zig). Pure helpers over `[]const u8` — no allocation, no I/O.
pub fn readU16(buf: []const u8, off: usize) u16 {
    return @as(u16, buf[off]) | (@as(u16, buf[off + 1]) << 8);
}

pub fn readU32(buf: []const u8, off: usize) u32 {
    return @as(u32, buf[off]) |
        (@as(u32, buf[off + 1]) << 8) |
        (@as(u32, buf[off + 2]) << 16) |
        (@as(u32, buf[off + 3]) << 24);
}

pub fn readU64(buf: []const u8, off: usize) u64 {
    return @as(u64, buf[off]) |
        (@as(u64, buf[off + 1]) << 8) |
        (@as(u64, buf[off + 2]) << 16) |
        (@as(u64, buf[off + 3]) << 24) |
        (@as(u64, buf[off + 4]) << 32) |
        (@as(u64, buf[off + 5]) << 40) |
        (@as(u64, buf[off + 6]) << 48) |
        (@as(u64, buf[off + 7]) << 56);
}

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
