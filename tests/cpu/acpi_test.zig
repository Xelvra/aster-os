const std = @import("std");
const acpi = @import("kernel").acpi;

const io_apic_address: u32 = 0xFEC00000;

/// Simulated physical layout. The parser reads table addresses as physical
/// and translates them by `hhdm_offset`; in tests the "physical" addresses are
/// fake and hhdm_offset maps them onto real host addresses of `buf`.
const fake_base: u64 = 0x100000;
const rsdp_phys: u64 = fake_base;
const root_phys: u64 = fake_base + 0x200;
const madt_phys: u64 = fake_base + 0x400;

const Layout = struct {
    buf: [0x600]u8 align(16) = undefined,

    fn hhdmOffset(self: *const Layout) u64 {
        return @intFromPtr(&self.buf) - fake_base;
    }

    fn rsdpAddr(self: *const Layout) u64 {
        return @intFromPtr(&self.buf) + (rsdp_phys - fake_base);
    }

    fn writeU8(self: *Layout, phys: u64, off: usize, v: u8) void {
        self.buf[offFrom(phys) + off] = v;
    }

    fn writeU16(self: *Layout, phys: u64, off: usize, v: u16) void {
        const at = offFrom(phys) + off;
        self.buf[at] = @truncate(v);
        self.buf[at + 1] = @truncate(v >> 8);
    }

    fn writeU32(self: *Layout, phys: u64, off: usize, v: u32) void {
        self.writeU16(phys, off, @truncate(v));
        self.writeU16(phys, off + 2, @truncate(v >> 16));
    }

    fn writeU64(self: *Layout, phys: u64, off: usize, v: u64) void {
        self.writeU32(phys, off, @truncate(v));
        self.writeU32(phys, off + 4, @truncate(v >> 32));
    }

    /// Set the checksum byte so the sum of the table's first `length` bytes
    /// is 0 mod 256.
    fn fixChecksum(self: *Layout, phys: u64, checksum_off: usize, length: usize) void {
        const base = offFrom(phys);
        var sum: u8 = 0;
        for (self.buf[base .. base + length], 0..) |b, i| {
            if (i != checksum_off) sum +%= b;
        }
        self.buf[base + checksum_off] = 0 -% sum;
    }

    /// Write a generic ACPI SDT header; returns the header checksum offset.
    fn writeHeader(self: *Layout, phys: u64, signature: []const u8, length: u32) usize {
        @memcpy(self.buf[offFrom(phys) .. offFrom(phys) + 4], signature[0..4]);
        self.writeU32(phys, 4, length);
        self.writeU8(phys, 8, 1); // revision
        @memcpy(self.buf[offFrom(phys) + 10 .. offFrom(phys) + 16], "ASTER0");
        @memcpy(self.buf[offFrom(phys) + 16 .. offFrom(phys) + 24], "ASTEROS!");
        self.writeU32(phys, 24, 1);
        self.writeU32(phys, 28, 0);
        self.writeU32(phys, 32, 0);
        return 9;
    }

    fn writeRsdp(self: *Layout) void {
        self.writeRsdpAt(rsdp_phys, root_phys);
    }

    fn writeRsdpV2(self: *Layout) void {
        self.writeRsdpV2At(rsdp_phys, root_phys);
    }

    fn writeRsdpAt(self: *Layout, rsdp_phys_: u64, root_phys_: u64) void {
        @memcpy(self.buf[offFrom(rsdp_phys_) .. offFrom(rsdp_phys_) + 8], "RSD PTR ");
        @memcpy(self.buf[offFrom(rsdp_phys_) + 10 .. offFrom(rsdp_phys_) + 16], "ASTER0");
        self.writeU8(rsdp_phys_, 15, 0); // revision 0
        self.writeU32(rsdp_phys_, 16, @intCast(root_phys_));
        self.fixChecksum(rsdp_phys_, 8, 20);
    }

    fn writeRsdpV2At(self: *Layout, rsdp_phys_: u64, root_phys_: u64) void {
        @memcpy(self.buf[offFrom(rsdp_phys_) .. offFrom(rsdp_phys_) + 8], "RSD PTR ");
        @memcpy(self.buf[offFrom(rsdp_phys_) + 10 .. offFrom(rsdp_phys_) + 16], "ASTER0");
        self.writeU8(rsdp_phys_, 15, 2); // revision 2
        self.writeU32(rsdp_phys_, 16, 0);
        self.writeU32(rsdp_phys_, 20, 36); // length
        self.writeU64(rsdp_phys_, 24, root_phys_);
        // Both checksums must be fixed: `readRsdp` validates the revision-1
        // checksum (byte 8 over the first 20 bytes) first, then the extended
        // one (byte 32 over all 36). Leaving byte 8 undefined made the parse
        // depend on whatever garbage the reused test stack slot held (C48).
        self.fixChecksum(rsdp_phys_, 8, 20);
        self.fixChecksum(rsdp_phys_, 32, 36);
    }

    /// Write a root table (RSDT with u32 entries or XSDT with u64 entries)
    /// listing `table_addrs` (fake physical addresses).
    fn writeRoot(self: *Layout, xsdt: bool, table_addrs: []const u64) void {
        self.writeRootAt(root_phys, xsdt, table_addrs);
    }

    fn writeRootAt(self: *Layout, phys: u64, xsdt: bool, table_addrs: []const u64) void {
        const entry_size: usize = if (xsdt) 8 else 4;
        const length: u32 = 36 + @as(u32, @intCast(table_addrs.len * entry_size));
        const sig = if (xsdt) "XSDT" else "RSDT";
        _ = self.writeHeader(phys, sig, length);
        for (table_addrs, 0..) |addr, i| {
            const off = 36 + i * entry_size;
            if (xsdt) {
                self.writeU64(phys, off, addr);
            } else {
                self.writeU32(phys, off, @intCast(addr));
            }
        }
        self.fixChecksum(phys, 9, length);
    }

    /// Write a MADT with the given entries (each entry a byte slice with its
    /// own length byte already set).
    fn writeMadt(self: *Layout, entries: []const []const u8) void {
        self.writeMadtAt(madt_phys, entries);
    }

    fn writeMadtAt(self: *Layout, phys: u64, entries: []const []const u8) void {
        var payload_len: u32 = 8; // local APIC address + flags
        for (entries) |e| payload_len += @as(u32, @intCast(e.len));
        const length: u32 = 36 + payload_len;
        _ = self.writeHeader(phys, "APIC", length);
        self.writeU32(phys, 36, 0xFEE00000); // local APIC address
        self.writeU32(phys, 40, 0); // flags
        var off: usize = 44;
        for (entries) |e| {
            @memcpy(self.buf[offFrom(phys) + off .. offFrom(phys) + off + e.len], e);
            off += e.len;
        }
        self.fixChecksum(phys, 9, length);
    }

    fn ioApicEntry() [12]u8 {
        var e: [12]u8 = [_]u8{0} ** 12;
        e[0] = 1; // type: I/O APIC
        e[1] = 12; // length
        e[2] = 0; // io apic id
        std.mem.writeInt(u32, e[4..8], io_apic_address, .little);
        std.mem.writeInt(u32, e[8..12], 0, .little); // gsi base
        return e;
    }

    fn localApicEntry() [8]u8 {
        var e: [8]u8 = [_]u8{0} ** 8;
        e[0] = 0; // type: processor local APIC
        e[1] = 8; // length
        return e;
    }

    fn localApicEntryWith(apic_id: u8, flags: u32) [8]u8 {
        var e = localApicEntry();
        e[3] = apic_id;
        std.mem.writeInt(u32, e[4..8], flags, .little);
        return e;
    }

    fn irqOverrideEntry(isa_irq: u8, gsi: u32, flags: u16) [10]u8 {
        var e: [10]u8 = [_]u8{0} ** 10;
        e[0] = 2; // type: interrupt source override
        e[1] = 10; // length
        e[2] = 0; // bus = ISA
        e[3] = isa_irq;
        std.mem.writeInt(u32, e[4..8], gsi, .little);
        std.mem.writeInt(u16, e[8..10], flags, .little);
        return e;
    }

    fn localNmiEntry() [6]u8 {
        var e: [6]u8 = [_]u8{0} ** 6;
        e[0] = 4; // type: local APIC NMI
        e[1] = 6; // length
        return e;
    }
};

fn offFrom(phys: u64) usize {
    return @intCast(phys - fake_base);
}

test "findIoApic resolves I/O APIC via RSDT" {
    var l = Layout{};
    l.writeMadt(&.{&Layout.ioApicEntry()});
    l.writeRoot(false, &.{madt_phys});
    l.writeRsdp();
    const result = acpi.findIoApic(l.rsdpAddr(), l.hhdmOffset());
    try std.testing.expectEqual(acpi.IoApicResult{ .found = io_apic_address }, result);
}

test "parseMadt collects LAPIC id, IRQ overrides and NMI (M2 SMP debt)" {
    var l = Layout{};
    l.writeMadt(&.{
        &Layout.ioApicEntry(),
        &Layout.localApicEntryWith(0x05, 1), // BSP, enabled
        &Layout.irqOverrideEntry(0, 2, 0), // ISA IRQ0 -> GSI2
        &Layout.irqOverrideEntry(1, 1, 0), // ISA IRQ1 -> GSI1 (identity)
        &Layout.localNmiEntry(),
    });
    l.writeRoot(true, &.{madt_phys});
    l.writeRsdpV2();
    const result = acpi.parseMadt(l.rsdpAddr(), l.hhdmOffset());
    const madt = switch (result) {
        .found => |m| m,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u64, io_apic_address), madt.io_apic_address);
    try std.testing.expectEqual(@as(?u8, 0x05), madt.local_apic_id);
    try std.testing.expectEqual(@as(usize, 2), madt.irq_override_count);
    try std.testing.expectEqual(@as(u8, 0), madt.irq_overrides[0].isa_irq);
    try std.testing.expectEqual(@as(u32, 2), madt.irq_overrides[0].gsi);
    try std.testing.expectEqual(@as(u8, 1), madt.irq_overrides[1].isa_irq);
    try std.testing.expectEqual(@as(u32, 1), madt.irq_overrides[1].gsi);
    try std.testing.expect(madt.has_nmi);
    try std.testing.expectEqual(@as(usize, 0), madt.ap_count);
}

test "parseMadt skips IRQ overrides with a GSI above the I/O APIC bound" {
    // A GSI outside the I/O APIC redirection table range (max_gsi) is corrupt
    // firmware data: it must be skipped so gsiFor falls back to the raw ISA
    // IRQ number instead of panicking on `gsi * 2` (audit regression, 6bd32ba).
    var l = Layout{};
    l.writeMadt(&.{
        &Layout.ioApicEntry(),
        &Layout.irqOverrideEntry(0, 300, 0), // gsi 300 > max_gsi 255 -> skipped
        &Layout.irqOverrideEntry(1, 1, 0), // normal override survives
    });
    l.writeRoot(true, &.{madt_phys});
    l.writeRsdpV2();
    const result = acpi.parseMadt(l.rsdpAddr(), l.hhdmOffset());
    const madt = switch (result) {
        .found => |m| m,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), madt.irq_override_count);
    try std.testing.expectEqual(@as(u8, 1), madt.irq_overrides[0].isa_irq);
    try std.testing.expectEqual(@as(u32, 1), madt.irq_overrides[0].gsi);
}

test "parseMadt collects enabled Application Processors (SMP bring-up)" {
    var l = Layout{};
    l.writeMadt(&.{
        &Layout.ioApicEntry(),
        &Layout.localApicEntryWith(0x00, 1), // BSP, enabled
        &Layout.localApicEntryWith(0x01, 1), // AP 1, enabled
        &Layout.localApicEntryWith(0x02, 0), // disabled -> skipped
        &Layout.localApicEntryWith(0x00, 1), // duplicate BSP id -> skipped
        &Layout.localApicEntryWith(0x03, 1), // AP 2, enabled
    });
    l.writeRoot(true, &.{madt_phys});
    l.writeRsdpV2();
    const result = acpi.parseMadt(l.rsdpAddr(), l.hhdmOffset());
    const madt = switch (result) {
        .found => |m| m,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(?u8, 0x00), madt.local_apic_id);
    try std.testing.expectEqual(@as(usize, 2), madt.ap_count);
    try std.testing.expectEqual(@as(u8, 0x01), madt.ap_ids[0]);
    try std.testing.expectEqual(@as(u8, 0x03), madt.ap_ids[1]);
}

test "findIoApic resolves I/O APIC via XSDT" {
    var l = Layout{};
    l.writeMadt(&.{&Layout.ioApicEntry()});
    l.writeRoot(true, &.{madt_phys});
    l.writeRsdpV2();
    const result = acpi.findIoApic(l.rsdpAddr(), l.hhdmOffset());
    try std.testing.expectEqual(acpi.IoApicResult{ .found = io_apic_address }, result);
}

test "findIoApic skips non-APIC entries then finds I/O APIC" {
    var l = Layout{};
    l.writeMadt(&.{ &Layout.localApicEntry(), &Layout.ioApicEntry() });
    l.writeRoot(false, &.{madt_phys});
    l.writeRsdp();
    const result = acpi.findIoApic(l.rsdpAddr(), l.hhdmOffset());
    try std.testing.expectEqual(acpi.IoApicResult{ .found = io_apic_address }, result);
}

test "findIoApic returns bad-checksum on bad RSDP checksum" {
    var l = Layout{};
    l.writeMadt(&.{&Layout.ioApicEntry()});
    l.writeRoot(false, &.{madt_phys});
    l.writeRsdp();
    l.buf[offFrom(rsdp_phys) + 8] +%= 1; // corrupt checksum
    try std.testing.expectEqual(acpi.IoApicResult.bad_checksum, acpi.findIoApic(l.rsdpAddr(), l.hhdmOffset()));
}

test "findIoApic returns no-rsdp on wrong RSDP signature" {
    var l = Layout{};
    l.writeMadt(&.{&Layout.ioApicEntry()});
    l.writeRoot(false, &.{madt_phys});
    l.writeRsdp();
    l.buf[offFrom(rsdp_phys)] = 'X'; // corrupt signature
    try std.testing.expectEqual(acpi.IoApicResult.no_rsdp, acpi.findIoApic(l.rsdpAddr(), l.hhdmOffset()));
}

test "findIoApic rejects a MADT with a corrupt length" {
    var l = Layout{};
    _ = l.writeHeader(madt_phys, "APIC", 8); // length below the 36-byte header
    l.fixChecksum(madt_phys, 9, 8);
    l.writeRoot(false, &.{madt_phys});
    l.writeRsdp();
    try std.testing.expectEqual(acpi.IoApicResult.no_ioapic_entry, acpi.findIoApic(l.rsdpAddr(), l.hhdmOffset()));
}

test "findIoApic rejects an I/O APIC entry with a too-short length" {
    var l = Layout{};
    var short_entry = [_]u8{ 1, 6, 0, 0, 0, 0 }; // type 1, length 6 (< the 12-byte entry)
    l.writeMadt(&.{&short_entry});
    l.writeRoot(false, &.{madt_phys});
    l.writeRsdp();
    try std.testing.expectEqual(acpi.IoApicResult.no_ioapic_entry, acpi.findIoApic(l.rsdpAddr(), l.hhdmOffset()));
}

test "findIoApic returns bad-checksum on bad RSDT checksum" {
    var l = Layout{};
    l.writeMadt(&.{&Layout.ioApicEntry()});
    l.writeRoot(false, &.{madt_phys});
    l.writeRsdp();
    l.buf[offFrom(root_phys) + 9] +%= 1; // corrupt RSDT checksum
    try std.testing.expectEqual(acpi.IoApicResult.bad_checksum, acpi.findIoApic(l.rsdpAddr(), l.hhdmOffset()));
}

test "findIoApic returns no-ioapic-entry on MADT without I/O APIC entry" {
    var l = Layout{};
    l.writeMadt(&.{&Layout.localApicEntry()});
    l.writeRoot(false, &.{madt_phys});
    l.writeRsdp();
    try std.testing.expectEqual(acpi.IoApicResult.no_ioapic_entry, acpi.findIoApic(l.rsdpAddr(), l.hhdmOffset()));
}

test "findIoApic returns no-madt when root table lists no tables" {
    var l = Layout{};
    l.writeRoot(false, &.{});
    l.writeRsdp();
    try std.testing.expectEqual(acpi.IoApicResult.no_madt, acpi.findIoApic(l.rsdpAddr(), l.hhdmOffset()));
}

test "findIoApic returns bad-checksum on bad MADT checksum" {
    var l = Layout{};
    l.writeMadt(&.{&Layout.ioApicEntry()});
    l.writeRoot(false, &.{madt_phys});
    l.writeRsdp();
    l.buf[offFrom(madt_phys) + 9] +%= 1; // corrupt MADT checksum
    try std.testing.expectEqual(acpi.IoApicResult.bad_checksum, acpi.findIoApic(l.rsdpAddr(), l.hhdmOffset()));
}

// Regression for CI boot failure: QEMU 8.2 SeaBIOS places the RSDT on an
// address that is not 4-byte aligned (e.g. 0x...230e mod 4 = 2). The parser
// must read such tables unaligned instead of @alignCast-ing them.
test "findIoApic resolves I/O APIC via unaligned RSDT address" {
    const unaligned_root: u64 = fake_base + 0x20e;
    var l = Layout{};
    l.writeMadt(&.{&Layout.ioApicEntry()});
    l.writeRootAt(unaligned_root, false, &.{madt_phys});
    l.writeRsdpAt(rsdp_phys, unaligned_root);
    const result = acpi.findIoApic(l.rsdpAddr(), l.hhdmOffset());
    try std.testing.expectEqual(acpi.IoApicResult{ .found = io_apic_address }, result);
}

test "findIoApic resolves I/O APIC via unaligned RSDT and unaligned MADT address" {
    const unaligned_root: u64 = fake_base + 0x20e;
    const unaligned_madt: u64 = fake_base + 0x40e;
    var l = Layout{};
    l.writeMadtAt(unaligned_madt, &.{&Layout.ioApicEntry()});
    l.writeRootAt(unaligned_root, false, &.{unaligned_madt});
    l.writeRsdpAt(rsdp_phys, unaligned_root);
    const result = acpi.findIoApic(l.rsdpAddr(), l.hhdmOffset());
    try std.testing.expectEqual(acpi.IoApicResult{ .found = io_apic_address }, result);
}

test "findIoApic resolves I/O APIC via unaligned XSDT address" {
    const unaligned_root: u64 = fake_base + 0x20e;
    var l = Layout{};
    l.writeMadt(&.{&Layout.ioApicEntry()});
    l.writeRootAt(unaligned_root, true, &.{madt_phys});
    l.writeRsdpV2At(rsdp_phys, unaligned_root);
    const result = acpi.findIoApic(l.rsdpAddr(), l.hhdmOffset());
    try std.testing.expectEqual(acpi.IoApicResult{ .found = io_apic_address }, result);
}

test "findIoApic resolves I/O APIC via unaligned XSDT and unaligned MADT address" {
    const unaligned_root: u64 = fake_base + 0x20e;
    const unaligned_madt: u64 = fake_base + 0x40e;
    var l = Layout{};
    l.writeMadtAt(unaligned_madt, &.{&Layout.ioApicEntry()});
    l.writeRootAt(unaligned_root, true, &.{unaligned_madt});
    l.writeRsdpV2At(rsdp_phys, unaligned_root);
    const result = acpi.findIoApic(l.rsdpAddr(), l.hhdmOffset());
    try std.testing.expectEqual(acpi.IoApicResult{ .found = io_apic_address }, result);
}
