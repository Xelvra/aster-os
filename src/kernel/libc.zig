const std = @import("std");
const sys = @import("api/sys.zig");
const api_storage = @import("api/storage.zig");

var heap_allocator: std.mem.Allocator = undefined;

pub fn setHeapAllocator(allocator: std.mem.Allocator) void {
    heap_allocator = allocator;
}

fn kernelAllocator() std.mem.Allocator {
    return heap_allocator;
}

pub export fn malloc(size: usize) callconv(.c) ?*anyopaque {
    // The header stores the original requested size; free() recomputes the
    // block length from it, so a checked add keeps an extreme size from
    // overflowing the bookkeeping arithmetic (2026-08-15-self-audit).
    const total = std.math.add(usize, size, @sizeOf(usize) + 7) catch return null;
    const block = kernelAllocator().alloc(u64, total / 8 + 1) catch return null;
    const len_ptr: *usize = @ptrCast(block.ptr);
    len_ptr.* = size;
    return @ptrCast(block.ptr + 1);
}

pub export fn calloc(nmemb: usize, size: usize) callconv(.c) ?*anyopaque {
    const total_req = std.math.mul(usize, nmemb, size) catch return null;
    const total = std.math.add(usize, total_req, @sizeOf(usize) + 7) catch return null;
    const block = kernelAllocator().alloc(u64, total / 8 + 1) catch return null;
    const len_ptr: *usize = @ptrCast(block.ptr);
    len_ptr.* = total_req;
    const data: [*]u8 = @ptrCast(block.ptr + 1);
    @memset(data[0..total_req], 0);
    return data;
}

pub export fn realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    if (ptr == null) return malloc(size);
    if (size == 0) {
        free(ptr);
        return null;
    }
    const data: [*]u8 = @ptrCast(ptr.?);
    const len_ptr: *usize = @ptrCast(@alignCast(data - @sizeOf(usize)));
    const old_len = len_ptr.*;
    if (old_len >= size) {
        // Shrinking keeps the original block: free() recomputes the block
        // length from the stored size, so overwriting it here would make free
        // release the wrong (smaller) length and corrupt the allocator
        // (2026-08-15-self-audit). The caller simply uses fewer bytes.
        return ptr;
    }
    const new_ptr = malloc(size) orelse return null;
    const new_data: [*]u8 = @ptrCast(new_ptr);
    @memcpy(new_data[0..old_len], data[0..old_len]);
    free(ptr);
    return new_ptr;
}

pub export fn free(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr == null) return;
    const data: [*]u8 = @ptrCast(ptr.?);
    const len_ptr: *usize = @ptrCast(@alignCast(data - @sizeOf(usize)));
    const len = len_ptr.*;
    const block: [*]u64 = @ptrCast(@alignCast(data - @sizeOf(usize)));
    kernelAllocator().free(block[0 .. (len + @sizeOf(usize) + 7) / 8 + 1]);
}

export fn abs(n: c_int) callconv(.c) c_int {
    return if (n < 0) -n else n;
}

export fn labs(n: c_long) callconv(.c) c_long {
    return if (n < 0) -n else n;
}

export fn llabs(n: c_longlong) callconv(.c) c_longlong {
    return if (n < 0) -n else n;
}

export fn atoi(str: [*:0]const u8) callconv(.c) c_int {
    var i: usize = 0;
    while (str[i] == ' ') i += 1;
    var neg = false;
    if (str[i] == '-') {
        neg = true;
        i += 1;
    } else if (str[i] == '+') {
        i += 1;
    }
    var result: c_int = 0;
    while (str[i] >= '0' and str[i] <= '9') : (i += 1) {
        result = result * 10 + (str[i] - '0');
    }
    return if (neg) -result else result;
}

export fn strtol(str: [*:0]const u8, endptr: ?*[*:0]const u8, base: c_int) callconv(.c) c_long {
    return cvtInteger(c_long, str, endptr, base, true);
}

export fn strtoll(str: [*:0]const u8, endptr: ?*[*:0]const u8, base: c_int) callconv(.c) c_longlong {
    return cvtInteger(c_longlong, str, endptr, base, true);
}

export fn strtoul(str: [*:0]const u8, endptr: ?*[*:0]const u8, base: c_int) callconv(.c) c_ulong {
    return cvtInteger(c_ulong, str, endptr, base, false);
}

export fn strtoull(str: [*:0]const u8, endptr: ?*[*:0]const u8, base: c_int) callconv(.c) c_ulonglong {
    return cvtInteger(c_ulonglong, str, endptr, base, false);
}

fn cvtInteger(comptime T: type, str: [*:0]const u8, endptr: ?*[*:0]const u8, base: c_int, comptime signed: bool) T {
    var i: usize = 0;
    while (str[i] == ' ' or str[i] == '\t' or str[i] == '\n') i += 1;
    var neg = false;
    if (signed) {
        if (str[i] == '-') {
            neg = true;
            i += 1;
        } else if (str[i] == '+') {
            i += 1;
        }
    }
    var effective_base: u32 = @intCast(if (base == 0) 10 else base);
    if (effective_base == 16 and str[i] == '0' and (str[i + 1] == 'x' or str[i + 1] == 'X')) {
        i += 2;
    } else if (effective_base == 0 and str[i] == '0') {
        if (str[i + 1] == 'x' or str[i + 1] == 'X') {
            effective_base = 16;
            i += 2;
        } else {
            effective_base = 8;
        }
    }
    var result: u64 = 0;
    const start = i;
    while (str[i] != 0) : (i += 1) {
        const c = str[i];
        const digit: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => break,
        };
        if (digit >= effective_base) break;
        result = result * effective_base + digit;
    }
    if (endptr) |ep| {
        ep.* = if (i == start) str else str + i;
    }
    if (signed) {
        const signed_result: i64 = @bitCast(result);
        return @intCast(if (neg) -signed_result else signed_result);
    }
    return @intCast(if (neg) @as(u64, 0) - result else result);
}

export fn memchr(ptr: [*]const u8, c: c_int, n: usize) callconv(.c) ?*anyopaque {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (ptr[i] == @as(u8, @intCast(c & 0xff))) return @constCast(&ptr[i]);
    }
    return null;
}

export fn strcmp(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) c_int {
    var i: usize = 0;
    while (a[i] != 0 and b[i] != 0 and a[i] == b[i]) i += 1;
    return @as(c_int, a[i]) - @as(c_int, b[i]);
}

export fn strncmp(a: [*:0]const u8, b: [*:0]const u8, n: usize) callconv(.c) c_int {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return @as(c_int, a[i]) - @as(c_int, b[i]);
        if (a[i] == 0) return 0;
    }
    return 0;
}

export fn strchr(s: [*:0]const u8, c: c_int) callconv(.c) ?[*:0]const u8 {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        if (s[i] == @as(u8, @intCast(c & 0xff))) return s + i;
    }
    if (c == 0) return s + i;
    return null;
}

export fn strrchr(s: [*:0]const u8, c: c_int) callconv(.c) ?[*:0]const u8 {
    var last: ?[*:0]const u8 = null;
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        if (s[i] == @as(u8, @intCast(c & 0xff))) last = s + i;
    }
    if (c == 0) return s + i;
    return last;
}

export fn strstr(haystack: [*:0]const u8, needle: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    if (needle[0] == 0) return haystack;
    var i: usize = 0;
    while (haystack[i] != 0) : (i += 1) {
        var j: usize = 0;
        while (needle[j] != 0 and haystack[i + j] == needle[j]) j += 1;
        if (needle[j] == 0) return haystack + i;
    }
    return null;
}

export fn strpbrk(s: [*:0]const u8, accept: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        var j: usize = 0;
        while (accept[j] != 0) : (j += 1) {
            if (s[i] == accept[j]) return s + i;
        }
    }
    return null;
}

export fn strspn(s: [*:0]const u8, accept: [*:0]const u8) callconv(.c) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        var found = false;
        var j: usize = 0;
        while (accept[j] != 0) : (j += 1) {
            if (s[i] == accept[j]) {
                found = true;
                break;
            }
        }
        if (!found) break;
    }
    return i;
}

export fn strcspn(s: [*:0]const u8, reject: [*:0]const u8) callconv(.c) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        var j: usize = 0;
        while (reject[j] != 0) : (j += 1) {
            if (s[i] == reject[j]) return i;
        }
    }
    return i;
}

export fn strcpy(dest: [*]u8, src: [*:0]const u8) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) dest[i] = src[i];
    dest[i] = 0;
    return dest;
}

export fn strncpy(dest: [*]u8, src: [*:0]const u8, n: usize) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (i < n and src[i] != 0) : (i += 1) dest[i] = src[i];
    while (i < n) : (i += 1) dest[i] = 0;
    return dest;
}

export fn strcat(dest: [*:0]u8, src: [*:0]const u8) callconv(.c) [*:0]u8 {
    var i: usize = 0;
    while (dest[i] != 0) i += 1;
    var j: usize = 0;
    while (src[j] != 0) : (j += 1) dest[i + j] = src[j];
    dest[i + j] = 0;
    return dest;
}

export fn strcoll(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) c_int {
    return strcmp(a, b);
}

const errno_values = [_][]const u8{
    "no error",
    "domain error",
    "range error",
    "illegal byte sequence",
    "no such file or directory",
    "invalid argument",
    "not enough memory",
};

export fn strerror(errnum: c_int) callconv(.c) [*:0]const u8 {
    const known: [*:0]const u8 = switch (errnum) {
        0 => "no error",
        33 => "domain error",
        34 => "range error",
        84 => "illegal byte sequence",
        2 => "no such file or directory",
        22 => "invalid argument",
        12 => "not enough memory",
        else => "unknown error",
    };
    return known;
}

export var errno: c_int = 0;

export fn isalnum(c: c_int) callconv(.c) c_int {
    return @intFromBool(isalpha(c) != 0 or isdigit(c) != 0);
}
export fn isalpha(c: c_int) callconv(.c) c_int {
    return @intFromBool((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z'));
}
export fn iscntrl(c: c_int) callconv(.c) c_int {
    return @intFromBool(c >= 0 and c < 0x20);
}
export fn isdigit(c: c_int) callconv(.c) c_int {
    return @intFromBool(c >= '0' and c <= '9');
}
export fn isgraph(c: c_int) callconv(.c) c_int {
    return @intFromBool(c > 0x20 and c < 0x7f);
}
export fn islower(c: c_int) callconv(.c) c_int {
    return @intFromBool(c >= 'a' and c <= 'z');
}
export fn isprint(c: c_int) callconv(.c) c_int {
    return @intFromBool(c >= 0x20 and c < 0x7f);
}
export fn ispunct(c: c_int) callconv(.c) c_int {
    return @intFromBool(isgraph(c) != 0 and isalnum(c) == 0);
}
export fn isspace(c: c_int) callconv(.c) c_int {
    return @intFromBool(c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c or c == 0x0b);
}
export fn isupper(c: c_int) callconv(.c) c_int {
    return @intFromBool(c >= 'A' and c <= 'Z');
}
export fn isxdigit(c: c_int) callconv(.c) c_int {
    return @intFromBool(isdigit(c) != 0 or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'));
}
export fn tolower(c: c_int) callconv(.c) c_int {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
export fn toupper(c: c_int) callconv(.c) c_int {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

export fn abort() callconv(.c) noreturn {
    @trap();
}

export fn time(timer: ?*time_t) callconv(.c) time_t {
    const t: time_t = 0;
    if (timer) |tptr| tptr.* = t;
    return t;
}

export fn clock() callconv(.c) clock_t {
    return 0;
}

const time_t = c_long;
const clock_t = c_long;

var lconv_instance: struct {
    decimal_point: [*:0]const u8,
    thousands_sep: [*:0]const u8,
    grouping: [*:0]const u8,
} = .{
    .decimal_point = ".",
    .thousands_sep = "",
    .grouping = "",
};

export fn localeconv() callconv(.c) *anyopaque {
    return &lconv_instance;
}

export var stdin: ?*anyopaque = null;
export var stdout: ?*anyopaque = null;
export var stderr: ?*anyopaque = null;

// C stdio over the kernel storage (KI file.*): fopen/fread/fclose/feof/getc
// map onto ext2 handles so standard Lua file functions (dofile, loadfile)
// work like stock Lua instead of failing on a no-op fopen. Read mode only;
// writes keep going to the serial console through fwrite. The FILE* is a
// small-slot index, not a real C stream.
const stdio_slots = 16;
const StdioSlot = struct {
    in_use: bool = false,
    handle: u64 = 0,
    eof: bool = false,
};
var stdio_table: [stdio_slots]StdioSlot = [_]StdioSlot{.{}} ** stdio_slots;

fn stdioSlot(stream: ?*anyopaque) ?*StdioSlot {
    const idx: usize = @intFromPtr(stream);
    if (idx == 0 or idx > stdio_slots) return null;
    const slot = &stdio_table[idx - 1];
    return if (slot.in_use) slot else null;
}

export fn fopen(path: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*anyopaque {
    if (mode[0] != 'r') return null;
    const len = std.mem.len(path);
    const result = sys.dispatch(.Storage, .{
        .a = @intFromEnum(api_storage.StorageOp.open),
        .b = @intFromPtr(path),
        .c = len,
    });
    if (result >> 32 != 0) return null;
    const handle = result & 0xFFFFFFFF;
    for (&stdio_table, 0..) |*slot, i| {
        if (!slot.in_use) {
            slot.* = .{ .in_use = true, .handle = handle, .eof = false };
            return @ptrFromInt(i + 1);
        }
    }
    return null;
}

export fn freopen(path: [*:0]const u8, mode: [*:0]const u8, stream: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = stream;
    return fopen(path, mode);
}

export fn fclose(stream: ?*anyopaque) callconv(.c) c_int {
    const slot = stdioSlot(stream) orelse return 0;
    _ = sys.dispatch(.Storage, .{
        .a = @intFromEnum(api_storage.StorageOp.close),
        .b = slot.handle,
    });
    slot.* = .{ .in_use = false };
    return 0;
}

export fn feof(stream: ?*anyopaque) callconv(.c) c_int {
    const slot = stdioSlot(stream) orelse return 1;
    return if (slot.eof) 1 else 0;
}

export fn ferror(stream: ?*anyopaque) callconv(.c) c_int {
    _ = stream;
    return 0;
}

export fn fread(ptr: ?*anyopaque, size: usize, nmemb: usize, stream: ?*anyopaque) callconv(.c) usize {
    const slot = stdioSlot(stream) orelse return 0;
    const total = size * nmemb;
    if (total == 0) return 0;
    const ra = api_storage.ReadArgs{
        .handle = slot.handle,
        .buf = @intFromPtr(ptr),
        .len = total,
    };
    const result = sys.dispatch(.Storage, .{
        .a = @intFromEnum(api_storage.StorageOp.read),
        .b = @intFromPtr(&ra),
    });
    if (result >> 32 != 0) {
        slot.eof = true;
        return 0;
    }
    const n = result & 0xFFFFFFFF;
    // Reading fewer bytes than requested means end of file reached.
    if (n < total) slot.eof = true;
    return if (size == 0) 0 else n / size;
}

export fn getc(stream: ?*anyopaque) callconv(.c) c_int {
    var byte: u8 = undefined;
    if (fread(&byte, 1, 1, stream) == 0) return -1;
    return byte;
}

export fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: ?*anyopaque) callconv(.c) usize {
    _ = stream;
    for (0..size * nmemb) |i| {
        serial_write(ptr[i]);
    }
    return nmemb;
}

export fn fflush(stream: ?*anyopaque) callconv(.c) c_int {
    _ = stream;
    return 0;
}

const serial = @import("serial.zig");

fn serial_write(byte: u8) void {
    serial.writeChar(byte);
}

export fn fabs(x: f64) callconv(.c) f64 {
    return @abs(x);
}

pub export fn floor(x: f64) callconv(.c) f64 {
    // IEEE 754 bit trick. NOTE: must not use @floor — on baseline x86_64
    // (no SSE4.1) the builtin lowers to a software routine that calls the C
    // symbol `floor`, i.e. this very export: infinite tail recursion (C51).
    const bits: u64 = @bitCast(x);
    const biased: u32 = @intCast((bits >> 52) & 0x7FF);
    const is_neg = (bits >> 63) != 0;
    if (x == 0) return x; // ±0 keep the sign
    if (biased >= 0x3FF + 52) return x;
    if (biased < 0x3FF) return if (is_neg) -1.0 else 0.0;
    const shift: u6 = @intCast(52 - (biased - 0x3FF));
    const mask = (@as(u64, 1) << shift) - 1;
    if ((bits & mask) == 0) return x;
    const truncated: f64 = @bitCast(bits & ~mask);
    return if (is_neg) truncated - 1.0 else truncated;
}

pub export fn ceil(x: f64) callconv(.c) f64 {
    // See floor() for the @ceil rationale (C51).
    const bits: u64 = @bitCast(x);
    const biased: u32 = @intCast((bits >> 52) & 0x7FF);
    const is_neg = (bits >> 63) != 0;
    if (x == 0) return x; // ±0 keep the sign
    if (biased >= 0x3FF + 52) return x;
    if (biased < 0x3FF) return if (is_neg) -0.0 else 1.0;
    const shift: u6 = @intCast(52 - (biased - 0x3FF));
    const mask = (@as(u64, 1) << shift) - 1;
    if ((bits & mask) == 0) return x;
    const truncated: f64 = @bitCast(bits & ~mask);
    return if (is_neg) truncated else truncated + 1.0;
}

pub export fn trunc(x: f64) callconv(.c) f64 {
    // See floor() for the @trunc rationale (C51).
    const bits: u64 = @bitCast(x);
    const biased: u32 = @intCast((bits >> 52) & 0x7FF);
    if (biased >= 0x3FF + 52) return x;
    if (biased < 0x3FF) return if ((bits >> 63) != 0) -0.0 else 0.0;
    const shift: u6 = @intCast(52 - (biased - 0x3FF));
    const mask = (@as(u64, 1) << shift) - 1;
    return @bitCast(bits & ~mask);
}

pub export fn rint(x: f64) callconv(.c) f64 {
    // Round to nearest, ties to even (wasm f64.nearest). Bit trick again:
    // no @rint builtin exists on baseline, and a naive round() would break
    // ties-to-even. See floor() for the rationale (C51).
    const bits: u64 = @bitCast(x);
    const biased: u32 = @intCast((bits >> 52) & 0x7FF);
    const is_neg = (bits >> 63) != 0;
    if (biased >= 0x3FF + 52) return x;
    if (biased < 0x3FF) return if (is_neg) -0.0 else 0.0;
    const shift: u6 = @intCast(52 - (biased - 0x3FF));
    const mask = (@as(u64, 1) << shift) - 1;
    const frac = bits & mask;
    if (frac == 0) return x;
    const truncated: f64 = @bitCast(bits & ~mask);
    const half = @as(u64, 1) << (shift - 1);
    if (frac < half) return truncated;
    if (frac > half) return if (is_neg) truncated - 1.0 else truncated + 1.0;
    const lsb = (bits >> shift) & 1;
    if (lsb == 0) return truncated;
    return if (is_neg) truncated - 1.0 else truncated + 1.0;
}

pub export fn copysign(a: f64, b: f64) callconv(.c) f64 {
    const sign_mask: u64 = @as(u64, 1) << 63;
    return @bitCast((@as(u64, @bitCast(a)) & ~sign_mask) | (@as(u64, @bitCast(b)) & sign_mask));
}

pub export fn sqrt(x: f64) callconv(.c) f64 {
    // Newton-Raphson with a bit-level initial guess. @sqrt is forbidden here
    // for the same self-recursion reason as @floor (C51): on baseline x86_64
    // it lowers to a call of the C symbol `sqrt`.
    const bits: u64 = @bitCast(x);
    const biased = (bits >> 52) & 0x7FF;
    if (biased == 0x7FF) return x; // inf or nan
    if ((bits >> 63) != 0) return std.math.nan(f64); // negative
    if (x == 0) return x;
    var y: f64 = @bitCast((bits >> 1) + 0x1FF8000000000000); // ±2.4% initial guess
    var i: usize = 0;
    while (i < 8) : (i += 1) y = 0.5 * (y + x / y);
    return y;
}

export fn pow(base: f64, exp: f64) callconv(.c) f64 {
    return std.math.pow(f64, base, exp);
}

export fn acos(x: f64) callconv(.c) f64 {
    return std.math.acos(x);
}

export fn asin(x: f64) callconv(.c) f64 {
    return std.math.asin(x);
}

export fn atan2(y: f64, x: f64) callconv(.c) f64 {
    return std.math.atan2(y, x);
}

export fn frexp(x: f64, exp: *c_int) callconv(.c) f64 {
    if (x == 0) {
        exp.* = 0;
        return 0;
    }
    const bits: u64 = @bitCast(x);
    const raw_exp: u32 = @intCast((bits >> 52) & 0x7ff);
    if (raw_exp == 0x7ff) { // inf or nan
        exp.* = 0;
        return x;
    }
    const unbiased: i32 = @as(i32, @intCast(raw_exp)) - 1022;
    exp.* = unbiased;
    const mantissa_bits: u64 = (bits & 0x000fffffffffffff) | 0x0010000000000000;
    const new_bits: u64 = (bits & 0x8000000000000000) | (mantissa_bits >> 1);
    return @bitCast(new_bits);
}

export fn ldexp(x: f64, exp: c_int) callconv(.c) f64 {
    return std.math.scalbn(x, exp);
}

export fn strtod(str: [*:0]const u8, endptr: ?*[*:0]const u8) callconv(.c) f64 {
    var i: usize = 0;
    while (isspace(str[i]) != 0) i += 1;
    var neg = false;
    if (str[i] == '-') {
        neg = true;
        i += 1;
    } else if (str[i] == '+') {
        i += 1;
    }
    var value: f64 = 0;
    var any = false;
    while (str[i] >= '0' and str[i] <= '9') : (i += 1) {
        value = value * 10 + (str[i] - '0');
        any = true;
    }
    var frac_pow: f64 = 0.1;
    if (str[i] == '.') {
        i += 1;
        while (str[i] >= '0' and str[i] <= '9') : (i += 1) {
            value += (str[i] - '0') * frac_pow;
            frac_pow *= 0.1;
            any = true;
        }
    }
    var exponent: i64 = 0;
    if (str[i] == 'e' or str[i] == 'E') {
        i += 1;
        var exp_neg = false;
        if (str[i] == '-') {
            exp_neg = true;
            i += 1;
        } else if (str[i] == '+') {
            i += 1;
        }
        while (str[i] >= '0' and str[i] <= '9') : (i += 1) {
            exponent = exponent * 10 + (str[i] - '0');
            // Saturate so a huge exponent cannot overflow (2026-08-15-self-audit).
            if (exponent > 9999) exponent = 9999;
        }
        if (exp_neg) exponent = -exponent;
    }
    if (endptr) |ep| {
        ep.* = if (any) str + i else str;
    }
    if (!any) return 0;
    value = value * std.math.pow(f64, 10.0, @floatFromInt(exponent));
    return if (neg) -value else value;
}

export fn lua_serial_write(c: u8) callconv(.c) void {
    const serial_mod = @import("serial.zig");
    serial_mod.writeChar(c);
}

export fn strlen(str: [*:0]const u8) callconv(.c) usize {
    return std.mem.len(str);
}
