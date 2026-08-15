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

    /// Create a regular file by absolute path and open it (empty content).
    pub fn create(backend: *ext2.Ext2, path: []const u8) ext2.Ext2Error!File {
        const ino = try backend.create(path);
        return .{
            .backend = backend,
            .ino = ino,
            .offset = 0,
            .file_size = 0,
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

    /// Delete a file by absolute path: frees its blocks and inode and removes
    /// the directory entry (M7.1.9).
    pub fn delete(backend: *ext2.Ext2, path: []const u8) ext2.Ext2Error!void {
        try backend.unlink(path);
    }

    /// Rename a file or directory by absolute path: relink its inode under the
    /// new name and drop the old directory entry (same inode, no data copy).
    pub fn rename(backend: *ext2.Ext2, old_path: []const u8, new_path: []const u8) ext2.Ext2Error!void {
        try backend.rename(old_path, new_path);
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
