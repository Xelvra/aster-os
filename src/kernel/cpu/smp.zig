const std = @import("std");
const acpi = @import("acpi.zig");
const apic = @import("apic.zig");
const idt = @import("idt.zig");
const io = @import("io.zig");
const page_map = @import("../mem/page_map.zig");

/// The low-memory page that hosts the copied trampoline. It sits below 1 MiB
/// so a SIPI vector fits (vector = physical >> 12 = 0x8). The PFA never
/// allocates below 1 MiB (pfa.low_memory_end), so the page is reserved
/// implicitly; the BSP identity-maps it so both the copy/writes and the APs'
/// execution can reach it.
const trampoline_phys: u64 = 0x8000;
const trampoline_flags: u64 = 0x2; // present | rw

const max_ap = acpi.max_ap;
const ap_stack_size: usize = 16384;

/// Number of enabled Application Processors from the MADT (0 = single-core).
pub var ap_count: usize = 0;

var ap_ids: [max_ap]u8 = undefined;
var ap_stacks: [max_ap][ap_stack_size]u8 align(16) = undefined;
var hhdm_offset: u64 = 0;

/// How many APs have reported ready after SIPI (written by the APs
/// themselves, polled by the BSP). Only touched during boot bring-up.
pub var ap_ready = std.atomic.Value(usize).init(0);

const smp_tramp_start = @extern([*]u8, .{ .name = "smp_trampoline_start" });
const smp_tramp_end = @extern([*]u8, .{ .name = "smp_trampoline_end" });
const smp_cr3_sym = @extern([*]u8, .{ .name = "smp_cr3" });
const smp_cpu_id_sym = @extern([*]u8, .{ .name = "smp_cpu_id" });
const smp_stack_top_sym = @extern([*]u8, .{ .name = "smp_stack_top" });
const smp_high64_sym = @extern([*]u8, .{ .name = "smp_high64" });
const smp_ap_entry_sym = @extern([*]u8, .{ .name = "smp_ap_entry" });

/// Collect the AP LAPIC IDs from the parsed MADT and stage the trampoline:
/// identity-map its page and copy the code block there. Called right after
/// `apic.init`; a null MADT (no ACPI / fallback) means single-core.
pub fn init(madt: ?acpi.Madt, hhdm: u64) void {
    hhdm_offset = hhdm;
    if (madt) |m| {
        const n = @min(m.ap_count, max_ap);
        for (0..n) |i| ap_ids[i] = m.ap_ids[i];
        ap_count = n;
    }
    if (ap_count == 0) return;

    page_map.mapPage(trampoline_phys, trampoline_phys, trampoline_flags);
    const code_len = @intFromPtr(smp_tramp_end) - @intFromPtr(smp_tramp_start);
    const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(trampoline_phys)));
    @memcpy(dst[0..code_len], smp_tramp_start[0..code_len]);

    // The page tables and the higher-half entry are the same for every AP.
    setData(u64, smp_cr3_sym, io.readCr3());
    setData(u64, smp_high64_sym, @intFromPtr(smp_ap_entry_sym));
}

/// Wake every AP with INIT -> SIPI -> SIPI and wait for it to report ready.
/// A stuck AP (timeout) is skipped so boot continues single-core instead of
/// hanging; the runtime test observes how many actually came up.
pub fn bringUp() void {
    if (ap_count == 0) return;
    const vector: u8 = @intCast(trampoline_phys >> 12);
    for (0..ap_count) |i| {
        const stack_top = @intFromPtr(&ap_stacks[i]) + ap_stack_size;
        setData(u64, smp_cpu_id_sym, @as(u64, @intCast(i)));
        setData(u64, smp_stack_top_sym, stack_top);
        ap_ready.store(0, .seq_cst);
        apic.sendInitIpi(ap_ids[i]);
        apic.sendSipi(ap_ids[i], vector);
        waitReady();
    }
}

const ready_spin_limit: u32 = 2_000_000;

fn waitReady() void {
    var spins: u32 = 0;
    while (ap_ready.load(.seq_cst) == 0 and spins < ready_spin_limit) : (spins += 1) {}
}

/// Application Processor entry point (called from smp_ap_entry, higher half).
/// Loads the shared IDT, enables the per-CPU Local APIC, reports ready and
/// idles. The scheduler stays BSP-only: only the BSP programs the LAPIC timer
/// and preempts, so the APs run no kernel work (and share no scheduler state).
export fn apEntry(cpu_id: u64) noreturn {
    _ = cpu_id;
    idt.load();
    apic.enableLocal();
    _ = ap_ready.fetchAdd(1, .seq_cst);
    while (true) {
        asm volatile ("sti" ::: .{ .memory = true });
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}

fn blockOffset(sym: [*]u8) usize {
    return @intFromPtr(sym) - @intFromPtr(smp_tramp_start);
}

fn setData(comptime T: type, sym: [*]u8, value: T) void {
    const addr = @as(usize, @intCast(trampoline_phys)) + blockOffset(sym);
    const ptr: *T = @ptrFromInt(addr);
    ptr.* = value;
}
