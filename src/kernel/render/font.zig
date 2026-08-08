const data = @import("font_data.zig");

pub const glyph_width = data.glyph_width;
pub const glyph_height = data.glyph_height;

pub fn glyph(codepoint: u32) [glyph_height]u8 {
    return data.glyph(codepoint);
}
