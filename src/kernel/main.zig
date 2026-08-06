const std = @import("std");
const serial = @import("serial.zig");
const boot = @import("boot/boot.zig");
const boot_info = @import("boot/boot_info.zig");

export fn _start() callconv(.c) noreturn {
    enable_sse();
    serial.init();
    kernelMain() catch {
        serial.writeLine("ASTER KERNEL INIT FAILED");
        halt();
    };
    halt();
}

fn enable_sse() void {
    const cr0 = read_cr0();
    write_cr0(cr0 & ~@as(u64, 1 << 2));
    write_cr0(read_cr0() | (1 << 1));
    write_cr4(read_cr4() | (3 << 9));
    write_mxcsr(0x1F80);
}

fn read_cr0() u64 {
    return asm volatile ("mov %%cr0, %[v]"
        : [v] "=r" (-> u64),
    );
}

fn write_cr0(value: u64) void {
    asm volatile ("mov %[v], %%cr0"
        :
        : [v] "r" (value),
        : .{ .memory = true });
}

fn read_cr4() u64 {
    return asm volatile ("mov %%cr4, %[v]"
        : [v] "=r" (-> u64),
    );
}

fn write_cr4(value: u64) void {
    asm volatile ("mov %[v], %%cr4"
        :
        : [v] "r" (value),
        : .{ .memory = true });
}

fn write_mxcsr(value: u32) void {
    asm volatile ("ldmxcsr %[v]"
        :
        : [v] "m" (value),
        : .{ .memory = true });
}

fn kernelMain() !void {
    serial.writeLine("ASTER BOOT OK");

    const info = try boot.collect();
    printBootInfo(&info);

    halt();
}

fn printBootInfo(info: *const boot_info.BootInfo) void {
    var buf: [128]u8 = undefined;

    const hhdm = std.fmt.bufPrint(&buf, "hhdm offset: 0x{x:0>16}", .{info.hhdm_offset}) catch return;
    serial.writeLine(hhdm);

    if (info.framebuffer) |fb| {
        const fb_line = std.fmt.bufPrint(&buf, "framebuffer: {}x{} pitch={} bpp={}", .{ fb.width, fb.height, fb.pitch, fb.bpp }) catch return;
        serial.writeLine(fb_line);
    } else {
        serial.writeLine("framebuffer: none");
    }
}

fn halt() noreturn {
    asm volatile ("cli" ::: .{ .memory = true });
    while (true) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}
