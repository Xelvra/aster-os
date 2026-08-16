const std = @import("std");
const io = @import("io.zig");
const idt = @import("idt.zig");
const page_map = @import("../mem/page_map.zig");
const acpi = @import("acpi.zig");

const ia32_apic_base_msr: u32 = 0x1B;

const apic_lvt_timer: u32 = 0x320;
const apic_timer_div: u32 = 0x3E0;
const apic_timer_initial: u32 = 0x380;
const apic_eoi: u32 = 0xB0;
const apic_svr: u32 = 0xF0;
const apic_lapic_id_reg: u32 = 0x20;
const apic_icr_lo: u32 = 0x300;
const apic_icr_hi: u32 = 0x310;

const icr_delivery_status: u32 = 1 << 12;
const icr_level_assert: u32 = 1 << 14;
const icr_trigger_level: u32 = 1 << 15;
const icr_init_mode: u32 = 0x5 << 8;
const icr_startup_mode: u32 = 0x6 << 8;

const ioapic_default_phys: u64 = 0xFEC00000;
/// The I/O APIC MMIO window the chipset puts at 0xFEC00xxx (reserved, not
/// RAM). A MADT-supplied address outside this window is corrupt and must not
/// be mapped/written (audit 2026-08-15).
const ioapic_window_start: u64 = 0xFEC00000;
const ioapic_window_end: u64 = 0xFEC01000;
const ioapic_regsel: u32 = 0x00;
const ioapic_win: u32 = 0x10;
const ioapic_redtbl: u32 = 0x10;
const ioapic_lo_masked: u32 = 1 << 16;

const timer_vector: u8 = 0x20;
const timer_periodic: u32 = 1 << 17;
const timer_div_1: u32 = 0xB;

const apic_enable: u32 = 1 << 8;
const spurious_vector: u8 = 0xFF;

var apic_base: u64 = 0;
var ioapic_base: u64 = 0;
var hhdm_offset: u64 = 0;
var irq_overrides: [acpi.max_irq_overrides]acpi.IrqOverride = undefined;
var irq_override_count: usize = 0;

pub fn init(hhdm: u64, madt: ?acpi.Madt) void {
    hhdm_offset = hhdm;
    const msr = io.readMsr(ia32_apic_base_msr);
    const apic_phys = msr & 0xFFFFF000;
    apic_base = apic_phys + hhdm_offset;

    page_map.mapPage(apic_base, apic_phys, 0x1A);
    var ioapic_phys: u64 = ioapic_default_phys;
    if (madt) |m| {
        // ISA IRQ -> GSI overrides (M2 SMP debt): the I/O APIC redirection
        // table uses the overridden GSI, not the raw ISA IRQ number.
        irq_overrides = m.irq_overrides;
        irq_override_count = m.irq_override_count;
        if (m.io_apic_address >= ioapic_window_start and m.io_apic_address < ioapic_window_end) {
            ioapic_phys = m.io_apic_address;
        }
    }
    ioapic_base = ioapic_phys + hhdm_offset;
    page_map.mapPage(ioapic_base, ioapic_phys, 0x1A);

    writeReg(apic_svr, apic_enable | spurious_vector);
    writeReg(apic_lvt_timer, @as(u32, timer_vector) | timer_periodic);
    writeReg(apic_timer_div, timer_div_1);
    writeReg(apic_timer_initial, 0x200000);

    enableIsaIrq(1, 0x21);
    enableIsaIrq(12, 0x22);
}

/// Enable the Local APIC on the current CPU (SMP AP bring-up): re-read the
/// IA32_APIC_BASE MSR — the APIC is per-CPU MMIO and the base can differ from
/// the BSP's — then arm the spurious-vector register so spurious interrupts
/// are dropped instead of faulting. No timer is programmed: only the BSP runs
/// the preemptive scheduler tick.
pub fn enableLocal() void {
    const msr = io.readMsr(ia32_apic_base_msr);
    const phys = msr & 0xFFFFF000;
    apic_base = phys + hhdm_offset;
    writeReg(apic_svr, apic_enable | spurious_vector);
}

/// The Local APIC ID of the current CPU (MMIO 0x20, bits 24-31). The BSP
/// reads its own for diagnostics; the MADT supplies the AP IDs.
pub fn readLocalApicId() u8 {
    return @truncate(readReg(apic_lapic_id_reg) >> 24);
}

/// Send an INIT IPI to one Application Processor (SMP bring-up, step 1).
/// INIT is level-triggered: the assert must be followed by a ~10 ms pause and
/// a deassert, otherwise the ICR delivery status stays set and the next
/// waitForIcrIdle spins forever.
pub fn sendInitIpi(lapic_id: u8) void {
    waitForIcrIdle();
    writeReg(apic_icr_hi, @as(u32, lapic_id) << 24);
    writeReg(apic_icr_lo, icr_init_mode | icr_trigger_level | icr_level_assert);
    const time = @import("../time.zig");
    const start = time.ms();
    while (time.ms() - start < 10) {}
    writeReg(apic_icr_hi, @as(u32, lapic_id) << 24);
    writeReg(apic_icr_lo, icr_init_mode | icr_trigger_level);
}

/// Send a Start-Up IPI (SIPI) to one Application Processor: `vector` is the
/// page-aligned low-memory address of the trampoline >> 12. Sent twice after
/// INIT per the P1/P2 flow (the second is a retry if the first was lost).
pub fn sendSipi(lapic_id: u8, vector: u8) void {
    waitForIcrIdle();
    writeReg(apic_icr_hi, @as(u32, lapic_id) << 24);
    writeReg(apic_icr_lo, icr_startup_mode | @as(u32, vector));
}

fn waitForIcrIdle() void {
    while ((readReg(apic_icr_lo) & icr_delivery_status) != 0) {}
}

/// Map an ISA IRQ to its I/O APIC global system interrupt (GSI), applying the
/// MADT Interrupt Source Override (M2 SMP debt). Without an override the GSI
/// equals the ISA IRQ number.
fn gsiFor(isa_irq: u8) u32 {
    for (0..irq_override_count) |i| {
        if (irq_overrides[i].isa_irq == isa_irq) return irq_overrides[i].gsi;
    }
    return isa_irq;
}

pub fn enableIsaIrq(isa_irq: u8, vector: u8) void {
    const gsi = gsiFor(isa_irq);
    // gsi is bounded by acpi.max_gsi at parse time; keep checked arithmetic
    // here anyway so a corrupt value that ever slips through degrades to the
    // raw ISA IRQ number instead of an overflow panic in ReleaseSafe.
    const gsi2 = std.math.mul(u32, gsi, 2) catch @as(u32, isa_irq);
    const reg_lo = std.math.add(u32, ioapic_redtbl, gsi2) catch @as(u32, isa_irq);
    const reg_hi = reg_lo + 1;
    ioapicWrite(reg_hi, 0);
    ioapicWrite(reg_lo, @as(u32, vector) & ~ioapic_lo_masked);
}

pub fn sendEoi() void {
    writeReg(apic_eoi, 0);
}

fn readReg(offset: u32) u32 {
    const addr = apic_base + offset;
    const ptr: [*]volatile u32 = @ptrFromInt(addr);
    return ptr[0];
}

fn writeReg(offset: u32, value: u32) void {
    const addr = apic_base + offset;
    const ptr: [*]volatile u32 = @ptrFromInt(addr);
    ptr[0] = value;
}

fn ioapicWrite(reg: u32, value: u32) void {
    const sel_ptr: [*]volatile u32 = @ptrFromInt(ioapic_base + ioapic_regsel);
    sel_ptr[0] = reg;
    const win_ptr: [*]volatile u32 = @ptrFromInt(ioapic_base + ioapic_win);
    win_ptr[0] = value;
}
