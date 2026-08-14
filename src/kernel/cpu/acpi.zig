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

/// ACPI tables are parsed through `*align(1)` pointers: the spec suggests
/// 4-byte alignment, but real firmware (e.g. QEMU 8.2 SeaBIOS) can hand out
/// RSDT/XSDT addresses that are not even 4-aligned. `@alignCast` to the
/// struct's natural alignment would trap in ReleaseSafe on such firmware; the
/// x86-64 kernel handles the resulting unaligned loads natively instead.
///
/// Locate the I/O APIC address from the MADT. The RSDP pointer handed by the
/// bootloader is already HHDM-mapped (base revision >= 4); the table addresses
/// inside RSDT/XSDT are physical and must be translated by `hhdm_offset`
/// (base revision >= 4 maps the ACPI regions in the higher half). The result
/// carries the reason for a fallback so the boot log can tell a firmware
/// without ACPI from a corrupted table or a missing IOAPIC entry.
pub const IoApicResult = union(enum) {
    found: u64,
    no_rsdp,
    bad_checksum,
    no_madt,
    no_ioapic_entry,
};

pub fn findIoApic(rsdp_address: u64, hhdm_offset: u64) IoApicResult {
    const rsdp = readRsdp(rsdp_address);
    const rsdp_ptr = switch (rsdp) {
        .found => |p| p,
        .no_rsdp => return .no_rsdp,
        .bad_checksum => return .bad_checksum,
    };
    const madt = findMadt(rsdp_ptr, hhdm_offset);
    const madt_ptr = switch (madt) {
        .found => |p| p,
        .bad_checksum => return .bad_checksum,
        .no_madt => return .no_madt,
    };
    return switch (ioApicAddress(madt_ptr)) {
        .found => |addr| .{ .found = addr },
        .bad_checksum => .bad_checksum,
        .no_ioapic_entry => .no_ioapic_entry,
    };
}

const RsdpResult = union(enum) {
    found: *align(1) const RsdpV1,
    no_rsdp,
    bad_checksum,
};

fn readRsdp(address: u64) RsdpResult {
    const ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(address)));
    if (!std.mem.eql(u8, ptr[0..8], rsdp_signature)) return .no_rsdp;
    const v1: *align(1) const RsdpV1 = @ptrCast(ptr);
    if (checksumOk(ptr[0..@sizeOf(RsdpV1)])) {
        // Revision 0/1 carries only the 32-bit RSDT address.
        return .{ .found = v1 };
    }
    if (v1.revision >= 2) {
        const v2: *align(1) const RsdpV2 = @ptrCast(ptr);
        if (checksumOk(ptr[0..@sizeOf(RsdpV2)])) return .{ .found = @ptrCast(v2) };
    }
    return .bad_checksum;
}

const MadtResult = union(enum) {
    found: *align(1) const AcpiHeader,
    bad_checksum,
    no_madt,
};

fn findMadt(rsdp: *align(1) const RsdpV1, hhdm_offset: u64) MadtResult {
    if (rsdp.revision >= 2) {
        const v2: *align(1) const RsdpV2 = @ptrCast(rsdp);
        const xsdt_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(v2.xsdt_address + hhdm_offset)));
        const header: *align(1) const AcpiHeader = @ptrCast(xsdt_ptr);
        if (!checksumOk(@as([*]const u8, @ptrCast(header))[0..header.length])) return .bad_checksum;
        const entries = @as([*]const u8, @ptrCast(header))[acpi_header_size..header.length];
        const table_count = (header.length - acpi_header_size) / @sizeOf(u64);
        for (0..table_count) |i| {
            const entry_addr = std.mem.readInt(u64, entries[i * 8 ..][0..8], .little);
            const table_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(entry_addr + hhdm_offset)));
            const table: *align(1) const AcpiHeader = @ptrCast(table_ptr);
            if (std.mem.eql(u8, &table.signature, "APIC")) return .{ .found = table };
        }
        return .no_madt;
    }

    const rsdt_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(rsdp.rsdt_address + hhdm_offset)));
    const header: *align(1) const AcpiHeader = @ptrCast(rsdt_ptr);
    if (!checksumOk(@as([*]const u8, @ptrCast(header))[0..header.length])) return .bad_checksum;
    const entries = @as([*]const u8, @ptrCast(header))[acpi_header_size..header.length];
    const table_count = (header.length - acpi_header_size) / @sizeOf(u32);
    for (0..table_count) |i| {
        const entry_addr = std.mem.readInt(u32, entries[i * 4 ..][0..4], .little);
        const table_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(entry_addr + hhdm_offset)));
        const table: *align(1) const AcpiHeader = @ptrCast(table_ptr);
        if (std.mem.eql(u8, &table.signature, "APIC")) return .{ .found = table };
    }
    return .no_madt;
}

const IoApicEntryResult = union(enum) {
    found: u64,
    bad_checksum,
    no_ioapic_entry,
};

fn ioApicAddress(madt: *align(1) const AcpiHeader) IoApicEntryResult {
    if (!checksumOk(@as([*]const u8, @ptrCast(madt))[0..madt.length])) return .bad_checksum;
    const entries = @as([*]const u8, @ptrCast(madt))[acpi_header_size + madt_local_apic_and_flags_size .. madt.length];
    var offset: usize = 0;
    while (offset < entries.len) {
        const entry_type = entries[offset];
        const entry_length = entries[offset + 1];
        if (entry_length == 0) return .no_ioapic_entry;
        if (offset + entry_length > entries.len) return .no_ioapic_entry;
        if (entry_type == madt_io_apic_type) {
            const addr: u32 = std.mem.readInt(u32, entries[offset + 4 ..][0..4], .little);
            return .{ .found = addr };
        }
        offset += entry_length;
    }
    return .no_ioapic_entry;
}

fn checksumOk(bytes: []const u8) bool {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return sum == 0;
}
