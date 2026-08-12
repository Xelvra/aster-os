const std = @import("std");

const rsdp_signature = "RSD PTR ";
const acpi_header_size = 36;
const madt_local_apic_and_flags_size = 8;
const madt_io_apic_type: u8 = 1;

const AcpiHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,
};

const RsdpV1 = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_address: u32,
};

const RsdpV2 = extern struct {
    v1: RsdpV1,
    length: u32,
    xsdt_address: u64,
    extended_checksum: u8,
    reserved: [3]u8,
};

/// Locate the I/O APIC address from the MADT. The RSDP pointer handed by the
/// bootloader is already HHDM-mapped (base revision >= 4); the table addresses
/// inside RSDT/XSDT are physical and must be translated by `hhdm_offset`
/// (base revision >= 4 maps the ACPI regions in the higher half). Returns null
/// on any parse failure so the caller falls back to the legacy default.
pub fn findIoApic(rsdp_address: u64, hhdm_offset: u64) ?u64 {
    const rsdp = readRsdp(rsdp_address) orelse return null;
    const madt = findMadt(rsdp, hhdm_offset) orelse return null;
    return ioApicAddress(madt);
}

fn readRsdp(address: u64) ?*const RsdpV1 {
    const ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(address)));
    if (!std.mem.eql(u8, ptr[0..8], rsdp_signature)) return null;
    const v1: *align(4) const RsdpV1 = @ptrCast(@alignCast(ptr));
    if (checksumOk(ptr[0..@sizeOf(RsdpV1)])) {
        // Revision 0/1 carries only the 32-bit RSDT address.
        return v1;
    }
    if (v1.revision >= 2) {
        const v2: *align(8) const RsdpV2 = @ptrCast(@alignCast(ptr));
        if (checksumOk(ptr[0..@sizeOf(RsdpV2)])) return &v2.v1;
    }
    return null;
}

fn findMadt(rsdp: *const RsdpV1, hhdm_offset: u64) ?*const AcpiHeader {
    if (rsdp.revision >= 2) {
        const v2: *align(8) const RsdpV2 = @ptrCast(@alignCast(rsdp));
        const xsdt_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(v2.xsdt_address + hhdm_offset)));
        const header: *align(4) const AcpiHeader = @ptrCast(@alignCast(xsdt_ptr));
        if (checksumOk(@as([*]const u8, @ptrCast(header))[0..header.length])) {
            const entries = @as([*]const u8, @ptrCast(header))[acpi_header_size..header.length];
            const table_count = (header.length - acpi_header_size) / @sizeOf(u64);
            for (0..table_count) |i| {
                const entry_addr = std.mem.readInt(u64, entries[i * 8 ..][0..8], .little);
                const table_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(entry_addr + hhdm_offset)));
                const table: *align(4) const AcpiHeader = @ptrCast(@alignCast(table_ptr));
                if (std.mem.eql(u8, &table.signature, "APIC")) return table;
            }
        }
        return null;
    }

    const rsdt_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(rsdp.rsdt_address + hhdm_offset)));
    const header: *align(4) const AcpiHeader = @ptrCast(@alignCast(rsdt_ptr));
    if (checksumOk(@as([*]const u8, @ptrCast(header))[0..header.length])) {
        const entries = @as([*]const u8, @ptrCast(header))[acpi_header_size..header.length];
        const table_count = (header.length - acpi_header_size) / @sizeOf(u32);
        for (0..table_count) |i| {
            const entry_addr = std.mem.readInt(u32, entries[i * 4 ..][0..4], .little);
            const table_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(entry_addr + hhdm_offset)));
            const table: *align(4) const AcpiHeader = @ptrCast(@alignCast(table_ptr));
            if (std.mem.eql(u8, &table.signature, "APIC")) return table;
        }
    }
    return null;
}

fn ioApicAddress(madt: *const AcpiHeader) ?u64 {
    if (checksumOk(@as([*]const u8, @ptrCast(madt))[0..madt.length])) {
        const entries = @as([*]const u8, @ptrCast(madt))[acpi_header_size + madt_local_apic_and_flags_size .. madt.length];
        var offset: usize = 0;
        while (offset < entries.len) {
            const entry_type = entries[offset];
            const entry_length = entries[offset + 1];
            if (entry_length == 0) return null;
            if (offset + entry_length > entries.len) return null;
            if (entry_type == madt_io_apic_type) {
                const addr: u32 = std.mem.readInt(u32, entries[offset + 4 ..][0..4], .little);
                return addr;
            }
            offset += entry_length;
        }
    }
    return null;
}

fn checksumOk(bytes: []const u8) bool {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return sum == 0;
}
