const std = @import("std");
const pci = @import("pci.zig");
const pfa = @import("../mem/pfa.zig");
const page_map = @import("../mem/page_map.zig");
const block = @import("block.zig");

/// virtio-blk over the modern (capability-based) PCI transport. Only the
/// blocks needed to read and write sectors are implemented: one split
/// virtqueue, no feature negotiation beyond the bare minimum. QEMU's
/// virtio-blk-pci is expected; the device is found by vendor/device id
/// (0x1af4:0x1001 on q35 without disable-legacy, 0x1af4:0x1042 with it — both
/// expose the modern capability layout).
pub const VirtioError = error{
    NotFound,
    InitFailed,
    QueueFailed,
    NoSupport,
    IoError,
    OutOfMemory,
};

const blk_vendor: u16 = 0x1AF4;
const blk_device_transitional: u16 = 0x1001;
const blk_device_modern: u16 = 0x1042;

const cap_vndr: u8 = 0x09;
const cfg_type_common: u8 = 1;
const cfg_type_notify: u8 = 2;
const cfg_type_isr: u8 = 3;
const cfg_type_device: u8 = 4;

const status_acknowledge: u8 = 1;
const status_driver: u8 = 2;
const status_features_ok: u8 = 8;
const status_driver_ok: u8 = 4;
const status_failed: u8 = 128;

const queue_max: u16 = 256;

const desc_f_next: u16 = 1;
const desc_f_write: u16 = 2;

const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

const VirtqAvail = extern struct {
    flags: u16,
    idx: u16,
    ring: [queue_max]u16,
    used_event: u16,
};

const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,
};

const VirtqUsed = extern struct {
    flags: u16,
    idx: u16,
    ring: [queue_max]VirtqUsedElem,
    avail_event: u16,
};

const BlkReqHeader = extern struct {
    type: u32,
    reserved: u32,
    sector: u64,
};

const blk_req_in: u32 = 0;
const blk_req_out: u32 = 1;

/// Full memory fence for the virtio ring protocol (ring writes must be
/// visible before the queue notification).
fn fence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

const CommonCfg = extern struct {
    device_feature_select: u32,
    device_feature: u32,
    driver_feature_select: u32,
    driver_feature: u32,
    msix_config: u16,
    num_queues: u16,
    device_status: u8,
    config_generation: u8,
    queue_select: u16,
    queue_size: u16,
    queue_msix_vector: u16,
    queue_enable: u16,
    queue_notify_off: u16,
    queue_desc: u64,
    queue_driver: u64,
    queue_device: u64,
    queue_notify_data: u16,
    queue_reset: u16,
};

const VirtioCap = extern struct {
    cap_vndr: u8,
    cap_next: u8,
    cap_len: u8,
    cfg_type: u8,
    bar: u8,
    padding: [3]u8,
    offset: u32,
    length: u32,
};

fn readCap(device: pci.Device, offset: u8) VirtioCap {
    const lo = pci.readConfig32(device.bus, device.slot, device.func, offset);
    const hi = pci.readConfig32(device.bus, device.slot, device.func, offset + 4);
    return .{
        .cap_vndr = @truncate(lo),
        .cap_next = @truncate(lo >> 8),
        .cap_len = @truncate(lo >> 16),
        .cfg_type = @truncate(lo >> 24),
        .bar = @truncate(hi),
        .padding = .{ @truncate(hi >> 8), @truncate(hi >> 16), @truncate(hi >> 24) },
        .offset = pci.readConfig32(device.bus, device.slot, device.func, offset + 8),
        .length = pci.readConfig32(device.bus, device.slot, device.func, offset + 12),
    };
}

const VirtQueue = struct {
    desc: [*]VirtqDesc,
    avail: *VirtqAvail,
    used: *VirtqUsed,
    size: u16,
    next_desc: u16,
    last_seen_used: u16,
    notify_off: u16,

    /// Read the used ring's idx through a volatile pointer: the device writes
    /// it by DMA, so the compiler must not cache it across a completion spin
    /// loop (audit 2026-08-15).
    fn usedIndex(self: *const VirtQueue) u16 {
        const idx_ptr: *const volatile u16 = @ptrFromInt(@intFromPtr(self.used) + 2); // VirtqUsed.idx
        return idx_ptr.*;
    }
};

/// Read a device-written completion byte through a volatile pointer (audit
/// 2026-08-15): the device DMA-writes status before updating the used ring.
fn volatileU8(ptr: *u8) u8 {
    return @as(*const volatile u8, @ptrCast(ptr)).*;
}

pub const VirtioBlk = struct {
    allocator: std.mem.Allocator,
    hhdm_offset: u64,
    pfa_inst: *pfa.PageFrameAllocator,
    common: *volatile CommonCfg,
    notify_base: u64,
    notify_multiplier: u32,
    queue: VirtQueue,

    pub fn init(allocator: std.mem.Allocator, pfa_inst: *pfa.PageFrameAllocator, hhdm_offset: u64) VirtioError!VirtioBlk {
        const device = pci.findDevice(blk_vendor, blk_device_modern) orelse
            pci.findDevice(blk_vendor, blk_device_transitional) orelse
            return error.NotFound;

        var common_addr: u64 = 0;
        var notify_addr: u64 = 0;
        var notify_mult: u32 = 0;
        var bar_end: [6]u64 = .{ 0, 0, 0, 0, 0, 0 };

        const caps_offset = pci.readConfig8(device.bus, device.slot, device.func, 0x34);
        var cap_offset: u8 = caps_offset;
        // Bound the capability chain walk so a cyclic cap_next cannot spin the
        // CPU forever (audit 2026-08-15).
        var cap_iter: u32 = 0;
        while (cap_offset != 0 and cap_iter < 256) : (cap_iter += 1) {
            const id = pci.readConfig8(device.bus, device.slot, device.func, cap_offset);
            if (id == cap_vndr) {
                const cap = readCap(device, cap_offset);
                if (device.barAddress(cap.bar)) |bar_phys| {
                    const end: u64 = @as(u64, cap.offset) + cap.length;
                    if (end > bar_end[cap.bar]) bar_end[cap.bar] = end;
                    const region_end: u64 = bar_phys + cap.offset;
                    switch (cap.cfg_type) {
                        cfg_type_common => common_addr = region_end,
                        cfg_type_notify => {
                            notify_addr = region_end;
                            notify_mult = pci.readConfig32(device.bus, device.slot, device.func, cap_offset + 16);
                        },
                        else => {},
                    }
                }
            }
            cap_offset = pci.readConfig8(device.bus, device.slot, device.func, cap_offset + 1);
        }

        for (0..bar_end.len) |i| {
            if (bar_end[i] == 0) continue;
            const pages_needed = (bar_end[i] + pfa.page_size - 1) / pfa.page_size;
            const bar_phys = device.barAddress(i) orelse continue;
            const bar_base_page = bar_phys - bar_phys % pfa.page_size;
            for (0..pages_needed) |j| {
                page_map.mapPage(hhdm_offset + bar_base_page + j * pfa.page_size, bar_base_page + j * pfa.page_size, page_map.rw);
            }
        }

        if (common_addr == 0 or notify_addr == 0) return error.InitFailed;
        const common = @as(*volatile CommonCfg, @ptrFromInt(hhdm_offset + common_addr));
        const notify_base = hhdm_offset + notify_addr;

        return VirtioBlk{
            .allocator = allocator,
            .hhdm_offset = hhdm_offset,
            .pfa_inst = pfa_inst,
            .common = common,
            .notify_base = notify_base,
            .notify_multiplier = notify_mult,
            .queue = undefined,
        };
    }

    pub fn setupQueue(self: *VirtioBlk) VirtioError!void {
        const common = self.common;
        common.device_status = 0;
        // Bound the reset wait so a misbehaving device cannot hang boot
        // (audit 2026-08-15).
        var reset_spins: u32 = 0;
        while (common.device_status != 0) : (reset_spins += 1) {
            if (reset_spins > 1_000_000) return VirtioError.IoError;
            std.atomic.spinLoopHint();
        }

        common.device_status = status_acknowledge;
        common.device_status = status_acknowledge | status_driver;

        common.device_feature_select = 0;
        _ = common.device_feature;
        common.device_feature_select = 1;
        _ = common.device_feature;
        common.driver_feature_select = 0;
        common.driver_feature = 0;
        common.driver_feature_select = 1;
        common.driver_feature = 1; // VIRTIO_F_VERSION_1: use the modern queue layout

        common.device_status = status_acknowledge | status_driver | status_features_ok;
        if (common.device_status & status_features_ok == 0) return error.InitFailed;

        common.queue_select = 0;
        const size = common.queue_size;
        if (size < 3 or size > queue_max) return error.QueueFailed;

        const desc_phys = self.pfa_inst.allocPage(true) catch return error.QueueFailed;
        const avail_phys = self.pfa_inst.allocPage(true) catch return error.QueueFailed;
        const used_phys = self.pfa_inst.allocPage(true) catch return error.QueueFailed;

        common.queue_desc = desc_phys;
        common.queue_driver = avail_phys;
        common.queue_device = used_phys;
        common.queue_enable = 1;
        if (common.queue_enable == 0) return error.QueueFailed;

        const notify_off = common.queue_notify_off;
        const desc = @as([*]VirtqDesc, @ptrFromInt(desc_phys + self.hhdm_offset));
        const avail = @as(*VirtqAvail, @ptrFromInt(avail_phys + self.hhdm_offset));
        const used = @as(*VirtqUsed, @ptrFromInt(used_phys + self.hhdm_offset));

        self.queue = .{
            .desc = desc,
            .avail = avail,
            .used = used,
            .size = size,
            .next_desc = 0,
            .last_seen_used = 0,
            .notify_off = notify_off,
        };

        common.device_status = status_acknowledge | status_driver | status_features_ok | status_driver_ok;
        if (common.device_status & status_failed != 0) return error.InitFailed;
    }

    /// Expose the driver behind the block-device interface so the GPT and
    /// filesystem layers never depend on virtio directly.
    pub fn asBlockDevice(self: *VirtioBlk) block.BlockDevice {
        return .{
            .ctx = self,
            .read_fn = blockRead,
            .write_fn = blockWrite,
        };
    }

    fn blockRead(ctx: *anyopaque, sector: u64, out: []u8) block.BlockError!void {
        const blk: *VirtioBlk = @ptrCast(@alignCast(ctx));
        blk.readSector(sector, out) catch return error.IoError;
    }

    fn blockWrite(ctx: *anyopaque, sector: u64, in: []const u8) block.BlockError!void {
        const blk: *VirtioBlk = @ptrCast(@alignCast(ctx));
        blk.writeSector(sector, in) catch return error.IoError;
    }

    /// Write one 512-byte sector from in. The data buffer handed to the device
    /// is heap-backed (phys = virt - hhdm_offset holds, as in readSector).
    pub fn writeSector(self: *VirtioBlk, sector: u64, in: []const u8) VirtioError!void {
        if (in.len != 512) return error.NoSupport;

        const header = try self.allocator.create(BlkReqHeader);
        defer self.allocator.destroy(header);
        const status_byte = try self.allocator.create(u8);
        defer self.allocator.destroy(status_byte);
        const data = try self.allocator.alloc(u8, 512);
        defer self.allocator.free(data);

        header.* = .{ .type = blk_req_out, .reserved = 0, .sector = sector };
        status_byte.* = 0xFF;
        @memcpy(data, in);

        if (self.queue.next_desc + 3 > self.queue.size) {
            self.queue.next_desc = 0;
        }
        const head = self.queue.next_desc;
        const desc = self.queue.desc;
        desc[head] = .{
            .addr = @intFromPtr(header) - self.hhdm_offset,
            .len = @sizeOf(BlkReqHeader),
            .flags = desc_f_next,
            .next = head + 1,
        };
        desc[head + 1] = .{
            .addr = @intFromPtr(data.ptr) - self.hhdm_offset,
            .len = @intCast(data.len),
            .flags = desc_f_next,
            .next = head + 2,
        };
        desc[head + 2] = .{
            .addr = @intFromPtr(status_byte) - self.hhdm_offset,
            .len = 1,
            .flags = desc_f_write,
            .next = 0xFFFF,
        };
        self.queue.next_desc = head + 3;

        fence();
        const avail_idx = self.queue.avail.idx;
        self.queue.avail.ring[avail_idx % self.queue.size] = head;
        fence();
        self.queue.avail.idx = avail_idx + 1;
        fence();

        const notify_addr = self.notify_base + @as(u64, self.queue.notify_off) * self.notify_multiplier;
        @as(*volatile u16, @ptrFromInt(notify_addr)).* = 0;

        var spins: usize = 0;
        while (self.queue.usedIndex() == self.queue.last_seen_used) : (spins += 1) {
            if (spins > 100_000_000) return error.IoError;
            std.atomic.spinLoopHint();
        }
        self.queue.last_seen_used = self.queue.usedIndex();

        if (volatileU8(status_byte) != 0) return error.IoError;
    }

    /// Read one 512-byte sector into out. A heap-backed buffer is used for
    /// the DMA data (the heap lives in the hhdm mapping, so phys = virt -
    /// hhdm_offset holds for every block handed to the device).
    pub fn readSector(self: *VirtioBlk, sector: u64, out: []u8) VirtioError!void {
        if (out.len != 512) return error.NoSupport;

        const header = try self.allocator.create(BlkReqHeader);
        defer self.allocator.destroy(header);
        const status_byte = try self.allocator.create(u8);
        defer self.allocator.destroy(status_byte);
        const data = try self.allocator.alloc(u8, 512);
        defer self.allocator.free(data);

        header.* = .{ .type = blk_req_in, .reserved = 0, .sector = sector };
        status_byte.* = 0xFF;

        // The previous chain is consumed (we wait on the used ring below), so
        // descriptor slots can be reused. Cycle the head so head+2 stays within
        // the descriptor table (size entries).
        if (self.queue.next_desc + 3 > self.queue.size) {
            self.queue.next_desc = 0;
        }
        const head = self.queue.next_desc;
        const desc = self.queue.desc;
        desc[head] = .{
            .addr = @intFromPtr(header) - self.hhdm_offset,
            .len = @sizeOf(BlkReqHeader),
            .flags = desc_f_next,
            .next = head + 1,
        };
        desc[head + 1] = .{
            .addr = @intFromPtr(data.ptr) - self.hhdm_offset,
            .len = @intCast(data.len),
            .flags = desc_f_write | desc_f_next,
            .next = head + 2,
        };
        desc[head + 2] = .{
            .addr = @intFromPtr(status_byte) - self.hhdm_offset,
            .len = 1,
            .flags = desc_f_write,
            .next = 0xFFFF,
        };
        self.queue.next_desc = head + 3;

        fence();
        const avail_idx = self.queue.avail.idx;
        self.queue.avail.ring[avail_idx % self.queue.size] = head;
        fence();
        self.queue.avail.idx = avail_idx + 1;
        fence();

        const notify_addr = self.notify_base + @as(u64, self.queue.notify_off) * self.notify_multiplier;
        @as(*volatile u16, @ptrFromInt(notify_addr)).* = 0;

        var spins: usize = 0;
        while (self.queue.usedIndex() == self.queue.last_seen_used) : (spins += 1) {
            if (spins > 100_000_000) return error.IoError;
            std.atomic.spinLoopHint();
        }
        self.queue.last_seen_used = self.queue.usedIndex();

        if (volatileU8(status_byte) != 0) return error.IoError;
        @memcpy(out, data);
    }
};
