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
