const std = @import("std");

const rsdp_signature = "RSD PTR ";
const acpi_header_size = 36;
const madt_local_apic_and_flags_size = 8;
const madt_io_apic_type: u8 = 1;
const madt_local_apic_type: u8 = 0;
const madt_irq_override_type: u8 = 2;
const madt_local_nmi_type: u8 = 4;

/// An ISA IRQ -> GSI override from the MADT (Interrupt Source Override). Most
/// chipsets redirect the ISA IRQs (e.g. IRQ0 -> GSI 2), so the I/O APIC
/// redirection table must use the GSI, not the ISA IRQ number.
pub const IrqOverride = struct {
    isa_irq: u8,
    gsi: u32,
    flags: u16,
};

pub const max_irq_overrides = 16;

/// Hard cap on Application Processors (the enabled processor entries after the
/// BSP). Real desktop/server chipsets rarely exceed a handful; the per-AP
/// stacks and the scheduler assume a small fixed upper bound.
pub const max_ap = 7;

/// The I/O APIC redirection table (IOREDTBL[gsi]) index range. Real chipsets
/// expose at most 255 redirection entries (the entry count is an 8-bit field)
/// and ISA IRQ overrides always reference low GSIs, so anything larger is
/// corrupt MADT data: accepting it would let `gsi * 2` overflow u32 in
/// ReleaseSafe and panic at boot.
pub const max_gsi = 255;

/// Everything the kernel needs from the MADT (the M2 SMP debt): the I/O APIC
/// address (already used), the BSP Local APIC ID, the ISA IRQ -> GSI overrides,
/// whether any Local APIC NMI source is configured, and the Local APIC IDs of
/// the enabled Application Processors (used for INIT-SIPI-SIPI bring-up).
pub const Madt = struct {
    io_apic_address: u64,
    local_apic_id: ?u8,
    has_nmi: bool,
    irq_overrides: [max_irq_overrides]IrqOverride = undefined,
    irq_override_count: usize = 0,
    ap_ids: [max_ap]u8 = undefined,
    ap_count: usize = 0,
};

pub const MadtResult = union(enum) {
    found: Madt,
    no_rsdp,
    bad_checksum,
    no_madt,
    no_ioapic_entry,
};

/// Parse the MADT (full M2 SMP debt): the I/O APIC address, the BSP Local
/// APIC ID, the ISA IRQ -> GSI overrides and NMI presence. Any parse failure
/// degrades to a fallback reason so the boot log can tell corrupt firmware
/// apart from a missing table.
pub fn parseMadt(rsdp_address: u64, hhdm_offset: u64) MadtResult {
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
    return switch (madtInfo(madt_ptr)) {
        .found => |m| .{ .found = m },
        .bad_checksum => .bad_checksum,
        .no_ioapic_entry => .no_ioapic_entry,
    };
}

const MadtInfoResult = union(enum) {
    found: Madt,
    bad_checksum,
    no_ioapic_entry,
};

fn madtInfo(madt: *align(1) const AcpiHeader) MadtInfoResult {
    if (!headerLengthValid(madt) or madt.length < acpi_header_size + madt_local_apic_and_flags_size) return .no_ioapic_entry;
    if (!checksumOk(@as([*]const u8, @ptrCast(madt))[0..madt.length])) return .bad_checksum;

    var result = Madt{
        .io_apic_address = undefined,
        .local_apic_id = null,
        .has_nmi = false,
    };
    var ioapic_found = false;
    const entries = @as([*]const u8, @ptrCast(madt))[acpi_header_size + madt_local_apic_and_flags_size .. madt.length];
    var offset: usize = 0;
    while (offset + 2 <= entries.len) {
        const entry_type = entries[offset];
        const entry_length = entries[offset + 1];
        if (entry_length < 2) return .no_ioapic_entry;
        if (offset + entry_length > entries.len) return .no_ioapic_entry;
        // Advance the cursor BEFORE the switch: a `continue` inside a switch
        // branch would otherwise skip this line and loop forever (C48
        // regression — the disabled-processor branch used `continue`).
        offset += entry_length;
        const entry = entries[offset - entry_length .. offset];
        switch (entry_type) {
            madt_io_apic_type => {
                // type(1) length(1) id(1) reserved(1) address(4) gsi_base(4).
                if (entry.len < 12) return .no_ioapic_entry;
                result.io_apic_address = std.mem.readInt(u32, entry[4..8], .little);
                ioapic_found = true;
            },
            madt_local_apic_type => {
                // type(1) length(1) acpi_processor_id(1) apic_id(1) flags(4).
                if (entry.len < 8) continue;
                // The BSP is the first enabled processor entry (flags bit 0);
                // the remaining enabled entries are Application Processors.
                const flags = std.mem.readInt(u32, entry[4..8], .little);
                if (flags & 1 == 0) continue;
                if (result.local_apic_id == null) {
                    result.local_apic_id = entry[3];
                } else if (result.ap_count < max_ap and entry[3] != result.local_apic_id.?) {
                    result.ap_ids[result.ap_count] = entry[3];
                    result.ap_count += 1;
                }
            },
            madt_irq_override_type => {
                // type(1) length(1) bus(1)=ISA source(1)=ISA IRQ gsi(4) flags(2).
                if (entry.len < 10) continue;
                const gsi = std.mem.readInt(u32, entry[4..8], .little);
                // A GSI outside the I/O APIC redirection table range is corrupt
                // firmware data: skip the override so `gsiFor` falls back to
                // the raw ISA IRQ number instead of panicking on `gsi * 2`
                // later.
                if (gsi > max_gsi) continue;
                if (result.irq_override_count < max_irq_overrides) {
                    result.irq_overrides[result.irq_override_count] = .{
                        .isa_irq = entry[3],
                        .gsi = gsi,
                        .flags = std.mem.readInt(u16, entry[8..10], .little),
                    };
                    result.irq_override_count += 1;
                }
            },
            madt_local_nmi_type => {
                // type(1) length(1) acpi_processor_id(1) flags(2) lint(1).
                if (entry.len >= 6) result.has_nmi = true;
            },
            else => {},
        }
    }
    if (!ioapic_found) return .no_ioapic_entry;
    return .{ .found = result };
}

pub const IoApicResult = union(enum) {
    found: u64,
    no_rsdp,
    bad_checksum,
    no_madt,
    no_ioapic_entry,
};

/// Compatibility wrapper: just the I/O APIC address.
pub fn findIoApic(rsdp_address: u64, hhdm_offset: u64) IoApicResult {
    return switch (parseMadt(rsdp_address, hhdm_offset)) {
        .found => |m| .{ .found = m.io_apic_address },
        .no_rsdp => .no_rsdp,
        .bad_checksum => .bad_checksum,
        .no_madt => .no_madt,
        .no_ioapic_entry => .no_ioapic_entry,
    };
}

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

const FindMadtResult = union(enum) {
    found: *align(1) const AcpiHeader,
    bad_checksum,
    no_madt,
};

fn findMadt(rsdp: *align(1) const RsdpV1, hhdm_offset: u64) FindMadtResult {
    if (rsdp.revision >= 2) {
        const v2: *align(1) const RsdpV2 = @ptrCast(rsdp);
        const xsdt_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(v2.xsdt_address + hhdm_offset)));
        const header: *align(1) const AcpiHeader = @ptrCast(xsdt_ptr);
        if (!headerLengthValid(header)) return .no_madt;
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
    if (!headerLengthValid(header)) return .no_madt;
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

/// An ACPI table is at least its 36-byte header; nothing legitimate comes
/// anywhere near 1 MiB. Rejecting absurd lengths stops a corrupt `length`
/// field from walking the checksum/slices into unmapped memory (audit
/// 2026-08-15).
fn headerLengthValid(header: *align(1) const AcpiHeader) bool {
    return header.length >= acpi_header_size and header.length <= 1024 * 1024;
}

fn checksumOk(bytes: []const u8) bool {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return sum == 0;
}
