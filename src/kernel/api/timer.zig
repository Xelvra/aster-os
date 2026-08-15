const sys = @import("sys.zig");
const validate = @import("validate.zig");
const time = @import("../time.zig");

pub const TimerOp = enum(u64) {
    ticks = 0,
    sleep_ms = 1,
};

pub fn dispatch(args: sys.SyscallArgs) u64 {
    const op = validate.opEnum(TimerOp, args.a) orelse return @intFromEnum(sys.KiStatus.NotSupported);
    return switch (op) {
        .ticks => time.ticks(),
        // Cooperative sleep (spec/timer.md §3) lands with the M7 task model.
        // The sub-op is frozen today so the number never changes.
        .sleep_ms => @intFromEnum(sys.KiStatus.NotSupported),
    };
}
