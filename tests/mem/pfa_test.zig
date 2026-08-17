const std = @import("std");
const pfa = @import("kernel").pfa;
const boot_info = @import("kernel").boot_info;

fn testEntries() [4]boot_info.MemoryEntry {
    return .{
        .{ .base = 0x00000000, .length = 0x00100000, .type = .reserved },
        .{ .base = 0x00100000, .length = 0x00100000, .type = .usable },
        .{ .base = 0x00200000, .length = 0x00100000, .type = .acpi_reclaimable },
        .{ .base = 0x00300000, .length = 0x00100000, .type = .usable },
    };
}

const expected_free_pages: u64 = 0x200;

fn initAllocator() pfa.PageFrameAllocator {
    var bitmap = [_]u8{0} ** 4096;
    const entries = testEntries();
    return pfa.PageFrameAllocator.init(&entries, 0, &bitmap, null) catch unreachable;
}

test "init marks usable pages free" {
    var alloc = initAllocator();
    try std.testing.expectEqual(expected_free_pages, alloc.totalFreePages());
}

test "allocPage returns first free page" {
    var alloc = initAllocator();
    const page = try alloc.allocPage(false);
    try std.testing.expectEqual(@as(u64, 0x00100000), page);
    try std.testing.expectEqual(expected_free_pages - 1, alloc.totalFreePages());
}

test "allocPage never reuses without free" {
    var alloc = initAllocator();
    const p1 = try alloc.allocPage(false);
    const p2 = try alloc.allocPage(false);
    try std.testing.expect(p1 != p2);
    try std.testing.expectEqual(p1 + pfa.page_size, p2);
}

test "freePage then allocPage reuses" {
    var alloc = initAllocator();
    const p1 = try alloc.allocPage(false);
    try alloc.freePage(p1);
    const p2 = try alloc.allocPage(false);
    try std.testing.expectEqual(p1, p2);
}

test "freed middle page is reused by a later allocation" {
    var alloc = initAllocator();
    var pages: [8]u64 = undefined;
    for (0..pages.len) |i| pages[i] = try alloc.allocPage(false);
    try alloc.freePage(pages[4]);
    const reuse = try alloc.allocPage(false);
    // The freed middle page must be returned, not a new page at the end of
    // the region (hint-driven first-fit + free_pages cache consistency).
    try std.testing.expectEqual(pages[4], reuse);
}

test "free_pages cache tracks allocations and frees" {
    var alloc = initAllocator();
    try std.testing.expectEqual(expected_free_pages, alloc.totalFreePages());
    const p1 = try alloc.allocPage(false);
    _ = try alloc.allocPages(5, false);
    try std.testing.expectEqual(expected_free_pages - 6, alloc.totalFreePages());
    try alloc.freePage(p1);
    try alloc.freePages(&.{ 0x00201000, 0x00202000, 0x00203000, 0x00204000, 0x00205000 });
    try std.testing.expectEqual(expected_free_pages, alloc.totalFreePages());
}

test "freePage rejects double free" {
    var alloc = initAllocator();
    const page = try alloc.allocPage(false);
    try alloc.freePage(page);
    try std.testing.expectError(pfa.PfaError.NotAllocated, alloc.freePage(page));
}

test "freePage rejects invalid address" {
    var alloc = initAllocator();
    try std.testing.expectError(pfa.PfaError.InvalidAddress, alloc.freePage(0x123));
}

test "allocPages returns contiguous run" {
    var alloc = initAllocator();
    const pages = try alloc.allocPages(4, false);
    try std.testing.expectEqual(@as(usize, 4), pages.len);
    try std.testing.expectEqual(pages[0] + pfa.page_size, pages[1]);
    try std.testing.expectEqual(pages[0] + 2 * pfa.page_size, pages[2]);
}

test "allocator never hands out memory below low_memory_end" {
    // The PFA deliberately never allocates below 1 MiB (BIOS/limine low
    // memory; the direct map does not cover it). Exhausting the free pool
    // must never return a page under that boundary (audit regression, 7370ed5).
    var alloc = initAllocator();
    var pages: [expected_free_pages]u64 = undefined;
    for (0..pages.len) |i| pages[i] = try alloc.allocPage(false);
    for (pages) |p| try std.testing.expect(p >= pfa.low_memory_end);
}

test "freePages frees all" {
    var alloc = initAllocator();
    const pages = try alloc.allocPages(3, false);
    try alloc.freePages(pages);
    try std.testing.expectEqual(expected_free_pages, alloc.totalFreePages());
}

test "out of memory returns error" {
    var bitmap = [_]u8{0} ** 4096;
    const entries = [_]boot_info.MemoryEntry{
        .{ .base = 0x100000, .length = 0x2000, .type = .usable },
    };
    var alloc = pfa.PageFrameAllocator.init(&entries, 0, &bitmap, null) catch unreachable;
    _ = try alloc.allocPage(false);
    _ = try alloc.allocPage(false);
    try std.testing.expectError(pfa.PfaError.OutOfMemory, alloc.allocPage(false));
}
