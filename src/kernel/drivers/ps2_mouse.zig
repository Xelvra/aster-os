const std = @import("std");
const input = @import("../input.zig");
const input_queue = @import("../input_queue.zig");

const ps2_data: u16 = 0x60;
const ps2_status: u16 = 0x64;
const ps2_command: u16 = 0x64;

const status_output_full: u8 = 0x01;

var mouse_packet: [3]u8 = undefined;
var mouse_byte_idx: u8 = 0;

/// Initialize the second PS/2 port (mouse) on IRQ12:
/// enable the port, set IRQ12 in the controller config byte, and tell the
/// device to start reporting. The config byte must keep port 2 clock
/// *enabled* (clear bit 5) and set the port 2 interrupt bit (0x02).
pub fn init() void {
    out8(ps2_command, 0xA8); // enable port 2
    out8(ps2_command, 0x20); // read controller config byte
    const cfg = in8(ps2_data);
    out8(ps2_command, 0x60);
    out8(ps2_data, (cfg | 0x02) & ~@as(u8, 0x20)); // IRQ12 on, port2 clock on
    out8(ps2_command, 0xD4);
    out8(ps2_data, 0xF4); // enable data reporting
}

pub fn handleIrq12() void {
    if (in8(ps2_status) & status_output_full != 0) {
        const byte = in8(ps2_data);
        mouse_packet[mouse_byte_idx] = byte;
        mouse_byte_idx +%= 1;
        if (mouse_byte_idx >= 3) {
            mouse_byte_idx = 0;
            pushMousePacket();
        }
    }
}

/// Decode a standard 3-byte PS/2 mouse packet (relative movement, buttons).
fn pushMousePacket() void {
    const b0 = mouse_packet[0];
    if (b0 & 0x08 == 0) return; // out of sync, skip

    var dx: i16 = @as(i16, mouse_packet[1]);
    var dy: i16 = @as(i16, mouse_packet[2]);
    if (b0 & 0x10 != 0) dx -= 256;
    if (b0 & 0x20 != 0) dy -= 256;

    input_queue.global.push(.{ .mouse = .{
        .dx = dx,
        .dy = dy,
        .left = b0 & 0x01 != 0,
        .right = b0 & 0x02 != 0,
        .middle = b0 & 0x04 != 0,
    } });
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
