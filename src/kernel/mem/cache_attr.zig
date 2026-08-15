const io = @import("../cpu/io.zig");

pub const CacheAttr = enum(u8) {
    uc = 0,
    wc = 1,
    wt = 4,
    wb = 6,
    uc_minus = 7,
    other,
};

var hhdm_offset: u64 = 0;

pub fn framebufferCacheAttr(fb_address: u64, offset: u64) CacheAttr {
    hhdm_offset = offset;
    const cr3 = io.readCr3();
    const pte = walkPageTable(cr3, fb_address) orelse return .other;
    const pat_index = ((pte >> 7) & 1) << 2 | ((pte >> 4) & 1) << 1 | ((pte >> 3) & 1);
    return patToAttr(pat_index);
}

fn walkPageTable(cr3: u64, vaddr: u64) ?u64 {
    const pml4_index: usize = @intCast((vaddr >> 39) & 0x1FF);
    const pdpt_index: usize = @intCast((vaddr >> 30) & 0x1FF);
    const pd_index: usize = @intCast((vaddr >> 21) & 0x1FF);
    const pt_index: usize = @intCast((vaddr >> 12) & 0x1FF);

    const pml4_entry = readEntry(cr3 + pml4_index * 8) orelse return null;
    const pml4_addr = pml4_entry & 0x000FFFFFFFFFF000;
    const pdpt_entry = readEntry(pml4_addr + pdpt_index * 8) orelse return null;
    if (pdpt_entry & (1 << 7) != 0) return pdpt_entry; // 1 GiB huge page
    const pdpt_addr = pdpt_entry & 0x000FFFFFFFFFF000;
    const pd_entry = readEntry(pdpt_addr + pd_index * 8) orelse return null;
    if (pd_entry & (1 << 7) != 0) return pd_entry; // 2 MiB huge page

    const pd_addr = pd_entry & 0x000FFFFFFFFFF000;
    const pt_entry = readEntry(pd_addr + pt_index * 8) orelse return null;
    return pt_entry;
}

fn readEntry(phys_addr: u64) ?u64 {
    const ptr: [*]const u64 = @ptrFromInt(phys_addr + hhdm_offset);
    const entry = ptr[0];
    if (entry & 1 == 0) return null;
    return entry;
}

fn patToAttr(index: usize) CacheAttr {
    const pat_msr = io.readMsr(0x277);
    const pat_value: u8 = @intCast((pat_msr >> @intCast(index * 8)) & 0xFF);
    return switch (pat_value) {
        0x00 => .uc,
        0x01 => .wc,
        0x04 => .wt,
        0x06 => .wb,
        0x07 => .uc_minus,
        else => .other,
    };
}
