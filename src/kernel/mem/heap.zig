const std = @import("std");
const pfa = @import("pfa.zig");

/// Heap grows in multi-page chunks. Lua's loadbuffer needs allocations
/// larger than a single 4 KiB page, so growing one page at a time would
/// never satisfy them.
const grow_pages: usize = 4;

const min_block_size: usize = @sizeOf(BlockHeader) * 2 + @sizeOf(BlockFooter);

const BlockHeader = struct {
    size: usize,
    free: bool,
    prev_free: ?*BlockHeader,
    next_free: ?*BlockHeader,
};

const BlockFooter = struct {
    size: usize,
};

pub const HeapAllocator = struct {
    pfa: pfa.PageFrameAllocator,
    free_list: ?*BlockHeader,

    pub fn init(alloc_pfa: *pfa.PageFrameAllocator) HeapAllocator {
        return .{
            .pfa = alloc_pfa.*,
            .free_list = null,
        };
    }

    pub fn allocator(self: *HeapAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .remap = remapFn,
                .free = freeFn,
            },
        };
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *HeapAllocator = @ptrCast(@alignCast(ctx));
        return self.rawAlloc(len, alignment) catch null;
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        _ = ctx;
        return false;
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *HeapAllocator = @ptrCast(@alignCast(ctx));
        const new_mem = self.rawAlloc(new_len, alignment) catch return null;
        const copy_len = @min(memory.len, new_len);
        @memcpy(new_mem[0..copy_len], memory[0..copy_len]);
        self.rawFree(memory.ptr, memory.len);
        return new_mem;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = alignment;
        _ = ret_addr;
        const self: *HeapAllocator = @ptrCast(@alignCast(ctx));
        self.rawFree(memory.ptr, memory.len);
    }

    fn rawAlloc(self: *HeapAllocator, len: usize, alignment: std.mem.Alignment) ![*]u8 {
        if (self.free_list == null) try self.grow();
        var found = self.findBlock(len + @sizeOf(BlockHeader) + @sizeOf(BlockFooter), alignment);
        if (found == null) {
            try self.grow();
            found = self.findBlock(len + @sizeOf(BlockHeader) + @sizeOf(BlockFooter), alignment) orelse return error.OutOfMemory;
        }
        const block = found.?;
        self.unlink(block);
        block.free = false;
        block.prev_free = null;
        block.next_free = null;

        const usable = self.usableSize(block);
        const split_size = std.mem.alignForward(usize, len + @sizeOf(BlockHeader) + @sizeOf(BlockFooter), 16);
        if (usable >= split_size + min_block_size) {
            self.split(block, split_size);
        }

        return self.dataPtr(block);
    }

    fn rawFree(self: *HeapAllocator, ptr: [*]u8, len: usize) void {
        _ = len;
        const block: *BlockHeader = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(BlockHeader));
        block.free = true;
        block.prev_free = null;
        block.next_free = null;
        const merged = self.coalesce(block);
        self.link(merged);
    }

    fn grow(self: *HeapAllocator) !void {
        const pages = try self.pfa.allocPages(grow_pages, true);
        const virtual = pages[0] + self.pfa.hhdm_offset;
        const block: *BlockHeader = @ptrFromInt(virtual);
        block.* = .{
            .size = grow_pages * pfa.page_size,
            .free = true,
            .prev_free = null,
            .next_free = null,
        };
        self.writeFooter(block);
        self.link(block);
    }

    fn findBlock(self: *HeapAllocator, size: usize, alignment: std.mem.Alignment) ?*BlockHeader {
        var it = self.free_list;
        while (it) |block| {
            if (self.usableSize(block) >= size and @intFromPtr(self.dataPtr(block)) % alignment.toByteUnits() == 0) {
                return block;
            }
            it = block.next_free;
        }
        return null;
    }

    fn split(self: *HeapAllocator, block: *BlockHeader, size: usize) void {
        const aligned_size = std.mem.alignForward(usize, size, 16);
        const remainder: *BlockHeader = @ptrFromInt(@intFromPtr(block) + aligned_size);
        remainder.* = .{
            .size = block.size - aligned_size,
            .free = true,
            .prev_free = null,
            .next_free = null,
        };
        self.writeFooter(remainder);
        block.size = aligned_size;
        self.writeFooter(block);
        self.link(remainder);
    }

    fn coalesce(self: *HeapAllocator, block_in: *BlockHeader) *BlockHeader {
        var block = block_in;
        const page_start = @intFromPtr(block) & ~(pfa.page_size - 1);
        const page_end = page_start + grow_pages * pfa.page_size;

        // backward merge — read the footer of the PREVIOUS block, not the
        // size of the current one (a boundary tag gives the true previous size)
        if (@intFromPtr(block) >= page_start + @sizeOf(BlockFooter)) {
            const prev_footer: *BlockFooter = @ptrFromInt(@intFromPtr(block) - @sizeOf(BlockFooter));
            const prev: *BlockHeader = @ptrFromInt(@intFromPtr(block) - prev_footer.size);
            if (@intFromPtr(prev) >= page_start and prev.free) {
                self.unlink(prev);
                prev.size += block.size;
                self.writeFooter(prev);
                block = prev; // continue with the merged block, no recursion
            }
        }

        // forward merge
        const next_addr = @intFromPtr(block) + block.size;
        if (next_addr < page_end) {
            const next: *BlockHeader = @ptrFromInt(next_addr);
            if (next.free) {
                self.unlink(next);
                block.size += next.size;
                self.writeFooter(block);
            }
        }

        return block;
    }

    fn link(self: *HeapAllocator, block: *BlockHeader) void {
        block.free = true;
        block.next_free = self.free_list;
        block.prev_free = null;
        if (self.free_list) |head| head.prev_free = block;
        self.free_list = block;
    }

    fn unlink(self: *HeapAllocator, block: *BlockHeader) void {
        if (block.prev_free) |prev| {
            prev.next_free = block.next_free;
        } else {
            self.free_list = block.next_free;
        }
        if (block.next_free) |next| next.prev_free = block.prev_free;
        block.prev_free = null;
        block.next_free = null;
    }

    fn dataPtr(self: *HeapAllocator, block: *BlockHeader) [*]u8 {
        _ = self;
        return @ptrFromInt(@intFromPtr(block) + @sizeOf(BlockHeader));
    }

    fn usableSize(self: *HeapAllocator, block: *BlockHeader) usize {
        _ = self;
        return block.size - @sizeOf(BlockHeader) - @sizeOf(BlockFooter);
    }

    fn writeFooter(self: *HeapAllocator, block: *BlockHeader) void {
        _ = self;
        const footer: *BlockFooter = @ptrFromInt(@intFromPtr(block) + block.size - @sizeOf(BlockFooter));
        footer.size = block.size;
    }
};
