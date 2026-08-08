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

pub fn init(allocator: std.mem.Allocator) void {
    lua.init(allocator);
}

/// Re-initialize the Lua shell state without restarting the system
/// (hot reload, spec/runtime.md §5).
pub fn reload() void {
    lua.reload();
    lua.runMain("main.lua") catch |err| {
        const serial = @import("../serial.zig");
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "shell: reload failed ({s})", .{@errorName(err)}) catch "shell: reload failed";
        serial.writeLine(line);
    };
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
            reload();
            return @intFromEnum(sys.KiStatus.Success);
        },
    }
}
