const std = @import("std");
const boot_info = @import("../boot/boot_info.zig");
const pfa = @import("pfa.zig");
const heap = @import("heap.zig");

pub const Memory = struct {
    pfa: pfa.PageFrameAllocator,
    heap_allocator: heap.HeapAllocator,
    bitmap: []u8,

    /// Fill `self` in place (not return-by-value) so the heap can hold a
    /// pointer to `self.pfa` that outlives this call — a returned copy would
    /// leave the pointer dangling (handoff H2/H3 class, audit 2026-08-15).
    pub fn init(self: *Memory, info: *const boot_info.BootInfo) !void {
        const total_pages = highestPage(info.memory_entries);
        const bitmap_bytes = (total_pages + 7) / 8;
        const bitmap_page = try reserveBitmap(info, bitmap_bytes);
        const bitmap_ptr: [*]u8 = @ptrFromInt(bitmap_page + info.hhdm_offset);
        @memset(bitmap_ptr[0..bitmap_bytes], 0);

        self.pfa = try pfa.PageFrameAllocator.init(info.memory_entries, info.hhdm_offset, bitmap_ptr[0..bitmap_bytes], bitmap_page / pfa.page_size);
        self.heap_allocator = heap.HeapAllocator.init(&self.pfa);
        self.bitmap = bitmap_ptr[0..bitmap_bytes];
    }

    pub fn allocator(self: *Memory) std.mem.Allocator {
        return self.heap_allocator.allocator();
    }

    /// Physical memory snapshot for the Sysmon KI module. The PFA stays
    /// encapsulated behind Memory so api/* never imports it directly.
    pub fn stats(self: *const Memory) MemStats {
        return .{
            .total_bytes = self.pfa.total_pages * pfa.page_size,
            .free_bytes = self.pfa.totalFreePages() * pfa.page_size,
        };
    }
};

pub const MemStats = struct {
    total_bytes: u64,
    free_bytes: u64,
};

fn highestPage(entries: []const boot_info.MemoryEntry) u64 {
    var highest: u64 = 0;
    for (entries) |entry| {
        if (!pfa.isRamEntry(entry.type)) continue;
        const end = entry.base + entry.length;
        const page = end / pfa.page_size;
        if (page > highest) highest = page;
    }
    return highest;
}

fn reserveBitmap(info: *const boot_info.BootInfo, bytes: usize) !u64 {
    const pages_needed = (bytes + pfa.page_size - 1) / pfa.page_size;
    for (info.memory_entries) |entry| {
        if (entry.type != .usable) continue;
        // Never reserve below low_memory_end: the bootloader's direct map does
        // not map it (C32/H3), so zeroing the bitmap there would page-fault at
        // boot; the PFA also refuses to allocate those pages, so the bitmap
        // accounting stays consistent (audit 2026-08-15).
        const base = @max(entry.base, pfa.low_memory_end);
        const page_aligned = std.mem.alignForward(u64, base, pfa.page_size);
        const end = entry.base + entry.length;
        if (page_aligned >= end) continue;
        const available = end - page_aligned;
        const entry_pages = available / pfa.page_size;
        if (entry_pages >= pages_needed) {
            return page_aligned;
        }
    }
    return error.OutOfMemory;
}
