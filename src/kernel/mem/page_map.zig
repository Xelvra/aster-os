const std = @import("std");
const pfa = @import("pfa.zig");
const present: u64 = 1 << 0;
const rw: u64 = 1 << 1;
const addr_mask: u64 = 0x000FFFFFFFFFF000;

var hhdm_offset: u64 = 0;
var pfa_inst: ?*pfa.PageFrameAllocator = null;

pub fn init(alloc: *pfa.PageFrameAllocator, hhdm: u64) void {
    pfa_inst = alloc;
    hhdm_offset = hhdm;
}

pub fn mapPage(virtual: u64, physical: u64, flags: u64) void {
    const alloc = pfa_inst orelse return;
    const cr3 = read_cr3();

    const pml4_idx: usize = @intCast((virtual >> 39) & 0x1FF);
    const pdpt_idx: usize = @intCast((virtual >> 30) & 0x1FF);
    const pd_idx: usize = @intCast((virtual >> 21) & 0x1FF);
    const pt_idx: usize = @intCast((virtual >> 12) & 0x1FF);

    const pml4 = cr3;
    const pdpt = ensureTable(alloc, pml4, pml4_idx);
    const pd = ensureTable(alloc, pdpt, pdpt_idx);
    const pt = ensureTable(alloc, pd, pd_idx);

    const pte_addr = pt + pt_idx * 8;
    const pte_ptr: [*]volatile u64 = @ptrFromInt(pte_addr + hhdm_offset);
    pte_ptr[0] = (physical & addr_mask) | flags | present;
    flushTlb(virtual);
}

fn ensureTable(alloc: *pfa.PageFrameAllocator, parent_phys: u64, index: usize) u64 {
    const entry_ptr: [*]volatile u64 = @ptrFromInt(parent_phys + hhdm_offset + index * 8);
    const entry = entry_ptr[0];
    if (entry & present != 0) {
        return entry & addr_mask;
    }
    const new_table_phys = alloc.allocPage(true) catch return 0;
    entry_ptr[0] = new_table_phys | present | rw;
    return new_table_phys;
}

fn flushTlb(virtual: u64) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (virtual),
        : .{ .memory = true });
}

fn read_cr3() u64 {
    return asm volatile ("mov %%cr3, %[v]"
        : [v] "=r" (-> u64),
    );
}
