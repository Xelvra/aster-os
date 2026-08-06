const std = @import("std");
const pfa = @import("kernel").pfa;
const heap = @import("kernel").heap;
const boot_info = @import("kernel").boot_info;

const RamSize = 0x400000;
const Context = struct {
    ram: [RamSize]u8 align(4096),
    bitmap: [8192]u8,
    pfa: pfa.PageFrameAllocator,
    heap_alloc: heap.HeapAllocator,
};

test "alloc and free" {
    var ctx: Context = undefined;
    ctx.ram = [_]u8{0} ** RamSize;
    ctx.bitmap = [_]u8{0} ** 8192;
    const hhdm = @intFromPtr(&ctx.ram) - @as(u64, 0x100000);
    const entries = [_]boot_info.MemoryEntry{.{ .base = 0x100000, .length = RamSize, .type = .usable }};
    ctx.pfa = pfa.PageFrameAllocator.init(&entries, hhdm, &ctx.bitmap, null) catch unreachable;
    ctx.heap_alloc = heap.HeapAllocator.init(&ctx.pfa);
    const alloc = ctx.heap_alloc.allocator();
    const buf = try alloc.alloc(u8, 32);
    defer alloc.free(buf);
    try std.testing.expectEqual(@as(usize, 32), buf.len);
    @memset(buf, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), buf[31]);
}

test "alloc memory is writable and readable" {
    var ctx: Context = undefined;
    ctx.ram = [_]u8{0} ** RamSize;
    ctx.bitmap = [_]u8{0} ** 8192;
    const hhdm = @intFromPtr(&ctx.ram) - @as(u64, 0x100000);
    const entries = [_]boot_info.MemoryEntry{.{ .base = 0x100000, .length = RamSize, .type = .usable }};
    ctx.pfa = pfa.PageFrameAllocator.init(&entries, hhdm, &ctx.bitmap, null) catch unreachable;
    ctx.heap_alloc = heap.HeapAllocator.init(&ctx.pfa);
    const alloc = ctx.heap_alloc.allocator();
    const buf = try alloc.alloc(u8, 1000);
    defer alloc.free(buf);
    @memset(buf, 0x42);
    for (buf) |b| try std.testing.expectEqual(@as(u8, 0x42), b);
}

test "realloc grows and preserves data" {
    var ctx: Context = undefined;
    ctx.ram = [_]u8{0} ** RamSize;
    ctx.bitmap = [_]u8{0} ** 8192;
    const hhdm = @intFromPtr(&ctx.ram) - @as(u64, 0x100000);
    const entries = [_]boot_info.MemoryEntry{.{ .base = 0x100000, .length = RamSize, .type = .usable }};
    ctx.pfa = pfa.PageFrameAllocator.init(&entries, hhdm, &ctx.bitmap, null) catch unreachable;
    ctx.heap_alloc = heap.HeapAllocator.init(&ctx.pfa);
    const alloc = ctx.heap_alloc.allocator();
    var buf = try alloc.alloc(u8, 16);
    defer alloc.free(buf);
    @memset(buf, 0xAA);
    buf = try alloc.realloc(buf, 64);
    try std.testing.expectEqual(@as(usize, 64), buf.len);
    try std.testing.expectEqual(@as(u8, 0xAA), buf[15]);
}

test "alloc different sizes does not overlap" {
    var ctx: Context = undefined;
    ctx.ram = [_]u8{0} ** RamSize;
    ctx.bitmap = [_]u8{0} ** 8192;
    const hhdm = @intFromPtr(&ctx.ram) - @as(u64, 0x100000);
    const entries = [_]boot_info.MemoryEntry{.{ .base = 0x100000, .length = RamSize, .type = .usable }};
    ctx.pfa = pfa.PageFrameAllocator.init(&entries, hhdm, &ctx.bitmap, null) catch unreachable;
    ctx.heap_alloc = heap.HeapAllocator.init(&ctx.pfa);
    const alloc = ctx.heap_alloc.allocator();
    const a = try alloc.alloc(u8, 100);
    const b = try alloc.alloc(u8, 200);
    const c = try alloc.alloc(u8, 300);
    defer alloc.free(c);
    defer alloc.free(b);
    defer alloc.free(a);
    const pa = @intFromPtr(a.ptr);
    const pb = @intFromPtr(b.ptr);
    const pc = @intFromPtr(c.ptr);
    try std.testing.expect(pa != pb and pa != pc and pb != pc);
    @memset(a, 0x11);
    @memset(b, 0x22);
    @memset(c, 0x33);
    try std.testing.expectEqual(@as(u8, 0x11), a[0]);
    try std.testing.expectEqual(@as(u8, 0x22), b[0]);
    try std.testing.expectEqual(@as(u8, 0x33), c[0]);
}

test "coalescing: free neighbors merge" {
    var ctx: Context = undefined;
    ctx.ram = [_]u8{0} ** RamSize;
    ctx.bitmap = [_]u8{0} ** 8192;
    const hhdm = @intFromPtr(&ctx.ram) - @as(u64, 0x100000);
    const entries = [_]boot_info.MemoryEntry{.{ .base = 0x100000, .length = RamSize, .type = .usable }};
    ctx.pfa = pfa.PageFrameAllocator.init(&entries, hhdm, &ctx.bitmap, null) catch unreachable;
    ctx.heap_alloc = heap.HeapAllocator.init(&ctx.pfa);
    const alloc = ctx.heap_alloc.allocator();
    const a = try alloc.alloc(u8, 48);
    const b = try alloc.alloc(u8, 48);
    const c = try alloc.alloc(u8, 48);
    alloc.free(b);
    alloc.free(a);
    alloc.free(c);
    const big = try alloc.alloc(u8, 200);
    try std.testing.expect(big.len == 200);
    alloc.free(big);
}

test "out of memory when heap exhausted" {
    var ctx: Context = undefined;
    ctx.ram = [_]u8{0} ** RamSize;
    ctx.bitmap = [_]u8{0} ** 8192;
    const hhdm = @intFromPtr(&ctx.ram) - @as(u64, 0x100000);
    const entries = [_]boot_info.MemoryEntry{.{ .base = 0x100000, .length = RamSize, .type = .usable }};
    ctx.pfa = pfa.PageFrameAllocator.init(&entries, hhdm, &ctx.bitmap, null) catch unreachable;
    ctx.heap_alloc = heap.HeapAllocator.init(&ctx.pfa);
    const alloc = ctx.heap_alloc.allocator();

    var bufs: [1100][]u8 = undefined;
    var count: usize = 0;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const buf = alloc.alloc(u8, 4000) catch break;
        bufs[count] = buf;
        count += 1;
        if (count == bufs.len) break;
    }
    try std.testing.expect(count < bufs.len);
    try std.testing.expect(count > 1000);
    try std.testing.expectError(std.mem.Allocator.Error.OutOfMemory, alloc.alloc(u8, 4000));
}
