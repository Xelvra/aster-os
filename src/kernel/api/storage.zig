const sys = @import("sys.zig");
const file = @import("../fs/file.zig");
const ext2 = @import("../fs/ext2.zig");
const virtio = @import("../drivers/virtio.zig");

/// Persistent filesystem behind the thin File API (spec/roadmap.md M7.1.4).
/// The mounted backend and the block driver live here so they outlive the
/// boot-time probe, and the handle table lets Lua (or any KI client) keep
/// open files across syscalls. With no disk attached nothing is mounted and
/// every op reports NotFound.
///
/// Result convention: the upper 32 bits carry the KiStatus, the lower 32 the
/// value (a handle for `open`, the byte count for `read`, 0 otherwise). This
/// keeps byte counts and error codes unambiguous.
pub const StorageOp = enum(u64) {
    open = 0,
    read = 1,
    write = 2,
    close = 3,
    truncate = 4,
};

pub const ReadArgs = extern struct {
    handle: u64,
    buf: u64,
    len: u64,
};

pub const WriteArgs = extern struct {
    handle: u64,
    data: u64,
    len: u64,
};

/// Backing disk; only meaningful after a successful boot-time probe.
pub var disk: virtio.VirtioBlk = undefined;
/// The mounted filesystem; `null` when no disk is attached.
pub var mounted: ?ext2.Ext2 = null;

const handle_max = 8;
var handles: [handle_max]?file.File = .{null} ** handle_max;

const status_shift: u6 = 32;

fn ok(value: u64) u64 {
    return value & 0xFFFFFFFF;
}

fn fail(status: sys.KiStatus) u64 {
    return @as(u64, @intFromEnum(status)) << status_shift;
}

/// Adopt the filesystem probed at boot (main.zig probeStorage).
pub fn mount(fs: ext2.Ext2) void {
    mounted = fs;
}

pub fn isMounted() bool {
    return mounted != null;
}

fn handleSlot(id: u64) ?*?file.File {
    if (id == 0 or id > handle_max) return null;
    return &handles[@intCast(id - 1)];
}

fn errToStatus(err: ext2.Ext2Error) sys.KiStatus {
    return switch (err) {
        error.NotFound => .NotFound,
        error.NotAFile, error.NotADirectory => .InvalidArgument,
        error.IoError => .IoError,
        error.OutOfSpace => .NoMemory,
        else => .NotSupported,
    };
}

pub fn dispatch(args: sys.SyscallArgs) u64 {
    const fs_ptr: *ext2.Ext2 = if (mounted) |*fs| fs else return fail(.NotFound);
    const op: StorageOp = @enumFromInt(args.a);
    switch (op) {
        .open => {
            const path_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(args.b)));
            const path = path_ptr[0..@as(usize, @intCast(args.c))];
            for (&handles, 0..) |*slot, i| {
                if (slot.* == null) {
                    const f = file.File.open(fs_ptr, path) catch |err| return fail(errToStatus(err));
                    slot.* = f;
                    return ok(@intCast(i + 1));
                }
            }
            return fail(.Busy);
        },
        .read => {
            const ra: *const ReadArgs = @ptrFromInt(@as(usize, @intCast(args.b)));
            const slot = handleSlot(ra.handle) orelse return fail(.InvalidArgument);
            if (slot.* == null) return fail(.InvalidArgument);
            const f: *file.File = &slot.*.?;
            const buf: [*]u8 = @ptrFromInt(@as(usize, @intCast(ra.buf)));
            const n = f.read(buf[0..@as(usize, @intCast(ra.len))]) catch |err| return fail(errToStatus(err));
            return ok(@intCast(n));
        },
        .write => {
            const wa: *const WriteArgs = @ptrFromInt(@as(usize, @intCast(args.b)));
            const slot = handleSlot(wa.handle) orelse return fail(.InvalidArgument);
            if (slot.* == null) return fail(.InvalidArgument);
            const f: *file.File = &slot.*.?;
            const data: [*]const u8 = @ptrFromInt(@as(usize, @intCast(wa.data)));
            f.write(data[0..@as(usize, @intCast(wa.len))]) catch |err| return fail(errToStatus(err));
            return ok(0);
        },
        .close => {
            const slot = handleSlot(args.b) orelse return fail(.InvalidArgument);
            slot.* = null;
            return ok(0);
        },
        .truncate => {
            const slot = handleSlot(args.b) orelse return fail(.InvalidArgument);
            if (slot.* == null) return fail(.InvalidArgument);
            const f: *file.File = &slot.*.?;
            f.truncate(@as(usize, @intCast(args.c))) catch |err| return fail(errToStatus(err));
            return ok(0);
        },
    }
}
