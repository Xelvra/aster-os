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

/// Measure the TSC rate against the PIT (channel 2, mode 0 one-shot) and store
/// the TSC count per 100 ms. Called once at boot with interrupts masked. A
/// ~50 ms window averages over far more TSC ticks than the old ~10 ms one, so
/// timing jitter and a single glitchy read matter less; the **median of five
/// samples** rejects an occasional broken read. If every sample is unusable,
/// a fixed 2.5 GHz assumption keeps `ms()` advancing (approximately) instead
/// of returning 0 and freezing the wall clock.
pub fn calibrateRealTime() void {
    const reload: u16 = 59659; // ~50 ms at pit_freq
    var samples: [5]u64 = undefined;
    for (&samples) |*s| {
        io.out8(pit_control, 0xB0); // channel 2, access lo/hi, mode 0, binary
        io.out8(pit_ch2_data, @truncate(reload));
        io.out8(pit_ch2_data, @truncate(reload >> 8));

        const t0 = rdtsc();
        var spins: usize = 0;
        while (readPitCh2() != 0) : (spins += 1) {
            if (spins > 1_000_000) break; // PIT never reached 0 — broken read
        }
        s.* = rdtsc() - t0;
    }
    insertionSort(&samples);
    const real_ms = @as(u64, reload) * 1000 / pit_freq;
    const median = samples[samples.len / 2];
    // Accept any real ~ms-scale measurement (QEMU TCG can emulate the TSC at
    // tens of GHz, so there is no useful upper bound); only an immediate exit
    // of the countdown loop (a few thousand ticks) is rejected.
    if (median >= real_ms * 100_000) {
        tsc_per_100ms = median * 100 / real_ms;
        return;
    }
    // Fallback: a 2.5 GHz assumption so ms() advances (approximately) rather
    // than freezing every real-time consumer when the PIT is unusable here.
    tsc_per_100ms = 2_500_000_000 / 10;
}

/// Insertion sort of a fixed 5-element array (kernel: no allocations).
fn insertionSort(values: *[5]u64) void {
    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        const key = values[i];
        var j = i;
        while (j > 0 and values[j - 1] > key) : (j -= 1) {
            values[j] = values[j - 1];
        }
        values[j] = key;
    }
}

/// Real wall-clock milliseconds since an arbitrary boot epoch (0 until
/// `calibrateRealTime` ran). Elapsed time = `ms() - start`.
pub fn ms() u64 {
    if (tsc_per_100ms == 0) return 0;
    return rdtsc() * 100 / tsc_per_100ms;
}

/// Wall-clock time of day at boot, as ms since midnight, read from the CMOS
/// RTC (0 when no valid RTC was available). `ofDayMs` adds the elapsed
/// monotonic ms, so the bar clock shows real wall time, not uptime.
var rtc_start_ms: u64 = 0;
/// The `ms()` value when `rtc_start_ms` was last set, so `ofDayMs` measures
/// elapsed time from that sync point (not from boot).
var ms_at_sync: u64 = 0;

/// (Re-)seed the wall clock from the RTC. Called at boot and again by the
/// event loop each frame, so the RTC — a real hardware clock that always
/// reflects the current time — keeps the bar clock correct even when the
/// TSC-based `ms()` is miscalibrated or frozen.
pub fn seedRtc(ms_since_midnight: u64) void {
    rtc_start_ms = ms_since_midnight;
    ms_at_sync = ms();
}

/// Current wall-clock time of day as ms since midnight (last RTC read +
/// elapsed monotonic ms).
pub fn ofDayMs() u64 {
    return rtc_start_ms + (ms() - ms_at_sync);
}
