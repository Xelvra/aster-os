const std = @import("std");

pub const TarError = error{
    NotFound,
    InvalidArchive,
};

/// Find a file in a tar archive (POSIX ustar). Returns a slice that points
/// into the archive itself — no copy. The archive is scanned 512-byte header
/// by header; a zero block ends the archive.
pub fn find(archive: []const u8, name: []const u8) TarError![]const u8 {
    var offset: usize = 0;
    while (offset + 512 <= archive.len) {
        const header = archive[offset .. offset + 512];
        if (allZero(header)) return TarError.NotFound;
        const entry_name = trimZero(header[0..100]);
        const size = readOctal(header[124..136]) catch return TarError.InvalidArchive;
        const data_start = offset + 512;
        if (data_start + size > archive.len) return TarError.InvalidArchive;
        const data = archive[data_start .. data_start + size];
        if (matchesName(entry_name, name)) return data;
        const padded = (size + 511) & ~@as(usize, 511);
        offset = data_start + padded;
    }
    return TarError.NotFound;
}

/// Compare an archive entry name against a requested name, ignoring a
/// leading "./" (GNU tar with `-C dir .` produces "./file").
fn matchesName(entry: []const u8, name: []const u8) bool {
    var e = entry;
    while (e.len > 0 and e[0] == '.') e = e[1..];
    while (e.len > 0 and e[0] == '/') e = e[1..];
    return std.mem.eql(u8, e, name);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |b| if (b != 0) return false;
    return true;
}

fn trimZero(bytes: []const u8) []const u8 {
    var len = bytes.len;
    while (len > 0 and bytes[len - 1] == 0) len -= 1;
    return bytes[0..len];
}

/// Parse an octal number from a fixed-size field (tar sizes are octal,
/// NUL/space terminated).
fn readOctal(bytes: []const u8) TarError!usize {
    var value: usize = 0;
    for (bytes) |c| {
        if (c == 0 or c == ' ') break;
        if (c < '0' or c > '7') return TarError.InvalidArchive;
        value = value * 8 + (c - '0');
    }
    return value;
}
