const io = @import("../cpu/io.zig");
const pfa = @import("pfa.zig");
const present: u64 = 1 << 0;
pub const rw: u64 = 1 << 1;
const ps: u64 = 1 << 7; // huge-page (PDE 2 MiB / PDPTE 1 GiB) bit
const addr_mask: u64 = 0x000FFFFFFFFFF000;

var hhdm_offset: u64 = 0;
var pfa_inst: ?*pfa.PageFrameAllocator = null;

pub fn init(alloc: *pfa.PageFrameAllocator, hhdm: u64) void {
    pfa_inst = alloc;
    hhdm_offset = hhdm;
}

pub fn mapPage(virtual: u64, physical: u64, flags: u64) void {
    const alloc = pfa_inst orelse return;
    const cr3 = io.readCr3();

    const pml4_idx: usize = @intCast((virtual >> 39) & 0x1FF);
    const pdpt_idx: usize = @intCast((virtual >> 30) & 0x1FF);
    const pd_idx: usize = @intCast((virtual >> 21) & 0x1FF);
    const pt_idx: usize = @intCast((virtual >> 12) & 0x1FF);

    const pml4 = cr3;
    // Bail out on any table-level failure instead of writing a PTE at the
    // direct-map base (audit 2026-08-15).
    const pdpt = ensureTable(alloc, pml4, pml4_idx) orelse return;
    const pd = ensureTable(alloc, pdpt, pdpt_idx) orelse return;
    const pt = ensureTable(alloc, pd, pd_idx) orelse return;

    const pte_addr = pt + pt_idx * 8;
    const pte_ptr: [*]volatile u64 = @ptrFromInt(pte_addr + hhdm_offset);
    pte_ptr[0] = (physical & addr_mask) | flags | present;
    flushTlb(virtual);
}

fn ensureTable(alloc: *pfa.PageFrameAllocator, parent_phys: u64, index: usize) ?u64 {
    const entry_ptr: [*]volatile u64 = @ptrFromInt(parent_phys + hhdm_offset + index * 8);
    const entry = entry_ptr[0];
    if (entry & present != 0) {
        // A huge-page entry (PS set) is data, not a table pointer — walking it
        // as entries would corrupt memory (audit 2026-08-15).
        if (entry & ps != 0) return null;
        return entry & addr_mask;
    }
    const new_table_phys = alloc.allocPage(true) catch return null;
    entry_ptr[0] = new_table_phys | present | rw;
    return new_table_phys;
}

fn flushTlb(virtual: u64) void {
    // Zig 0.16 rejects `invlpg (%[addr])` with an "r" operand in Debug builds
    // ("invalid memory operand"), while ReleaseSafe accepts it. Moving the
    // address into %rax first and then using `(%rax)` works in both modes.
    asm volatile ("mov %[addr], %%rax\ninvlpg (%%rax)"
        :
        : [addr] "r" (virtual),
        : .{ .rax = true, .memory = true });
}
