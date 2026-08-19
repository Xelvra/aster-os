// Wasm side of the M7 Fáze C benchmark (spec/roadmap.md): a fixed-size
// Mandelbrot escape-time grid, computed once in start(). The iteration
// checksum is written to serial so the host can confirm this program and
// its Lua twin (src/kernel/lua/programs/bench.lua) computed the identical
// result — the timing itself is measured by the kernel around the spawn
// call (src/kernel/bench.zig), not inside the program.
extern fn debug_write(ptr: [*:0]const u8) void;

const width: u32 = 64;
const height: u32 = 64;
const max_iter: u32 = 50;

export fn start() void {
    var checksum: u64 = 0;
    var py: u32 = 0;
    while (py < height) : (py += 1) {
        const cy: f64 = -1.5 + @as(f64, @floatFromInt(py)) * (3.0 / @as(f64, height));
        var px: u32 = 0;
        while (px < width) : (px += 1) {
            const cx: f64 = -2.0 + @as(f64, @floatFromInt(px)) * (3.0 / @as(f64, width));
            var x: f64 = 0.0;
            var y: f64 = 0.0;
            var iter: u32 = 0;
            while (x * x + y * y <= 4.0 and iter < max_iter) : (iter += 1) {
                const x_temp = x * x - y * y + cx;
                y = 2.0 * x * y + cy;
                x = x_temp;
            }
            checksum += iter;
        }
    }

    var buf: [48]u8 = undefined;
    writeChecksum(&buf, checksum);
}

fn writeChecksum(buf: []u8, checksum: u64) void {
    // No libc, no std.fmt (wasm32-freestanding + no allocator here) — format
    // the decimal checksum by hand into a NUL-terminated buffer.
    const prefix = "BENCH WASM CHECKSUM ";
    @memcpy(buf[0..prefix.len], prefix);
    var i: usize = prefix.len;
    if (checksum == 0) {
        buf[i] = '0';
        i += 1;
    } else {
        var digits: [20]u8 = undefined;
        var n = checksum;
        var d: usize = 0;
        while (n > 0) : (n /= 10) {
            digits[d] = @as(u8, @intCast(n % 10)) + '0';
            d += 1;
        }
        while (d > 0) {
            d -= 1;
            buf[i] = digits[d];
            i += 1;
        }
    }
    buf[i] = '\n';
    i += 1;
    buf[i] = 0;
    debug_write(buf[0..i :0]);
}
