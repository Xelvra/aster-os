const sys = @import("sys.zig");
const idt = @import("../cpu/idt.zig");

pub const TimerOp = enum(u64) {
    ticks = 0,
    sleep_ms = 1,
};

pub fn dispatch(args: sys.SyscallArgs) u64 {
    const op: TimerOp = @enumFromInt(args.a);
    return switch (op) {
        .ticks => idt.tick_counter.load(.monotonic),
        // Cooperative sleep (spec/timer.md §3) lands with the M7 task model.
        // The sub-op is frozen today so the number never changes.
        .sleep_ms => @intFromEnum(sys.KiStatus.NotSupported),
    };
}
