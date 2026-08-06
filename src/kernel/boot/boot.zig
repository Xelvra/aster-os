const std = @import("std");
const limine = @import("limine.zig");
const boot_info = @import("boot_info.zig");

pub const BootError = error{
    BaseRevisionUnsupported,
    NoHhdm,
    NoMemoryMap,
};

const max_memory_entries = 64;
var memory_entries_storage: [max_memory_entries]boot_info.MemoryEntry = undefined;

pub fn collect() BootError!boot_info.BootInfo {
    if (!limine.base_revision_supported()) return BootError.BaseRevisionUnsupported;

    const hhdm_offset = limine.hhdm_offset() orelse return BootError.NoHhdm;
    const framebuffer = translateFramebuffer(limine.framebuffers());
    const memory_entries = try translateMemoryEntries();

    return .{
        .hhdm_offset = hhdm_offset,
        .framebuffer = framebuffer,
        .memory_entries = memory_entries,
    };
}

fn translateMemoryEntries() BootError![]const boot_info.MemoryEntry {
    const memmap = limine.memmap() orelse return BootError.NoMemoryMap;
    const count = @min(memmap.entry_count, max_memory_entries);
    for (0..count) |i| {
        const entry = memmap.entries[i] orelse continue;
        memory_entries_storage[i] = .{
            .base = entry.base,
            .length = entry.length,
            .type = translateEntryType(entry.type),
        };
    }
    return memory_entries_storage[0..count];
}

fn translateEntryType(raw: u64) boot_info.MemoryEntryType {
    return @enumFromInt(raw);
}

fn translateFramebuffer(response: ?*const limine.framebuffer_response) ?boot_info.Framebuffer {
    const resp = response orelse return null;
    if (resp.framebuffer_count == 0) return null;
    const fb = resp.framebuffers[0] orelse return null;
    return .{
        .address = fb.address,
        .width = fb.width,
        .height = fb.height,
        .pitch = fb.pitch,
        .bpp = fb.bpp,
        .memory_model = fb.memory_model,
        .red_mask_size = fb.red_mask_size,
        .red_mask_shift = fb.red_mask_shift,
        .green_mask_size = fb.green_mask_size,
        .green_mask_shift = fb.green_mask_shift,
        .blue_mask_size = fb.blue_mask_size,
        .blue_mask_shift = fb.blue_mask_shift,
    };
}
