const std = @import("std");
const input = @import("../input.zig");
const input_queue = @import("../input_queue.zig");

const ps2_data: u16 = 0x60;
const ps2_status: u16 = 0x64;
const ps2_command: u16 = 0x64;

const status_output_full: u8 = 0x01;
const status_input_full: u8 = 0x02;
const status_mouse_data: u8 = 0x20; // bit 5: data belongs to port 2 (mouse)

const ps2_ack: u8 = 0xFA;
const ps2_resend: u8 = 0xFE;
const ps2_test_passed: u8 = 0x00;

var mouse_packet: [3]u8 = undefined;
var mouse_byte_idx: u8 = 0;

/// Initialize the second PS/2 port (mouse) on IRQ12. Robust against a
/// missing device: the port is tested first and every command waits for
/// its ACK with a bounded timeout, so init can never stall the controller
/// (which would freeze the keyboard that shares the same data register).
pub fn init() void {
    // Drain any stale bytes left in the output buffer (e.g. the keyboard's
    // ACK to 0xF4 from ps2_keyboard.init) so the port-2 test result below
    // is not confused with leftover data.
    while (in8(ps2_status) & status_output_full != 0) {
        _ = in8(ps2_data);
    }

    // Test whether a device is present on port 2 before touching it.
    out8(ps2_command, 0xA9); // test port 2
    var spins: u32 = 0;
    while (in8(ps2_status) & status_output_full == 0) : (spins += 1) {
        if (spins > 100000) return; // no response -> no mouse
    }
    const test_result = in8(ps2_data);
    if (test_result != ps2_test_passed) return; // port 2 has no working device

    // Enable port 2 and set its IRQ bit in the config byte. Keep the
    // keyboard (port 1) enabled and translation on.
    out8(ps2_command, 0xA8); // enable port 2
    _ = waitOutput();
    out8(ps2_command, 0x20); // read config
    _ = waitOutput();
    const cfg = in8(ps2_data);
    out8(ps2_command, 0x60);
    _ = waitOutput();
    out8(ps2_data, (cfg | 0x02) & ~@as(u8, 0x20)); // IRQ12 on, port2 clock on

    // Tell the mouse to start reporting; wait for its ACK.
    _ = mouseCommand(0xF4);
}

fn waitOutput() ?u8 {
    var spins: u32 = 0;
    while (in8(ps2_status) & status_output_full == 0) : (spins += 1) {
        if (spins > 100000) return null;
    }
    return in8(ps2_data);
}

fn mouseCommand(cmd: u8) ?u8 {
    // Write a command to the mouse: prefix with 0xD4 (write to port 2).
    out8(ps2_command, 0xD4);
    var spins: u32 = 0;
    while (in8(ps2_status) & status_input_full != 0) : (spins += 1) {
        if (spins > 100000) return null;
    }
    out8(ps2_data, cmd);
    // Wait for the ACK byte.
    spins = 0;
    while (spins < 100000) : (spins += 1) {
        if (in8(ps2_status) & status_output_full != 0) {
            const b = in8(ps2_data);
            if (b == ps2_resend) {
                return mouseCommand(cmd); // retry once
            }
            return b;
        }
    }
    return null;
}

pub fn handleIrq12() void {
    const status = in8(ps2_status);
    // Only consume bytes that belong to the mouse port (bit 5). Keyboard
    // scancodes share the data register; without this check a keyboard byte
    // would desynchronize the packet stream.
    if (status & status_output_full != 0 and status & status_mouse_data != 0) {
        const byte = in8(ps2_data);
        if (byte == ps2_ack or byte == 0xAA) return; // ACK / self-test
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

    input_queue.mouse.push(.{ .mouse = .{
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
