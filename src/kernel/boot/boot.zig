const limine = @import("limine.zig");
const boot_info = @import("boot_info.zig");
const std = @import("std");

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
    const initrd = collectInitrd();
    const rsdp_address = if (limine.rsdp()) |r| r.address else null;

    return .{
        .hhdm_offset = hhdm_offset,
        .framebuffer = framebuffer,
        .memory_entries = memory_entries,
        .initrd = initrd,
        .rsdp_address = rsdp_address,
        .kernel_size = limine.kernelSize() orelse 0,
    };
}

/// The first bootloader module (the initrd tar). Limine hands its address
/// already mapped into the higher half, so no hhdm translation is applied.
/// A zero-sized or zero-address module is treated as absent (audit
/// 2026-08-15) — the shell runs with defaults instead of slicing garbage.
fn collectInitrd() ?[]const u8 {
    const resp = limine.modules() orelse return null;
    if (resp.module_count == 0) return null;
    const mod = resp.modules[0] orelse return null;
    if (mod.address == 0 or mod.size == 0) return null;
    return @as([*]const u8, @ptrFromInt(@as(usize, @intCast(mod.address))))[0..@intCast(mod.size)];
}

fn translateMemoryEntries() BootError![]const boot_info.MemoryEntry {
    const memmap = limine.memmap() orelse return BootError.NoMemoryMap;
    // The storage is fixed-size (64 entries); reading past it would walk
    // foreign memory, so the count is clamped to it and the boot log notes a
    // silently-truncated map (2026-08-15-self-audit).
    const count = @min(memmap.entry_count, max_memory_entries);
    for (0..count) |i| {
        const entry = memmap.entries[i] orelse continue;
        memory_entries_storage[i] = .{
            .base = entry.base,
            .length = entry.length,
            .type = translateEntryType(entry.type),
        };
    }
    if (memmap.entry_count > max_memory_entries) {
        const serial = @import("../serial.zig");
        var buf: [48]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "memmap: truncated to {d} entries", .{max_memory_entries}) catch "memmap: truncated";
        serial.writeLine(line);
    }
    return memory_entries_storage[0..count];
}

/// Map a bootloader memory-map type to the kernel's own enum. Unknown types
/// are mapped to reserved — never usable — so a new/unknown type cannot make
/// the allocator treat random memory as free (2026-08-15-self-audit).
fn translateEntryType(raw: u64) boot_info.MemoryEntryType {
    return switch (raw) {
        0 => .usable,
        1 => .reserved,
        2 => .acpi_reclaimable,
        3 => .acpi_nvs,
        4 => .bad_memory,
        5 => .bootloader_reclaimable,
        6 => .executable_and_modules,
        7 => .framebuffer,
        8 => .reserved_mapped,
        else => .reserved,
    };
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
