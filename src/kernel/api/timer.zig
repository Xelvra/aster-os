const sys = @import("sys.zig");
const validate = @import("validate.zig");
const time = @import("../time.zig");

pub const TimerOp = enum(u64) {
    ticks = 0,
    sleep_ms = 1,
    ms = 2,
    of_day_ms = 3,
};

pub fn dispatch(args: sys.SyscallArgs) u64 {
    const op = validate.opEnum(TimerOp, args.a) orelse return @intFromEnum(sys.KiStatus.NotSupported);
    return switch (op) {
        .ticks => time.ticks(),
        // Real wall-clock milliseconds since boot (TSC, PIT-calibrated) —
        // unlike ticks it is independent of the APIC tick rate, so UI
        // timing (e.g. the double-click threshold) is portable.
        .ms => time.ms(),
        // Wall-clock time of day as ms since midnight (CMOS RTC seeded at
        // boot + elapsed) — what the bar clock shows.
        .of_day_ms => time.ofDayMs(),
        // Cooperative sleep (spec/timer.md §3) lands with the M7 task model.
        // The sub-op is frozen today so the number never changes.
        .sleep_ms => @intFromEnum(sys.KiStatus.NotSupported),
    };
}
