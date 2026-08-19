// M7 Fáze C: the wasm-vs-Lua benchmark (spec/roadmap.md). Spawns the wasm
// twin (src/kernel/apps/bench.zig) and the Lua twin
// (src/kernel/lua/programs/bench.lua) — the identical Mandelbrot escape-time
// grid in both languages — and times each spawn call with the kernel's own
// millisecond clock (time.zig). Gated by `-Dbench=true`, mirroring
// runtime_test.zig's `-Druntime-tests=true` gate; mutually exclusive with it
// in practice (both are noreturn, called right before eventLoop in main.zig).
const std = @import("std");
const serial = @import("serial.zig");
const time = @import("time.zig");
const runtime = @import("api/runtime.zig");
const build_options = @import("build_options");

pub const enabled = build_options.bench;

const debug_exit_port: u16 = 0x501;
const exit_pass: u8 = 0x31;
const exit_fail: u8 = 0x30;

pub fn runAll() noreturn {
    var ok = true;

    const wasm_start = time.ms();
    _ = runtime.spawn(.{ .kind = .Wasm, .entry = "bench.wasm" }) catch {
        serial.writeLine("BENCH FAIL: wasm spawn failed");
        ok = false;
    };
    const wasm_ms = time.ms() - wasm_start;

    const lua_start = time.ms();
    _ = runtime.spawn(.{ .kind = .Lua, .entry = "bench.lua" }) catch {
        serial.writeLine("BENCH FAIL: lua spawn failed");
        ok = false;
    };
    const lua_ms = time.ms() - lua_start;

    var buf: [64]u8 = undefined;
    const wasm_line = std.fmt.bufPrint(&buf, "BENCH WASM MS {d}", .{wasm_ms}) catch "BENCH WASM MS ?";
    serial.writeLine(wasm_line);
    const lua_line = std.fmt.bufPrint(&buf, "BENCH LUA MS {d}", .{lua_ms}) catch "BENCH LUA MS ?";
    serial.writeLine(lua_line);

    if (ok) {
        serial.writeLine("BENCH DONE");
        exitQemu(exit_pass);
    } else {
        exitQemu(exit_fail);
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
