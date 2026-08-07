const std = @import("std");
const boot_info = @import("../boot/boot_info.zig");

pub const Framebuffer = struct {
    base: [*]volatile u8,
    width: u32,
    height: u32,
    pitch: u32,
    bytes_per_pixel: u8,
    red_shift: u5,
    green_shift: u5,
    blue_shift: u5,

    pub fn init(info: boot_info.Framebuffer) Framebuffer {
        const red_shift: u5 = @intCast(info.red_mask_shift);
        const green_shift: u5 = @intCast(info.green_mask_shift);
        const blue_shift: u5 = @intCast(info.blue_mask_shift);
        return .{
            .base = @ptrFromInt(info.address),
            .width = @intCast(info.width),
            .height = @intCast(info.height),
            .pitch = @intCast(info.pitch),
            .bytes_per_pixel = @intCast(info.bpp / 8),
            .red_shift = red_shift,
            .green_shift = green_shift,
            .blue_shift = blue_shift,
        };
    }

    pub fn pixelColor(self: *const Framebuffer, color: u32) u32 {
        const red: u32 = (color >> 16) & 0xFF;
        const green: u32 = (color >> 8) & 0xFF;
        const blue: u32 = color & 0xFF;
        return (red << self.red_shift) | (green << self.green_shift) | (blue << self.blue_shift);
    }

    pub fn setPixel(self: *Framebuffer, x: u32, y: u32, color: u32) void {
        if (x >= self.width or y >= self.height) return;
        const offset = y * self.pitch + x * self.bytes_per_pixel;
        const px: [*]volatile u32 = @ptrCast(@alignCast(self.base + offset));
        px[0] = color;
    }

    /// Write one 8-bit glyph row into the framebuffer starting at (x, y).
    /// Pixels where the corresponding glyph bit is 0 are left untouched,
    /// so callers can draw onto an existing background.
    pub fn drawGlyphRow(self: *Framebuffer, x: i32, y: i32, bits: u8, color: u32) void {
        if (y < 0 or y >= self.height) return;
        const row_offset = @as(i64, y) * self.pitch;
        var bit: u5 = 0;
        while (bit < 8) : (bit += 1) {
            const mask: u8 = @as(u8, 1) << @intCast(7 - bit);
            if (bits & mask == 0) continue;
            const dst_x = x + @as(i32, @intCast(bit));
            if (dst_x < 0 or dst_x >= self.width) continue;
            const offset = row_offset + @as(i64, @intCast(dst_x)) * self.bytes_per_pixel;
            const px: [*]volatile u32 = @ptrCast(@alignCast(self.base + @as(usize, @intCast(offset))));
            px[0] = color;
        }
    }

    pub fn getPixel(self: *const Framebuffer, x: u32, y: u32) u32 {
        if (x >= self.width or y >= self.height) return 0;
        const offset = y * self.pitch + x * self.bytes_per_pixel;
        const px: [*]const volatile u32 = @ptrCast(@alignCast(self.base + offset));
        return px[0];
    }

    pub fn fillRect(self: *Framebuffer, x: i32, y: i32, w: u32, h: u32, color: u32) void {
        const clipped = clipRect(x, y, w, h, self.width, self.height) orelse return;
        const cols = clipped.x1 - clipped.x0;
        const pair: u64 = (@as(u64, color) << 32) | color;
        for (clipped.y0..clipped.y1) |row| {
            const row_offset = row * self.pitch + clipped.x0 * self.bytes_per_pixel;
            // Write 64-bit pairs where the row start is 8-byte aligned, else
            // fall back to 32-bit writes. The framebuffer is write-combining,
            // so wide writes let the WC buffer coalesce.
            if (row_offset % 8 == 0) {
                const wide: [*]volatile u64 = @ptrFromInt(@intFromPtr(self.base) + row_offset);
                var col: usize = 0;
                while (col + 1 < cols) : (col += 2) {
                    wide[col / 2] = pair;
                }
                if (col < cols) {
                    const tail: [*]volatile u32 = @ptrFromInt(@intFromPtr(self.base) + row_offset + col * 4);
                    tail[0] = color;
                }
            } else {
                const line: [*]volatile u32 = @ptrFromInt(@intFromPtr(self.base) + row_offset);
                for (0..cols) |col| {
                    line[col] = color;
                }
            }
        }
    }

    pub fn blit(self: *Framebuffer, src: [*]const u8, src_x: i32, src_y: i32, dst_x: i32, dst_y: i32, w: u32, h: u32) void {
        const clipped = clipRect(dst_x, dst_y, w, h, self.width, self.height) orelse return;
        const src_offset_x = @as(i32, @intCast(clipped.x0)) - dst_x;
        const src_offset_y = @as(i32, @intCast(clipped.y0)) - dst_y;
        const row_count = clipped.y1 - clipped.y0;
        const col_count = clipped.x1 - clipped.x0;
        const bytes_per_row = @as(i32, @intCast(w)) * self.bytes_per_pixel;
        for (0..row_count) |r| {
            const src_row = (src_y + src_offset_y + @as(i32, @intCast(r))) * bytes_per_row + (src_x + src_offset_x) * self.bytes_per_pixel;
            const dst_row = (clipped.y0 + @as(u32, @intCast(r))) * self.pitch + clipped.x0 * self.bytes_per_pixel;
            const bytes = col_count * self.bytes_per_pixel;
            const src_ptr: [*]const u8 = @ptrFromInt(@intFromPtr(src) + @as(usize, @intCast(src_row)));
            const dst_ptr: [*]volatile u8 = self.base + dst_row;
            for (0..bytes) |i| {
                dst_ptr[i] = src_ptr[i];
            }
        }
    }

    pub fn fillScreen(self: *Framebuffer, color: u32) void {
        self.fillRect(0, 0, self.width, self.height, color);
    }

    /// Fill a rectangle with rounded corners of the given radius. Pixels
    /// outside the rounded shape are left untouched.
    pub fn roundRect(self: *Framebuffer, x: i32, y: i32, w: u32, h: u32, radius: u32, color: u32) void {
        if (w == 0 or h == 0) return;
        const r = @min(radius, @min(w / 2, h / 2));
        const r_i: i32 = @intCast(r);
        // Center body (covers everything except the four corners).
        self.fillRect(x + r_i, y, w - r * 2, h, color);
        // Top/bottom strips between the corners.
        self.fillRect(x, y + r_i, w, h - r * 2, color);
        // Corners: iterate the r x r box and keep pixels inside the arc.
        var cy: i32 = 0;
        while (cy < r_i) : (cy += 1) {
            var cx: i32 = 0;
            while (cx < r_i) : (cx += 1) {
                if (cx * cx + cy * cy > r_i * r_i) continue;
                const px = x + cx;
                const py = y + cy;
                const corners = [_][2]i32{
                    .{ px, py },
                    .{ x + @as(i32, @intCast(w)) - 1 - cx, py },
                    .{ px, y + @as(i32, @intCast(h)) - 1 - cy },
                    .{ x + @as(i32, @intCast(w)) - 1 - cx, y + @as(i32, @intCast(h)) - 1 - cy },
                };
                for (corners) |corner| {
                    self.setPixel(@intCast(corner[0]), @intCast(corner[1]), color);
                }
            }
        }
    }

    /// Draw the border of a rectangle (the interior is left untouched).
    pub fn rectBorder(self: *Framebuffer, x: i32, y: i32, w: u32, h: u32, thickness: u32, color: u32) void {
        if (w == 0 or h == 0 or thickness == 0) return;
        const t_u: u32 = @min(thickness, @min(w / 2, h / 2));
        const t: i32 = @intCast(t_u);
        self.fillRect(x, y, w, t_u, color); // top
        self.fillRect(x, y + @as(i32, @intCast(h)) - t, w, t_u, color); // bottom
        self.fillRect(x, y, t_u, h, color); // left
        self.fillRect(x + @as(i32, @intCast(w)) - t, y, t_u, h, color); // right
    }

    /// Draw a rectangle border whose color interpolates linearly from
    /// `color_a` (top-left) to `color_b` (bottom-right), matching the
    /// active window look. Colors are 0xRRGGBB.
    pub fn gradientBorder(self: *Framebuffer, x: i32, y: i32, w: u32, h: u32, thickness: u32, color_a: u32, color_b: u32) void {
        if (w == 0 or h == 0 or thickness == 0) return;
        const t_u: u32 = @min(thickness, @min(w / 2, h / 2));
        const t: i32 = @intCast(t_u);
        const half: i32 = @divTrunc(t, 2);
        const w_i: i32 = @intCast(w);
        const h_i: i32 = @intCast(h);
        // Perimeter of a w x h rectangle = 2w + 2h - 4 pixels.
        const total: i32 = 2 * w_i + 2 * h_i - 4;
        if (total <= 0) return;
        const ar: i32 = @intCast((color_a >> 16) & 0xFF);
        const ag: i32 = @intCast((color_a >> 8) & 0xFF);
        const ab: i32 = @intCast(color_a & 0xFF);
        const br: i32 = @intCast((color_b >> 16) & 0xFF);
        const bg: i32 = @intCast((color_b >> 8) & 0xFF);
        const bb: i32 = @intCast(color_b & 0xFF);
        var i: i32 = 0;
        while (i < total) : (i += 1) {
            // Walk the perimeter clockwise: top, right, bottom, left.
            var px: i32 = undefined;
            var py: i32 = undefined;
            if (i < w_i) {
                px = x + i;
                py = y;
            } else if (i < w_i + h_i - 1) {
                px = x + w_i - 1;
                py = y + (i - w_i);
            } else if (i < w_i + h_i - 1 + w_i - 1) {
                px = x + (w_i - 1) - (i - w_i - h_i + 1);
                py = y + h_i - 1;
            } else {
                px = x;
                py = y + (h_i - 1) - (i - 2 * w_i - h_i + 2);
            }
            const t_frac = @divTrunc(i * 1000, total);
            const rr = ar + @divTrunc((br - ar) * t_frac, 1000);
            const gg = ag + @divTrunc((bg - ag) * t_frac, 1000);
            const bbb = ab + @divTrunc((bb - ab) * t_frac, 1000);
            const color: u32 = (@as(u32, @intCast(rr)) << 16) | (@as(u32, @intCast(gg)) << 8) | @as(u32, @intCast(bbb));
            // Stamp the color as a t x t block at each perimeter pixel so a
            // 2px border does not leave gaps.
            for (0..@intCast(t)) |oy| {
                for (0..@intCast(t)) |ox| {
                    const ox_i: i32 = @intCast(ox);
                    const oy_i: i32 = @intCast(oy);
                    const dx = px + ox_i - half;
                    const dy = py + oy_i - half;
                    if (dx < x or dx >= x + w_i or dy < y or dy >= y + h_i) continue;
                    self.setPixel(@intCast(dx), @intCast(dy), color);
                }
            }
        }
    }
};

const ClipRect = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
};

fn clipRect(x: i32, y: i32, w: u32, h: u32, fb_width: u32, fb_height: u32) ?ClipRect {
    const x0 = @max(x, 0);
    const y0 = @max(y, 0);
    const x1 = @min(@as(i64, x) + w, @as(i64, fb_width));
    const y1 = @min(@as(i64, y) + h, @as(i64, fb_height));
    if (x1 <= x0 or y1 <= y0) return null;
    return .{
        .x0 = @intCast(x0),
        .y0 = @intCast(y0),
        .x1 = @intCast(x1),
        .y1 = @intCast(y1),
    };
}
