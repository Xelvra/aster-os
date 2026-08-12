const boot_info = @import("../boot/boot_info.zig");

pub const page_size: u64 = 4096;

/// Physical memory below this address is never allocated: the bootloader's
/// direct map does not map it, even though the memory map lists it usable
/// (handoff H3). 1 MiB is the conventional boundary for "low memory".
pub const low_memory_end: u64 = 0x100000;
/// Maximum contiguous frame run allocPages can hand out. The heap grows in
/// multi-page chunks (grow_pages=4), the initfs image (~40 KiB) and the
/// graphics back buffer (~470 pages at 800x600x32bpp) are the largest single
/// allocations, so a 1024-page run (4 MiB) covers all of them.
const max_pages_per_run: usize = 1024;

/// Scratch output buffer for allocPages. It lives outside the PageFrameAllocator
/// struct so the struct stays small on the (bootloader-provided) stack — a
/// [1024]u64 member would overflow it. There is a single PFA instance, and
/// allocations never run from an IRQ, so a single shared buffer is safe.
var pages_storage_global: [max_pages_per_run]u64 = undefined;

pub const PfaError = error{
    OutOfMemory,
    InvalidAddress,
    NotAllocated,
    RunTooLarge,
};

pub const PageFrameAllocator = struct {
    bitmap: []u8,
    total_pages: u64,
    hhdm_offset: u64,
    next_free_hint: u64,
    free_pages: u64,
    pages_storage: []u64,

    pub fn init(memory_entries: []const boot_info.MemoryEntry, hhdm_offset: u64, bitmap: []u8, bitmap_phys_page: ?u64) PfaError!PageFrameAllocator {
        var highest_page: u64 = 0;
        for (memory_entries) |entry| {
            if (!isRamEntry(entry.type)) continue;
            const end = entry.base + entry.length;
            const page = end / page_size;
            if (page > highest_page) highest_page = page;
        }

        const total_pages = highest_page;
        const bitmap_bytes = (total_pages + 7) / 8;
        if (bitmap.len < bitmap_bytes) return PfaError.OutOfMemory;

        @memset(bitmap[0..bitmap_bytes], 0xFF);

        var self = PageFrameAllocator{
            .bitmap = bitmap[0..bitmap_bytes],
            .total_pages = total_pages,
            .hhdm_offset = hhdm_offset,
            .next_free_hint = 0,
            .free_pages = 0,
            .pages_storage = &pages_storage_global,
        };

        for (memory_entries) |entry| {
            if (entry.type == .usable) {
                const first_page = entry.base / page_size;
                const page_count = entry.length / page_size;
                for (first_page..first_page + page_count) |i| {
                    // Low memory below 1 MiB is reported usable by the
                    // bootloader's memory map, but it is NOT mapped into the
                    // higher-half direct map (H3, verified by a page-table
                    // walk) - allocating it would page-fault on first touch.
                    if (i * page_size < low_memory_end) continue;
                    self.clearBit(i);
                    self.free_pages += 1;
                }
            }
        }

        if (bitmap_phys_page) |phys_page| {
            const bitmap_page_count = (bitmap.len + page_size - 1) / page_size;
            for (phys_page..phys_page + bitmap_page_count) |i| {
                self.setBit(i);
            }
            // The bitmap pages were carved out of a usable region already
            // counted as free above; mark them consumed.
            self.free_pages -= @intCast(bitmap_page_count);
        }

        return self;
    }

    pub fn allocPage(self: *PageFrameAllocator, zero: bool) PfaError!u64 {
        const index = self.findFirstFree() orelse return PfaError.OutOfMemory;
        self.setBit(index);
        self.next_free_hint = index + 1;
        self.free_pages -= 1;
        const addr = index * page_size;
        if (zero) self.zeroPage(addr);
        return addr;
    }

    pub fn freePage(self: *PageFrameAllocator, addr: u64) PfaError!void {
        if (addr % page_size != 0) return PfaError.InvalidAddress;
        const index = addr / page_size;
        if (index >= self.total_pages) return PfaError.InvalidAddress;
        if (!self.isSet(index)) return PfaError.NotAllocated;
        self.clearBit(index);
        if (index < self.next_free_hint) self.next_free_hint = index;
        self.free_pages += 1;
    }

    pub fn allocPages(self: *PageFrameAllocator, count: usize, zero: bool) PfaError![]u64 {
        if (count > max_pages_per_run) return PfaError.RunTooLarge;
        const start = self.findFirstFreeRun(count) orelse return PfaError.OutOfMemory;
        for (0..count) |i| {
            const index = start + i;
            self.setBit(index);
            const addr = index * page_size;
            if (zero) self.zeroPage(addr);
            self.pages_storage[i] = addr;
        }
        self.next_free_hint = start + count;
        self.free_pages -= @intCast(count);
        return self.pages_storage[0..count];
    }

    pub fn freePages(self: *PageFrameAllocator, addrs: []const u64) PfaError!void {
        for (addrs) |addr| {
            try self.freePage(addr);
        }
    }

    pub fn totalFreePages(self: *const PageFrameAllocator) u64 {
        return self.free_pages;
    }

    /// First single free page. Scans from the hint forward, then wraps around
    /// to the start when the hint region is exhausted. The hint is a scanning
    /// optimization, not a guarantee: freePage lowers it below any freshly
    /// freed page, so correctness never depends on its accuracy.
    fn findFirstFree(self: *const PageFrameAllocator) ?u64 {
        for (self.next_free_hint..self.total_pages) |i| {
            if (!self.isSet(i)) return i;
        }
        for (0..self.next_free_hint) |i| {
            if (!self.isSet(i)) return i;
        }
        return null;
    }

    /// First free run of `count` pages, scanned in two passes: from the hint
    /// to the end, then from the start to the hint. A run is never counted
    /// across the wrap boundary — pages wrap at `total_pages`, so contiguous
    /// runs cannot span it.
    fn findFirstFreeRun(self: *const PageFrameAllocator, count: usize) ?u64 {
        var run: usize = 0;
        for (self.next_free_hint..self.total_pages) |i| {
            if (!self.isSet(i)) {
                run += 1;
                if (run == count) return i - (count - 1);
            } else {
                run = 0;
            }
        }
        run = 0;
        for (0..self.next_free_hint) |i| {
            if (!self.isSet(i)) {
                run += 1;
                if (run == count) return i - (count - 1);
            } else {
                run = 0;
            }
        }
        return null;
    }

    fn zeroPage(self: *PageFrameAllocator, physical: u64) void {
        const virtual = physical + self.hhdm_offset;
        const ptr: [*]u8 = @ptrFromInt(virtual);
        @memset(ptr[0..page_size], 0);
    }

    fn setBit(self: *PageFrameAllocator, page: u64) void {
        const byte: usize = @intCast(page / 8);
        const bit: u3 = @intCast(page % 8);
        self.bitmap[byte] |= (@as(u8, 1) << bit);
    }

    fn clearBit(self: *PageFrameAllocator, page: u64) void {
        const byte: usize = @intCast(page / 8);
        const bit: u3 = @intCast(page % 8);
        self.bitmap[byte] &= ~(@as(u8, 1) << bit);
    }

    fn isSet(self: *const PageFrameAllocator, page: u64) bool {
        const byte: usize = @intCast(page / 8);
        const bit: u3 = @intCast(page % 8);
        return (self.bitmap[byte] & (@as(u8, 1) << bit)) != 0;
    }
};

pub fn isRamEntry(entry_type: boot_info.MemoryEntryType) bool {
    return switch (entry_type) {
        .usable,
        .bootloader_reclaimable,
        .executable_and_modules,
        .acpi_reclaimable,
        .acpi_nvs,
        => true,
        else => false,
    };
}
