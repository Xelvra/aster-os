const std = @import("std");
const input_queue = @import("../input_queue.zig");

const ps2_data: u16 = 0x60;
const ps2_status: u16 = 0x64;
const ps2_command: u16 = 0x64;

const status_output_full: u8 = 0x01;

pub fn init() void {
    out8(ps2_command, 0xAD);
    out8(ps2_command, 0x20);
    _ = in8(ps2_data);
    out8(ps2_command, 0x60);
    out8(ps2_data, 0x41);
    out8(ps2_command, 0xAE);
    out8(ps2_data, 0xF4);
}

pub fn handleIrq1() void {
    if (in8(ps2_status) & status_output_full != 0) {
        const scancode = in8(ps2_data);
        if (scancode == 0x00 or scancode == 0xFF or scancode == 0xFA or scancode == 0xAA) return;
        if (scancode & 0x80 != 0) {
            input_queue.global.push(.{ .key_up = scancode & 0x7F });
        } else {
            input_queue.global.push(.{ .key_down = scancode });
        }
    }
}

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
