const debug = @import("debug.zig");
const graphics = @import("graphics.zig");
const input = @import("input.zig");
const timer = @import("timer.zig");
const runtime = @import("runtime.zig");
const sysmon = @import("sysmon.zig");
const power = @import("power.zig");
const storage = @import("storage.zig");

pub const Syscall = enum(u64) {
    Debug = 0,
    Graphics = 1,
    Input = 2,
    Timer = 3,
    Runtime = 4,
    Yield = 5,
    Sysmon = 6,
    Power = 7,
    Storage = 8,
};

pub const KiStatus = enum(u16) {
    Success = 0,
    InvalidArgument = 1,
    NotFound = 2,
    NotSupported = 3,
    NoMemory = 4,
    Busy = 5,
    Timeout = 6,
    IoError = 7,
};

pub const SyscallArgs = struct {
    a: u64 = 0,
    b: u64 = 0,
    c: u64 = 0,
};

pub fn dispatch(num: Syscall, args: SyscallArgs) u64 {
    return switch (num) {
        .Debug => debug.dispatch(args),
        .Graphics => graphics.dispatch(args),
        .Input => input.dispatch(args),
        .Timer => timer.dispatch(args),
        .Runtime => runtime.dispatch(args),
        .Yield => @intFromEnum(KiStatus.NotSupported),
        .Sysmon => sysmon.dispatch(args),
        .Power => power.dispatch(args),
        .Storage => storage.dispatch(args),
    };
}
