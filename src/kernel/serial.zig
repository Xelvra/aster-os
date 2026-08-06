const std = @import("std");

const COM1_BASE: u16 = 0x3F8;
const COM1_DATA: u16 = COM1_BASE + 0;
const COM1_INTERRUPT_ENABLE: u16 = COM1_BASE + 1;
const COM1_LINE_CONTROL: u16 = COM1_BASE + 3;
const COM1_MODEM_CONTROL: u16 = COM1_BASE + 4;
const COM1_LINE_STATUS: u16 = COM1_BASE + 5;

const LINE_STATUS_TRANSMIT_EMPTY: u8 = 0x20;

fn out8(port: u16, value: u8) void {
    asm volatile (
        \\outb %[val], %[port]
        :
        : [val] "{al}" (value),
          [port] "{dx}" (port),
        : .{ .memory = true });
}

fn in8(port: u16) u8 {
    return asm volatile (
        \\inb %[port], %[val]
        : [val] "={al}" (-> u8),
        : [port] "{dx}" (port),
        : .{ .memory = true });
}

pub fn init() void {
    out8(COM1_INTERRUPT_ENABLE, 0x00);
    out8(COM1_LINE_CONTROL, 0x80);
    out8(COM1_BASE + 0, 0x01);
    out8(COM1_INTERRUPT_ENABLE, 0x00);
    out8(COM1_LINE_CONTROL, 0x03);
    out8(COM1_MODEM_CONTROL, 0x0B);
    out8(COM1_BASE + 2, 0xC7);
}

fn transmitReady() bool {
    return (in8(COM1_LINE_STATUS) & LINE_STATUS_TRANSMIT_EMPTY) != 0;
}

fn writeByte(byte: u8) void {
    while (!transmitReady()) {}
    out8(COM1_DATA, byte);
}

pub fn write(bytes: []const u8) void {
    for (bytes) |byte| writeByte(byte);
}

pub fn writeChar(char: u8) void {
    writeByte(char);
}

pub fn writeLine(bytes: []const u8) void {
    write(bytes);
    writeByte('\r');
    writeByte('\n');
}
