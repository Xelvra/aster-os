const std = @import("std");
const serial = @import("serial.zig");
const build_options = @import("build_options");

/// Project version from the tracked `.version` file (ADR-014: no
/// timestamps, single source of truth).
pub const version = std.mem.trim(u8, build_options.version, " \r\n\t");

const reset = "\x1b[0m";
const bold = "\x1b[1m";
const dim = "\x1b[2m";
const red = "\x1b[31m";
const green = "\x1b[32m";
const yellow = "\x1b[33m";
const cyan = "\x1b[36m";

const rule_len = 12 + version.len; // "/-\STER OS" (10) + "  " (2) + version

/// The header `/-\STER OS` reads "ASTER OS": `/-\` draws the letter "A".
pub fn banner() void {
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}{s}/-\\{s}{s}STER OS{s}{s}  {s}{s}", .{
        bold, cyan, reset, bold, reset, dim, version, reset,
    }) catch return;
    serial.writeLine(line);
    rule();
}

pub fn ok(name: []const u8, detail: []const u8) void {
    status(green, "[ OK ]", name, detail);
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

/// A horizontal rule as wide as the banner line (dim), used to open and
/// close the boot log. The width is derived from the version, so the rule
/// always aligns with the banner regardless of the version string.
pub fn rule() void {
    var dashes: [rule_len]u8 = undefined;
    @memset(&dashes, '-');
    var buf: [rule_len + 16]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ dim, dashes[0..], reset }) catch return;
    serial.writeLine(line);
}
