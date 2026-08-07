const std = @import("std");
const serial = @import("serial.zig");
const boot = @import("boot/boot.zig");
const boot_info = @import("boot/boot_info.zig");
const mem = @import("mem/mem.zig");
const cache_attr = @import("mem/cache_attr.zig");
const idt = @import("cpu/idt.zig");
const pic = @import("drivers/pic.zig");
const apic = @import("cpu/apic.zig");
const page_map = @import("mem/page_map.zig");
const ps2 = @import("drivers/ps2.zig");
const input_queue = @import("input_queue.zig");

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

    idt.init();
    serial.writeLine("idt: init ok");
    pic.remap();
    serial.writeLine("pic: remap ok");

    var memory = try mem.Memory.init(&info);
    printMemoryInfo(&memory, &info);

    const alloc = memory.allocator();
    const test_buf = try alloc.alloc(u8, 64);
    defer alloc.free(test_buf);
    @memset(test_buf, 0xAB);
    if (test_buf[0] == 0xAB and test_buf[63] == 0xAB) {
        serial.writeLine("heap alloc test: ok");
    } else {
        serial.writeLine("heap alloc test: failed");
    }

    page_map.init(&memory.pfa, info.hhdm_offset);
    apic.init(info.hhdm_offset);
    ps2.init();
    serial.writeLine("apic: init ok");

    asm volatile ("sti" ::: .{ .memory = true });
    serial.writeLine("timer test: waiting for ticks");
    eventLoop();
}

fn eventLoop() noreturn {
    var last_tick: u64 = 0;
    var buf: [64]u8 = undefined;
    while (true) {
        const ticks = idt.tick_counter.load(.monotonic);
        if (ticks >= last_tick + 1000) {
            last_tick = ticks;
            const line = std.fmt.bufPrint(&buf, "ticks: {}", .{ticks}) catch "ticks: err";
            serial.writeLine(line);
        }
        while (input_queue.global.pop()) |event| {
            switch (event) {
                .timer_tick => |t| {
                    _ = t;
                },
                .key_down => |sc| {
                    const line = std.fmt.bufPrint(&buf, "key: 0x{x}", .{sc}) catch "key: err";
                    serial.writeLine(line);
                },
                .key_up => |sc| {
                    const line = std.fmt.bufPrint(&buf, "key up: 0x{x}", .{sc}) catch "key up: err";
                    serial.writeLine(line);
                },
            }
        }
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}

fn printMemoryInfo(memory: *mem.Memory, info: *const boot_info.BootInfo) void {
    var buf: [128]u8 = undefined;

    var usable_total: u64 = 0;
    for (info.memory_entries) |entry| {
        if (entry.type == .usable) usable_total += entry.length;
        if (entry.base >= 0xfe000000 and entry.base < 0xff000000) {
            const mm = std.fmt.bufPrint(&buf, "mm: base=0x{x} len=0x{x} type={}", .{ entry.base, entry.length, @intFromEnum(entry.type) }) catch return;
            serial.writeLine(mm);
        }
    }
    const ram = std.fmt.bufPrint(&buf, "usable ram: {} bytes ({} MiB)", .{ usable_total, usable_total / (1024 * 1024) }) catch return;
    serial.writeLine(ram);

    const free = std.fmt.bufPrint(&buf, "free pages: {}", .{memory.pfa.totalFreePages()}) catch return;
    serial.writeLine(free);
}

fn printBootInfo(info: *const boot_info.BootInfo) void {
    var buf: [128]u8 = undefined;

    const hhdm = std.fmt.bufPrint(&buf, "hhdm offset: 0x{x:0>16}", .{info.hhdm_offset}) catch return;
    serial.writeLine(hhdm);

    if (info.framebuffer) |fb| {
        const fb_line = std.fmt.bufPrint(&buf, "framebuffer: {}x{} pitch={} bpp={}", .{ fb.width, fb.height, fb.pitch, fb.bpp }) catch return;
        serial.writeLine(fb_line);
        const attr = cache_attr.framebufferCacheAttr(fb.address, info.hhdm_offset);
        const attr_line = std.fmt.bufPrint(&buf, "framebuffer cache: {s}", .{@tagName(attr)}) catch return;
        serial.writeLine(attr_line);
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
