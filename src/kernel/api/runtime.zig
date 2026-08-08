const std = @import("std");
const sys = @import("sys.zig");
const lua = @import("../lua/lua.zig");

pub const RuntimeKind = enum(u8) {
    Lua = 0,
    Wasm = 1,
    Native = 2,
};

pub const SpawnOptions = struct {
    kind: RuntimeKind,
    entry: []const u8,
    args: []const u8 = &.{},
};

pub const Program = struct {
    kind: RuntimeKind,
    handle: u64,
};

pub const RuntimeOp = enum(u64) {
    spawn = 0,
    kill = 1,
    status = 2,
    reload = 3,
};

var next_handle: u64 = 1;
var reload_requested = false;

pub fn init(allocator: std.mem.Allocator, initrd: ?[]const u8) void {
    lua.init(allocator);
    lua.setInitrd(initrd);
}

/// Re-initialize the Lua shell state without restarting the system
/// (hot reload, spec/runtime.md §5). Safe only when no Lua frame is on
/// the stack — the event loop is the single caller (performReload).
pub fn reload() void {
    lua.reload();
    lua.runMain("main.lua") catch |err| {
        const serial = @import("../serial.zig");
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "shell: reload failed ({s})", .{@errorName(err)}) catch "shell: reload failed";
        serial.writeLine(line);
    };
}

/// Request a shell reload. Safe from anywhere, including inside a Lua
/// call (e.g. `runtime.reload()` from the session menu): the reload
/// itself is deferred to the event loop, which performs it outside the
/// Lua call frame (never close a lua_State that is currently executing).
pub fn requestReload() void {
    reload_requested = true;
}

pub fn reloadRequested() bool {
    return reload_requested;
}

/// Perform the pending reload and clear the flag. Called by the event
/// loop only (no Lua frame on the stack).
pub fn performReload() void {
    if (!reload_requested) return;
    reload_requested = false;
    reload();
}
pub fn spawn(opts: SpawnOptions) !Program {
    switch (opts.kind) {
        .Lua => {
            const handle = next_handle;
            next_handle += 1;
            try lua.runMain(opts.entry);
            return .{ .kind = .Lua, .handle = handle };
        },
        else => return error.NotSupported,
    }
}

pub fn dispatch(args: sys.SyscallArgs) u64 {
    const op: RuntimeOp = @enumFromInt(args.a);
    switch (op) {
        .spawn => {
            const opts: *const SpawnOptions = @ptrFromInt(@as(usize, @intCast(args.b)));
            if (spawn(opts.*)) |_| {
                return @intFromEnum(sys.KiStatus.Success);
            } else |_| {
                return @intFromEnum(sys.KiStatus.NotSupported);
            }
        },
        .kill, .status => return @intFromEnum(sys.KiStatus.NotSupported),
        .reload => {
            // Deferred: the event loop performs the reload outside the
            // Lua call that triggered it (spec/runtime.md §5).
            requestReload();
            return @intFromEnum(sys.KiStatus.Success);
        },
    }
}
