const io = @import("../cpu/io.zig");

/// Minimal PCI configuration-space access (port 0xCF8/0xCFC). The classic
/// mechanism works in QEMU without ACPI/ECAM and is enough to find devices
/// and their BARs.
const config_address_port: u16 = 0xCF8;
const config_data_port: u16 = 0xCFC;

pub const Device = struct {
    bus: u8,
    slot: u8,
    func: u8,
    vendor: u16,
    device: u16,
    class: u8,
    subclass: u8,
    /// Raw BAR values (0..5); the caller decides memory vs I/O and mapping.
    bars: [6]u32,

    pub fn barAddress(self: Device, index: usize) ?u64 {
        if (index >= self.bars.len) return null;
        const bar = self.bars[index];
        if (bar == 0) return null;
        if (bar & 1 != 0) return null; // I/O BAR, unsupported here
        // Memory BAR: bit 0 clear. If it is a 64-bit BAR, combine with the
        // next one.
        var value: u64 = @as(u64, bar) & 0xFFFFFFFFFFFFFFF0;
        if (bar & 0x4 != 0 and index + 1 < self.bars.len) {
            value |= @as(u64, self.bars[index + 1]) << 32;
        }
        return value;
    }
};

pub fn readConfig32(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    const address: u32 = (1 << 31) | (@as(u32, bus) << 16) | (@as(u32, slot) << 11) | (@as(u32, func) << 8) | (@as(u32, offset) & 0xFC);
    io.out32(config_address_port, address);
    return io.in32(config_data_port);
}

fn readConfig16(bus: u8, slot: u8, func: u8, offset: u8) u16 {
    const value = readConfig32(bus, slot, func, offset);
    const shift: u5 = @intCast((offset & 2) * 8);
    return @truncate(value >> shift);
}

pub fn readConfig8(bus: u8, slot: u8, func: u8, offset: u8) u8 {
    const value = readConfig32(bus, slot, func, offset);
    const shift: u5 = @intCast((offset & 3) * 8);
    return @truncate(value >> shift);
}

/// Read one device function, or null if nothing is present there.
fn readDevice(bus: u8, slot: u8, func: u8) ?Device {
    const vendor = readConfig16(bus, slot, func, 0);
    if (vendor == 0xFFFF) return null;
    return .{
        .bus = bus,
        .slot = slot,
        .func = func,
        .vendor = vendor,
        .device = readConfig16(bus, slot, func, 0x02),
        .class = @truncate(readConfig16(bus, slot, func, 0x0A) >> 8),
        .subclass = @truncate(readConfig16(bus, slot, func, 0x0A)),
        .bars = .{
            readConfig32(bus, slot, func, 0x10),
            readConfig32(bus, slot, func, 0x14),
            readConfig32(bus, slot, func, 0x18),
            readConfig32(bus, slot, func, 0x1C),
            readConfig32(bus, slot, func, 0x20),
            readConfig32(bus, slot, func, 0x24),
        },
    };
}

/// Find the first device matching vendor/device.
pub fn findDevice(vendor: u16, device_id: u16) ?Device {
    for (0..32) |slot| {
        if (readConfig16(0, @intCast(slot), 0, 0) == 0xFFFF) continue;
        const func_count: u8 = if (readConfig16(0, @intCast(slot), 0, 0x0E) & 0x80 != 0) 8 else 1;
        for (0..func_count) |func| {
            if (readDevice(0, @intCast(slot), @intCast(func))) |device| {
                if (device.vendor == vendor and device.device == device_id) return device;
            }
        }
    }
    return null;
}
