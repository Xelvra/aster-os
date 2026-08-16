const fb_mod = @import("../fb/framebuffer.zig");
const font = @import("font.zig");

pub const Framebuffer = fb_mod.Framebuffer;
pub const Color = u32;

pub const Renderer = struct {
    fb: *Framebuffer,

    pub fn init(fb: *Framebuffer) Renderer {
        return .{ .fb = fb };
    }

    pub fn drawRect(self: *const Renderer, x: i32, y: i32, w: u32, h: u32, color: Color) void {
        self.fb.fillRect(x, y, w, h, self.fb.pixelColor(color));
    }

    pub fn fillScreen(self: *const Renderer, color: Color) void {
        self.fb.fillScreen(self.fb.pixelColor(color));
    }

    pub fn blit(self: *const Renderer, src: [*]const u8, src_x: i32, src_y: i32, dst_x: i32, dst_y: i32, w: u32, h: u32) void {
        self.fb.blit(src, src_x, src_y, dst_x, dst_y, w, h);
    }

    pub fn roundRect(self: *const Renderer, x: i32, y: i32, w: u32, h: u32, radius: u32, color: Color) void {
        self.fb.roundRect(x, y, w, h, radius, self.fb.pixelColor(color));
    }

    pub fn rectBorder(self: *const Renderer, x: i32, y: i32, w: u32, h: u32, thickness: u32, color: Color) void {
        self.fb.rectBorder(x, y, w, h, thickness, self.fb.pixelColor(color));
    }

    pub fn gradientBorder(self: *const Renderer, x: i32, y: i32, w: u32, h: u32, thickness: u32, color_a: Color, color_b: Color) void {
        self.fb.gradientBorder(x, y, w, h, thickness, color_a, color_b);
    }

    pub fn drawGlyph(self: *const Renderer, codepoint: u32, x: i32, y: i32, color: Color) void {
        const pixels = font.glyph(codepoint);
        for (0..font.glyph_height) |row| {
            var bit: u5 = 0;
            while (bit < font.glyph_width) : (bit += 1) {
                const mask: u8 = @as(u8, 1) << @intCast(7 - bit);
                if (pixels[row] & mask != 0) {
                    // Widen to i64 before adding so an extreme x/y cannot
                    // overflow i32 (audit 2026-08-15); negative results are
                    // off-screen and skipped, setPixel clamps the upper edge.
                    const px = @as(i64, x) + @as(i64, bit);
                    const py = @as(i64, y) + @as(i64, @intCast(row));
                    if (px < 0 or py < 0) continue;
                    self.fb.setPixel(@intCast(px), @intCast(py), self.fb.pixelColor(color));
                }
            }
        }
    }

    pub fn drawText(self: *const Renderer, text: []const u8, x: i32, y: i32, color: Color) void {
        const pixel = self.fb.pixelColor(color);
        var cursor_x = x;
        for (text) |c| {
            const pixels = font.glyph(c);
            for (0..font.glyph_height) |row| {
                const bits = pixels[row];
                if (bits == 0) continue;
                self.fb.drawGlyphRow(cursor_x, y + @as(i32, @intCast(row)), bits, pixel);
            }
            cursor_x += font.glyph_width;
        }
    }
};
