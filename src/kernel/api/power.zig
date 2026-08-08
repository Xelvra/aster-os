const std = @import("std");
const sys = @import("sys.zig");

pub const PowerOp = enum(u64) {
    reboot = 0,
};

pub fn dispatch(args: sys.SyscallArgs) u64 {
    const op: PowerOp = @enumFromInt(args.a);
    return switch (op) {
        .reboot => reboot(),
    };
}

/// i8042 system reset (command port 0x64, command 0xFE). The standard
/// keyboard-controller reset used before ACPI; works in QEMU. Falls back
/// to an infinite halt if the reset does not take effect.
fn reboot() u64 {
    const reset_cmd: u8 = 0xFE;
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (reset_cmd),
          [port] "{dx}" (@as(u16, 0x64)),
        : .{ .memory = true });
    while (true) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}
