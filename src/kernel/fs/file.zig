const std = @import("std");
const ext2 = @import("ext2.zig");

/// Thin Aster File API (spec/roadmap.md M6.1.4, ADR-023): `open` / `read` /
/// `close` over an opaque backend reference. The caller never sees inode
/// numbers, uid/gid, mode bits, ACLs or ext2 metadata — the backend is a
/// replaceable detail (ext2 today, tar/initfs and others later).
pub const File = struct {
    backend: *const ext2.Ext2,
    ino: u32,
    offset: usize,
    file_size: u64,

    /// Open a regular file by absolute path.
    pub fn open(backend: *const ext2.Ext2, path: []const u8) ext2.Ext2Error!File {
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
