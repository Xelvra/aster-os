const std = @import("std");
const serial = @import("serial.zig");
const build_options = @import("build_options");

/// Project version from the tracked `.version` file (ADR-014: no
/// timestamps, single source of truth).
pub const version = std.mem.trim(u8, build_options.version, " \r\n\t");

const reset = "\x1b[0m";
const bold = "\x1b[1m";
// 24-bit truecolor: the RGB values match the README boot-log block exactly,
// so the terminal and the rendered documentation use the same colors.
const dim = "\x1b[38;2;139;148;158m"; // #8b949e
const red = "\x1b[38;2;248;81;73m"; // #f85149
const green = "\x1b[38;2;63;185;80m"; // #3fb950
const yellow = "\x1b[38;2;210;153;34m"; // #d29922
const teal = "\x1b[38;2;45;212;191m"; // #2dd4bf

/// The header `/-\STER OS` reads "ASTER OS": `/-\` draws the letter "A".
pub fn banner() void {
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}{s}/-\\STER OS{s}{s}  {s}{s}", .{
        bold, teal, reset, dim, version, reset,
    }) catch return;
    serial.writeLine(line);
}

pub fn ok(name: []const u8, detail: []const u8) void {
    status(green, "[ OK ]", name, detail);
}

/// A blank line to visually separate sections of the boot log.
pub fn blank() void {
    serial.writeLine("");
}

pub fn warn(name: []const u8, detail: []const u8) void {
    status(yellow, "[WARN]", name, detail);
}

pub fn fail(name: []const u8, detail: []const u8) void {
    status(red, "[FAIL]", name, detail);
}

fn status(color: []const u8, tag: []const u8, name: []const u8, detail: []const u8) void {
    var buf: [192]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}{s}{s} {s:<16} {s}{s}{s}", .{
        color, tag, reset, name, dim, detail, reset,
    }) catch return;
    serial.writeLine(line);
}
