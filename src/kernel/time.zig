const std = @import("std");

/// Monotonic tick source for the kernel, the Timer KI module and Lua. The
/// APIC timer IRQ calls `tick()` on every interrupt; readers use `ticks()`.
/// Owned here (middle layer), not by the CPU/IDT code, so `api/timer` and
/// tests read the clock without importing low-level CPU internals.
var tick_counter = std.atomic.Value(u64).init(0);

/// Advance the tick counter. Called from the APIC timer ISR only.
pub fn tick() void {
    _ = tick_counter.fetchAdd(1, .monotonic);
}

/// Current monotonic tick count since boot.
pub fn ticks() u64 {
    return tick_counter.load(.monotonic);
}
