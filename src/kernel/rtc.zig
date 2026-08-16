const io = @import("cpu/io.zig");

const cmos_index: u16 = 0x70;
const cmos_data: u16 = 0x71;
const nmi_disable: u8 = 0x80;

const reg_seconds = 0x00;
const reg_minutes = 0x02;
const reg_hours = 0x04;
const reg_status_a = 0x0A;
const reg_status_b = 0x0B;

fn readRegister(reg: u8) u8 {
    // NMI is masked for the duration of the read so a stray interrupt cannot
    // observe a torn CMOS register pair.
    io.out8(cmos_index, reg | nmi_disable);
    return io.in8(cmos_data);
}

/// BCD vs binary is selected in register B bit 2 (set = binary). Default is
/// BCD (QEMU's mc146818 and most chipsets use BCD).
fn binaryMode() bool {
    return readRegister(reg_status_b) & 0x04 != 0;
}

/// Convert a BCD byte (e.g. 0x42 = 42) to a plain number. Pure, host-testable.
pub fn fromBcd(value: u8) u8 {
    return (value >> 4) * 10 + (value & 0x0F);
}

/// Current time of day from the CMOS RTC (24-hour hour + minute). Returns null
/// when the RTC update is in progress for too long or the two consecutive
/// reads disagree (a rollover mid-read). The kernel only needs the minute
/// resolution for the bar clock, so seconds/date are not read.
pub fn readTime() ?struct { hour: u8, minute: u8 } {
    var spins: u32 = 0;
    while (readRegister(reg_status_a) & 0x80 != 0) : (spins += 1) {
        if (spins > 10000) return null; // update in progress too long
    }
    const binary = binaryMode();
    const h1 = readRegister(reg_hours);
    const m1 = readRegister(reg_minutes);
    const h2 = readRegister(reg_hours);
    const m2 = readRegister(reg_minutes);
    if (h1 != h2 or m1 != m2) return null; // read across an update boundary

    var hour = if (binary) h1 & 0x7F else fromBcd(h1 & 0x7F);
    if (h1 & 0x80 != 0) hour += 12; // PM in 12-hour mode
    const minute = if (binary) m1 else fromBcd(m1);
    if (hour > 23 or minute > 59) return null;
    return .{ .hour = hour, .minute = minute };
}
