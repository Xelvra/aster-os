const std = @import("std");
const serial = @import("../serial.zig");
const input_queue = @import("../input_queue.zig");

pub const Syscall = enum(u64) {
    Debug = 0,
    Graphics = 1,
    Input = 2,
    Timer = 3,
    Runtime = 4,
    Yield = 5,
};

pub const KiStatus = enum(u16) {
    Success = 0,
    InvalidArgument = 1,
    NotFound = 2,
    NotSupported = 3,
    NoMemory = 4,
    Busy = 5,
    Timeout = 6,
};

pub const SyscallArgs = struct {
    a: u64 = 0,
    b: u64 = 0,
    c: u64 = 0,
};

pub const DebugOp = enum(u64) {
    write = 0,
    status = 1,
};

pub const InputOp = enum(u64) {
    next_event = 0,
    peek_event = 1,
    flush = 2,
};

pub fn dispatch(num: Syscall, args: SyscallArgs) u64 {
    return switch (num) {
        .Debug => debugDispatch(args),
        .Input => inputDispatch(args),
        .Graphics, .Timer, .Runtime, .Yield => @intFromEnum(KiStatus.NotSupported),
    };
}

fn debugDispatch(args: SyscallArgs) u64 {
    const op: DebugOp = @enumFromInt(args.a);
    return switch (op) {
        .write => {
            const ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(args.b)));
            const len: usize = @intCast(args.c);
            for (0..len) |i| {
                serial.writeChar(ptr[i]);
            }
            return @intFromEnum(KiStatus.Success);
        },
        .status => @intFromEnum(KiStatus.Success),
    };
}

fn inputDispatch(args: SyscallArgs) u64 {
    const op: InputOp = @enumFromInt(args.a);
    return switch (op) {
        .next_event => @intFromEnum(KiStatus.NotSupported),
        .peek_event => @intFromEnum(KiStatus.NotSupported),
        .flush => @intFromEnum(KiStatus.NotSupported),
    };
}
