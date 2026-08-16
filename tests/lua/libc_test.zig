const std = @import("std");
const libc = @import("kernel").libc;

test "malloc/free round-trip" {
    libc.setHeapAllocator(std.testing.allocator);
    const p = libc.malloc(64).?;
    const bytes: [*]u8 = @ptrCast(p);
    var i: usize = 0;
    while (i < 64) : (i += 1) bytes[i] = @intCast(i & 0xff);
    var j: usize = 0;
    while (j < 64) : (j += 1) try std.testing.expectEqual(@as(u8, @intCast(j & 0xff)), bytes[j]);
    libc.free(p);
}

test "malloc(0) returns a freeable block" {
    libc.setHeapAllocator(std.testing.allocator);
    const p = libc.malloc(0).?;
    libc.free(p);
}

test "realloc grows and copies old data" {
    libc.setHeapAllocator(std.testing.allocator);
    const p = libc.malloc(16).?;
    const bytes: [*]u8 = @ptrCast(p);
    var i: usize = 0;
    while (i < 16) : (i += 1) bytes[i] = 0xAB;
    const grown = libc.realloc(p, 64).?;
    const g: [*]u8 = @ptrCast(grown);
    var j: usize = 0;
    while (j < 16) : (j += 1) try std.testing.expectEqual(@as(u8, 0xAB), g[j]);
    libc.free(grown);
}

test "realloc shrink keeps the block and free releases the right length" {
    // Audit 2026-08-15: a shrink used to overwrite the stored size, so the
    // later free() recomputed a smaller block and released the wrong length.
    libc.setHeapAllocator(std.testing.allocator);
    const p = libc.malloc(64).?;
    const bytes: [*]u8 = @ptrCast(p);
    var i: usize = 0;
    while (i < 64) : (i += 1) bytes[i] = 0xCD;
    const shrunk = libc.realloc(p, 16).?;
    // Shrink returns the same pointer (the allocation is kept whole).
    try std.testing.expectEqual(p, shrunk);
    libc.free(shrunk);
    // The testing allocator would panic here if free used the wrong length.
}

test "realloc(ptr, 0) frees" {
    libc.setHeapAllocator(std.testing.allocator);
    const p = libc.malloc(32).?;
    try std.testing.expect(libc.realloc(p, 0) == null);
}

test "calloc zeroes the block" {
    libc.setHeapAllocator(std.testing.allocator);
    const p = libc.calloc(10, 4).?;
    const bytes: [*]u8 = @ptrCast(p);
    var i: usize = 0;
    while (i < 40) : (i += 1) try std.testing.expectEqual(@as(u8, 0), bytes[i]);
    libc.free(p);
}
