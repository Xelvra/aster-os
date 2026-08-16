const std = @import("std");
const serial = @import("../serial.zig");

const idt_size = 256;
var idt_entries: [idt_size]IdtEntry align(16) = undefined;

const IdtEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    zero: u32 = 0,
};

const InterruptGate: u8 = 0x8E;
const TrapGate: u8 = 0x8F;

const stub_size = 9;
const isr_stubs = @extern([*]u8, .{ .name = "isr_stubs" });

pub fn init() void {
    for (0..idt_size) |i| {
        setEntry(i, InterruptGate);
    }
    load();
}

/// Load the (shared) IDT on the current CPU. The BSP does it during init; each
/// Application Processor calls this again after SIPI — the table is global, so
/// every core gets the same interrupt gates.
pub fn load() void {
    var idt_reg: [10]u8 align(16) = undefined;
    const limit: u16 = idt_size * @sizeOf(IdtEntry) - 1;
    const base: u64 = @intFromPtr(&idt_entries);
    std.mem.writeInt(u16, idt_reg[0..2], limit, .little);
    std.mem.writeInt(u64, idt_reg[2..10], base, .little);
    // Zig 0.16 rejects `lidtq (%[reg])` with an "r" operand in Debug builds
    // ("invalid memory operand"), while ReleaseSafe accepts it. Moving the
    // address into %rax first and then using `(%rax)` works in both modes.
    asm volatile ("mov %[reg], %%rax\nlidtq (%%rax)"
        :
        : [reg] "r" (@intFromPtr(&idt_reg)),
        : .{ .rax = true, .memory = true });
}

fn setEntry(vector: usize, gate_type: u8) void {
    const stub_addr = @intFromPtr(isr_stubs) + vector * stub_size;
    idt_entries[vector] = .{
        .offset_low = @truncate(stub_addr),
        .selector = 0x28,
        .ist = 0,
        .type_attr = gate_type,
        .offset_mid = @truncate(stub_addr >> 16),
        .offset_high = @truncate(stub_addr >> 32),
    };
}

fn handleIsrImpl(frame: *InterruptFrame) callconv(.c) void {
    // Guards the ISR stubs: the vector is pushed with `push imm8` and masked
    // to 8 bits in isr_common, so a value > 0xFF means the stub changed
    // (regression guard for C35 — cheap, fires on any vector, not timing).
    std.debug.assert(frame.vector <= 0xFF);
    const vector = frame.vector;
    switch (vector) {
        0x20 => {
            const apic = @import("apic.zig");
            const input_service = @import("../input/service.zig");
            const time = @import("../time.zig");
            time.tick();
            const t = time.ticks();
            input_service.pushTimerTick(t);
            apic.sendEoi();
        },
        0x21 => {
            const ack = @import("apic.zig");
            const ps2 = @import("../drivers/ps2.zig");
            ps2.handleIrq1();
            ack.sendEoi();
        },
        0x22 => {
            const ack = @import("apic.zig");
            const ps2 = @import("../drivers/ps2.zig");
            ps2.handleIrq12();
            ack.sendEoi();
        },
        0xFF => {},
        else => handleFault(vector, frame),
    }
}

comptime {
    @export(&handleIsrImpl, .{ .name = "handle_isr" });
}

fn handleFault(vector: usize, frame: *InterruptFrame) void {
    serial.writeLine("ASTER FAULT");
    writeHexNibble("vec", @as(u64, @intCast(vector)));
    writeHexNibble("err", frame.error_code);
    writeHexNibble("rip", frame.rip);
    writeHexNibble("cr2", read_cr2());
    writeHexNibble("rbp", frame.rbp);
    printBacktrace(frame.rbp);
    halt();
}

const max_backtrace_depth = 8;

fn printBacktrace(frame_pointer: u64) void {
    var fp: u64 = frame_pointer;
    var depth: usize = 0;
    while (fp != 0 and depth < max_backtrace_depth) : (depth += 1) {
        // Only walk a plausible kernel-address frame: 8-aligned and inside the
        // higher-half kernel/direct-map range. A garbage rbp (stack corruption
        // or a fabricated task frame) must not #PF inside the fault handler
        // (audit 2026-08-15).
        if (fp % 8 != 0 or fp < 0xffffffff80000000 or fp >= 0xffffffffffff0000) break;
        const return_addr: u64 = @as(*const u64, @ptrFromInt(fp + 8)).*;
        if (return_addr == 0) break;
        writeHexNibble("bt", return_addr);
        fp = @as(*const u64, @ptrFromInt(fp)).*;
    }
}

const hex_digits = "0123456789abcdef";

fn writeHexNibble(label: []const u8, value: u64) void {
    serial.writeChar(' ');
    for (label) |c| serial.writeChar(c);
    serial.writeChar('=');
    serial.writeChar('0');
    serial.writeChar('x');
    var shift: u6 = 60;
    while (true) {
        const digit: u8 = @intCast((value >> shift) & 0xF);
        serial.writeChar(hex_digits[digit]);
        if (shift == 0) break;
        shift -= 4;
    }
    serial.writeLine("");
}

pub const InterruptFrame = struct {
    rdi: u64,
    rsi: u64,
    rcx: u64,
    rdx: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    rbx: u64,
    rbp: u64,
    rax: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

fn read_cr2() u64 {
    return asm volatile ("mov %%cr2, %[v]"
        : [v] "=r" (-> u64),
    );
}

fn halt() noreturn {
    asm volatile ("cli" ::: .{ .memory = true });
    while (true) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}
