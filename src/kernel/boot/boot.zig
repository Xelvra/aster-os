const std = @import("std");
const limine = @import("limine.zig");
const boot_info = @import("boot_info.zig");

pub const BootError = error{
    BaseRevisionUnsupported,
    NoHhdm,
};

pub fn collect() BootError!boot_info.BootInfo {
    if (!limine.base_revision_supported()) return BootError.BaseRevisionUnsupported;

    const hhdm_offset = limine.hhdm_offset() orelse return BootError.NoHhdm;
    const framebuffer = translateFramebuffer(limine.framebuffers());

    return .{
        .hhdm_offset = hhdm_offset,
        .framebuffer = framebuffer,
        .memory_entries = &.{},
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
