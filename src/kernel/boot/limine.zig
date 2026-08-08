export var requests_start_marker: [4]u64 linksection(".limine_requests") = .{ 0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf, 0x785c6ed015d3e316, 0x181e920a7852b9d9 };
export var requests_end_marker: [2]u64 linksection(".limine_requests") = .{ 0xadc0e0531bb10d03, 0x9572709f31764c62 };

pub const hhdm_response = extern struct {
    revision: u64,
    offset: u64,
};

pub const hhdm_request = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*hhdm_response,
};

pub const framebuffer = extern struct {
    address: u64,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    unused: [7]u8,
    edid_size: u64,
    edid: u64,
    mode_count: u64,
    modes: u64,
};

pub const framebuffer_response = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers: [*]?*framebuffer,
};

pub const framebuffer_request = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*framebuffer_response,
};

pub const memmap_entry = extern struct {
    base: u64,
    length: u64,
    type: u64,
};

pub const memmap_response = extern struct {
    revision: u64,
    entry_count: u64,
    entries: [*]?*memmap_entry,
};

pub const memmap_request = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*memmap_response,
};

pub const file = extern struct {
    revision: u64,
    address: u64,
    size: u64,
    path: u64,
    string: u64,
    media_type: u32,
    unused: u32,
    tftp_ipv4: [4]u8,
    tftp_port: u32,
    partition_index: u32,
    mbr_disk_id: u32,
    gpt_disk_uuid: [16]u8,
    gpt_part_uuid: [16]u8,
    part_uuid: [16]u8,
};

pub const module_response = extern struct {
    revision: u64,
    module_count: u64,
    modules: [*]?*file,
};

pub const module_request = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*module_response,
    // Revision 1 fields: Limine reads internal_module_count at this offset —
    // they must exist (zeroed) so it does not read past our request.
    internal_module_count: u64,
    internal_modules: u64,
};

export var base_revision: [3]u64 linksection(".limine_requests") = .{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 6 };

export var hhdm: hhdm_request linksection(".limine_requests") = .{
    .id = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    .revision = 0,
    .response = null,
};

export var framebuffer_req: framebuffer_request linksection(".limine_requests") = .{
    .id = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x9d5827dcd881dd75, 0xa3148604f6fab11b },
    .revision = 0,
    .response = null,
};

export var memmap_req: memmap_request linksection(".limine_requests") = .{
    .id = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    .revision = 0,
    .response = null,
};

export var module_req: module_request linksection(".limine_requests") = .{
    .id = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x3e7e279702be32af, 0xca1c4f3bd1280cee },
    .revision = 0,
    .response = null,
    .internal_module_count = 0,
    .internal_modules = 0,
};

comptime {
    _ = &requests_start_marker;
    _ = &requests_end_marker;
}

pub fn base_revision_supported() bool {
    const tag = @as(*const volatile [3]u64, @ptrCast(&base_revision));
    return tag[2] == 0;
}

pub fn hhdm_offset() ?u64 {
    const req = @as(*volatile hhdm_request, @ptrCast(&hhdm));
    const response = req.response orelse return null;
    return response.offset;
}

pub fn framebuffers() ?*const framebuffer_response {
    const req = @as(*volatile framebuffer_request, @ptrCast(&framebuffer_req));
    return req.response;
}

pub fn memmap() ?*const memmap_response {
    const req = @as(*volatile memmap_request, @ptrCast(&memmap_req));
    return req.response;
}

pub fn modules() ?*const module_response {
    const req = @as(*volatile module_request, @ptrCast(&module_req));
    return req.response;
}
