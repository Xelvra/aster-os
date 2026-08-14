const std = @import("std");
const pfa = @import("pfa.zig");
const irq = @import("../cpu/irq.zig");
const serial = @import("../serial.zig");

/// Heap grows in multi-page chunks. Lua's loadbuffer needs allocations
/// larger than a single 4 KiB page, so growing one page at a time would
/// never satisfy them.
const grow_pages: usize = 4;

/// `rawAlloc`/`rawFree` manipulate the shared free list under an interrupt
/// mask (ADR-017): with the preemptive scheduler (M7+) a task could be
/// preempted mid-allocation and another task would then work on an
/// inconsistent list. `grow()` calls `pfa.allocPages()`, whose own guard
/// sees IF already cleared and re-enables nothing — nesting is safe because
/// the restore decision comes from RFLAGS, not a refcount.
const min_block_size: usize = @sizeOf(BlockHeader) * 2 + @sizeOf(BlockFooter);

/// Canary written into every block header. If memory corruption ever turns a
/// foreign buffer into a "block", checkBlock() fires while it is still being
/// used — pinpointing the corrupter instead of failing three tests later.
const block_magic: u64 = 0x41535445424C4B31; // "ASTEBLK1"

const BlockHeader = struct {
    magic: u64,
    size: usize,
    free: bool,
    prev_free: ?*BlockHeader,
    next_free: ?*BlockHeader,
    /// End (exclusive) of the grow region this block belongs to. Coalescing
    /// must never merge across this boundary — grow can allocate more than
    /// `grow_pages` (e.g. 5 pages), so a fixed window would over-read into
    /// whatever follows the region (a framebuffer back buffer caused a #GP).
    grow_end: usize,
};

/// Stop with a clear marker when a block header does not carry the canary —
/// the heap has been corrupted (use-after-free, overflow, or a foreign buffer
/// misread as a block). Halt, do not continue on corrupt state.
fn checkBlock(block: *BlockHeader) void {
    if (block.magic == block_magic) return;
    var cb: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&cb, "HEAP CORRUPTION at block {x:0>12}", .{@intFromPtr(block)}) catch "HEAP CORRUPTION";
    serial.writeLine(line);
    while (true) asm volatile ("hlt" ::: .{ .memory = true });
}

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
        const guard = irq.begin();
        defer guard.end();
        const need = len + @sizeOf(BlockHeader) + @sizeOf(BlockFooter);
        if (self.free_list == null) try self.grow(need);
        var found = self.findBlock(need, alignment);
        if (found == null) {
            try self.grow(need);
            found = self.findBlock(need, alignment) orelse return error.OutOfMemory;
        }
        const block = found.?;
        checkBlock(block);
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
        const guard = irq.begin();
        defer guard.end();
        _ = len;
        const block: *BlockHeader = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(BlockHeader));
        checkBlock(block);
        block.free = true;
        block.prev_free = null;
        block.next_free = null;
        const merged = self.coalesce(block);
        self.link(merged);
    }

    /// Grow the heap by enough contiguous pages to hold at least `min_bytes`
    /// of payload plus block overhead. A single grow block is contiguous, so a
    /// large allocation (e.g. the shell source buffer) is satisfiable. The
    /// block overhead is added before rounding up to whole pages: `min_bytes`
    /// already includes it, so the region must cover `min_bytes` bytes of
    /// usable space, i.e. `min_bytes + header + footer` of raw pages.
    fn grow(self: *HeapAllocator, min_bytes: usize) !void {
        const with_overhead = min_bytes + @sizeOf(BlockHeader) + @sizeOf(BlockFooter);
        const min_pages = (with_overhead + pfa.page_size - 1) / pfa.page_size;
        const pages_count = @max(grow_pages, min_pages);
        const pages = try self.pfa.allocPages(pages_count, true);
        const virtual = pages[0] + self.pfa.hhdm_offset;
        const grow_end = virtual + pages_count * pfa.page_size;
        const block: *BlockHeader = @ptrFromInt(virtual);
        block.* = .{
            .magic = block_magic,
            .size = pages_count * pfa.page_size,
            .free = true,
            .prev_free = null,
            .next_free = null,
            .grow_end = grow_end,
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
            .magic = block_magic,
            .size = block.size - aligned_size,
            .free = true,
            .prev_free = null,
            .next_free = null,
            .grow_end = block.grow_end,
        };
        self.writeFooter(remainder);
        block.size = aligned_size;
        self.writeFooter(block);
        self.link(remainder);
    }

    fn coalesce(self: *HeapAllocator, block_in: *BlockHeader) *BlockHeader {
        var block = block_in;
        checkBlock(block);
        const page_start = @intFromPtr(block) & ~(pfa.page_size - 1);

        // backward merge — read the footer of the PREVIOUS block, not the
        // size of the current one (a boundary tag gives the true previous size)
        if (@intFromPtr(block) >= page_start + @sizeOf(BlockFooter)) {
            const prev_footer: *BlockFooter = @ptrFromInt(@intFromPtr(block) - @sizeOf(BlockFooter));
            const prev: *BlockHeader = @ptrFromInt(@intFromPtr(block) - prev_footer.size);
            if (@intFromPtr(prev) >= page_start and prev.free) {
                checkBlock(prev);
                self.unlink(prev);
                prev.size += block.size;
                self.writeFooter(prev);
                block = prev; // continue with the merged block, no recursion
            }
        }

        // forward merge, bounded by the grow region this block belongs to
        const next_addr = @intFromPtr(block) + block.size;
        if (next_addr < block.grow_end) {
            const next: *BlockHeader = @ptrFromInt(next_addr);
            if (next.free) {
                checkBlock(next);
                self.unlink(next);
                block.size += next.size;
                self.writeFooter(block);
            }
        }

        return block;
    }

    fn link(self: *HeapAllocator, block: *BlockHeader) void {
        checkBlock(block);
        block.free = true;
        block.next_free = self.free_list;
        block.prev_free = null;
        if (self.free_list) |head| head.prev_free = block;
        self.free_list = block;
    }
    fn unlink(self: *HeapAllocator, block: *BlockHeader) void {
        checkBlock(block);
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
