const std = @import("std");
const ext2 = @import("ext2.zig");

/// Thin Aster File API (spec/roadmap.md M6.1.4, ADR-023): `open` / `read` /
/// `write` / `close` over an opaque backend reference. The caller never sees
/// inode numbers, uid/gid, mode bits, ACLs or ext2 metadata — the backend is a
/// replaceable detail (ext2 today, tar/initfs and others later). Write support
/// (M7.1.4) requires a mutable backend.
pub const File = struct {
    backend: *ext2.Ext2,
    ino: u32,
    offset: usize,
    file_size: u64,

    /// Open a regular file by absolute path.
    pub fn open(backend: *ext2.Ext2, path: []const u8) ext2.Ext2Error!File {
        const ino = try backend.find(path);
        const inode = try backend.readInode(ino);
        if (inode.mode & ext2.inode_type_reg == 0) return ext2.Ext2Error.NotAFile;
        return .{
            .backend = backend,
            .ino = ino,
            .offset = 0,
            .file_size = inode.size_lo,
        };
    }

    /// Read up to `out.len` bytes from the current offset; advances the
    /// offset. Returns 0 at end of file.
    pub fn read(self: *File, out: []u8) ext2.Ext2Error!usize {
        const n = try self.backend.readAt(self.ino, self.offset, out);
        self.offset += n;
        return n;
    }

    /// Write `data` at the current offset; advances the offset and grows the
    /// file size (block allocation) as needed (M7.1.4).
    pub fn write(self: *File, data: []const u8) ext2.Ext2Error!void {
        try self.backend.writeAt(self.ino, self.offset, data);
        self.offset += data.len;
        if (self.offset > self.file_size) self.file_size = self.offset;
    }

    /// Set the file size. Shrinking drops the tail; used before a rewrite to
    /// replace a file's content (M7.1.4).
    pub fn truncate(self: *File, new_size: usize) ext2.Ext2Error!void {
        try self.backend.truncate(self.ino, new_size);
        self.file_size = new_size;
        if (self.offset > new_size) self.offset = new_size;
    }

    pub fn close(self: *File) void {
        _ = self;
    }

    pub fn fileSize(self: *const File) u64 {
        return self.file_size;
    }

    pub fn eof(self: *const File) bool {
        return self.offset >= self.file_size;
    }
};
