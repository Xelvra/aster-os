const io = @import("io.zig");
const idt = @import("idt.zig");
const page_map = @import("../mem/page_map.zig");

const ia32_apic_base_msr: u32 = 0x1B;

const apic_lvt_timer: u32 = 0x320;
const apic_timer_div: u32 = 0x3E0;
const apic_timer_initial: u32 = 0x380;
const apic_eoi: u32 = 0xB0;
const apic_svr: u32 = 0xF0;

const ioapic_default_phys: u64 = 0xFEC00000;
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

pub fn init(hhdm_offset: u64, ioapic_override: ?u64) void {
    const msr = io.readMsr(ia32_apic_base_msr);
    const apic_phys = msr & 0xFFFFF000;
    apic_base = apic_phys + hhdm_offset;

    page_map.mapPage(apic_base, apic_phys, 0x1A);
    const ioapic_phys = ioapic_override orelse ioapic_default_phys;
    ioapic_base = ioapic_phys + hhdm_offset;
    page_map.mapPage(ioapic_base, ioapic_phys, 0x1A);

    writeReg(apic_svr, apic_enable | spurious_vector);
    writeReg(apic_lvt_timer, @as(u32, timer_vector) | timer_periodic);
    writeReg(apic_timer_div, timer_div_1);
    writeReg(apic_timer_initial, 0x200000);

    enableIsaIrq(1, 0x21);
    enableIsaIrq(12, 0x22);
}

pub fn enableIsaIrq(isa_irq: u8, vector: u8) void {
    const reg_lo = ioapic_redtbl + @as(u32, isa_irq) * 2;
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
