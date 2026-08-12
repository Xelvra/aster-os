pub const MemoryEntryType = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    executable_and_modules = 6,
    framebuffer = 7,
    reserved_mapped = 8,
};

pub const MemoryEntry = struct {
    base: u64,
    length: u64,
    type: MemoryEntryType,
};

pub const Framebuffer = struct {
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
};

pub const BootInfo = struct {
    hhdm_offset: u64,
    framebuffer: ?Framebuffer,
    memory_entries: []const MemoryEntry,
    /// The initrd module from the bootloader (a tar archive), mapped into
    /// the higher half. Null when the bootloader provided none.
    initrd: ?[]const u8,
    /// Virtual (HHDM) address of the ACPI RSDP handed by the bootloader.
    /// Null when the bootloader exposed no ACPI tables.
    rsdp_address: ?u64,
    /// Size in bytes of the kernel image itself (Limine executable file
    /// request), reported in the boot log metrics.
    kernel_size: u64,
};
