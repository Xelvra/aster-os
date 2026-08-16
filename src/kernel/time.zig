const std = @import("std");
const io = @import("cpu/io.zig");

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

/// Real-time clock (milliseconds) used for boot metrics (spec/roadmap.md §2).
/// The TSC is calibrated against the PIT once at boot, so `ms()` reports real
/// wall-clock time without relying on the APIC tick rate or interrupts.
/// Integer-only (no floating point in the kernel).
var tsc_per_100ms: u64 = 0;

pub fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [_] "={eax}" (lo),
          [_] "={edx}" (hi),
        :
        : .{ .memory = true });
    return (@as(u64, hi) << 32) | lo;
}

const pit_control: u16 = 0x43;
const pit_ch2_data: u16 = 0x42;
const pit_freq: u64 = 1193182; // 8254 nominal rate, Hz

fn readPitCh2() u16 {
    // Latch channel 2 (control byte 0x80 = ch2 + latch count), then read
    // lo/hi. A mode word (0xB0) is NOT a latch — programming it per read made
    // the countdown appear to finish immediately and produced a garbage TSC
    // rate / ms() == 0.
    io.out8(pit_control, 0x80);
    const lo = io.in8(pit_ch2_data);
    const hi = io.in8(pit_ch2_data);
    return @as(u16, lo) | (@as(u16, hi) << 8);
}

/// Measure the TSC rate against the PIT (channel 2, mode 0 one-shot, ~10 ms)
/// and store the TSC count per 100 ms. Called once at boot with interrupts
/// masked; ~10 ms of PIT counting is an acceptable boot-cost. Retried so a
/// broken read cannot leave `tsc_per_100ms` at a garbage value that would make
/// `ms()` return 0 and freeze every real-time consumer (bar clock, UI timing).
pub fn calibrateRealTime() void {
    const reload: u16 = 11932; // ~10 ms at pit_freq
    for (0..4) |_| {
        io.out8(pit_control, 0xB0); // channel 2, access lo/hi, mode 0, binary
        io.out8(pit_ch2_data, @truncate(reload));
        io.out8(pit_ch2_data, @truncate(reload >> 8));

        const t0 = rdtsc();
        var spins: usize = 0;
        while (readPitCh2() != 0) : (spins += 1) {
            if (spins > 100_000) break; // PIT never reached 0 — broken read
        }
        const t1 = rdtsc();

        const real_ms = @as(u64, reload) * 1000 / pit_freq;
        const tsc_delta = t1 - t0;
        // Accept any real ~ms-scale measurement: QEMU TCG can emulate the TSC
        // at tens of GHz (a correct 10 ms countdown measures 250M+ ticks), so
        // there is no useful upper bound. Only reject an immediate exit of the
        // countdown loop, which measures only a few thousand ticks.
        if (tsc_delta >= real_ms * 100_000) {
            tsc_per_100ms = tsc_delta * 100 / real_ms;
            return;
        }
    }
    // All retries failed: keep tsc_per_100ms at 0 (ms() returns 0) rather than
    // store a garbage rate.
}

/// Real wall-clock milliseconds since an arbitrary boot epoch (0 until
/// `calibrateRealTime` ran). Elapsed time = `ms() - start`.
pub fn ms() u64 {
    if (tsc_per_100ms == 0) return 0;
    return rdtsc() * 100 / tsc_per_100ms;
}

/// Wall-clock time of day at boot, as ms since midnight, read from the CMOS
/// RTC (0 when no valid RTC was available). `ofDayMs` adds the monotonic ms,
/// so the bar clock shows real wall time, not uptime.
var rtc_start_ms: u64 = 0;

pub fn seedRtc(ms_since_midnight: u64) void {
    rtc_start_ms = ms_since_midnight;
}

/// Current wall-clock time of day as ms since midnight (RTC seed + elapsed).
pub fn ofDayMs() u64 {
    return rtc_start_ms + ms();
}
