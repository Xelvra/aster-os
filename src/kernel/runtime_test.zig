const std = @import("std");
const serial = @import("serial.zig");
const input_queue = @import("input_queue.zig");
const graphics = @import("api/graphics.zig");
const build_options = @import("build_options");

const debug_exit_port: u16 = 0x501;
const exit_pass: u8 = 0x31;
const exit_fail: u8 = 0x30;

pub const enabled = build_options.runtime_tests;

var failures: usize = 0;

const Test = struct {
    name: []const u8,
    func: *const fn () void,
};

fn testTimerTicks() void {
    var ticks_seen: u64 = 0;
    var spins: usize = 0;
    while (ticks_seen < 5 and spins < 100000) : (spins += 1) {
        while (input_queue.global.pop()) |event| {
            switch (event) {
                .timer_tick => ticks_seen += 1,
                .key => {},
            }
        }
        asm volatile ("hlt" ::: .{ .memory = true });
    }
    expect(ticks_seen >= 5, "APIC timer produces tick events through the queue");
}

fn testFramebufferWrites() void {
    const r = graphics.renderer orelse {
        expect(false, "graphics renderer initialized");
        return;
    };
    r.fillScreen(0xFF0000);
    const pixel = r.fb.getPixel(0, 0);
    expect(pixel == 0x00FF0000, "fillScreen writes expected color to framebuffer");
    r.drawText("rt", 0, 0, 0xFFFFFF);
    expect(true, "drawText draws without fault");
}

const tests = [_]Test{
    .{ .name = "timer tick + event queue", .func = testTimerTicks },
    .{ .name = "framebuffer write + drawText", .func = testFramebufferWrites },
};

pub fn runAll() noreturn {
    if (!comptime enabled) @compileError("runtime tests are not enabled");
    serial.writeLine("RUNTIME TESTS START");
    for (tests) |t| {
        runOne(t);
    }
    if (failures == 0) {
        serial.writeLine("RUNTIME TESTS PASS");
        exitQemu(exit_pass);
    } else {
        serial.writeLine("RUNTIME TESTS FAIL");
        exitQemu(exit_fail);
    }
}

fn runOne(t: Test) void {
    serial.writeLine(t.name);
    t.func();
}

pub fn expect(cond: bool, name: []const u8) void {
    if (cond) {
        serial.writeLine("  ok");
    } else {
        failures += 1;
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "  FAIL: {s}", .{name}) catch "  FAIL";
        serial.writeLine(line);
    }
}

fn exitQemu(code: u8) noreturn {
    asm volatile (
        \\outb %[val], %[port]
        :
        : [val] "{al}" (code),
          [port] "{dx}" (debug_exit_port),
        : .{ .memory = true });
    while (true) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}
