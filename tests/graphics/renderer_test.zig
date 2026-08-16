const std = @import("std");
const framebuffer = @import("kernel").framebuffer;
const renderer = @import("kernel").renderer;
const font = @import("kernel").font;
const boot_info = @import("kernel").boot_info;

const FbWidth = 64;
const FbHeight = 32;

const Context = struct {
    memory: [FbWidth * FbHeight * 4]u8 align(16),
    fb: framebuffer.Framebuffer,
    renderer: renderer.Renderer,
};

fn initCtx(ctx: *Context) void {
    ctx.memory = [_]u8{0} ** (FbWidth * FbHeight * 4);
    ctx.fb = framebuffer.Framebuffer.init(.{
        .address = @intFromPtr(&ctx.memory),
        .width = FbWidth,
        .height = FbHeight,
        .pitch = FbWidth * 4,
        .bpp = 32,
        .memory_model = 1,
        .red_mask_size = 8,
        .red_mask_shift = 16,
        .green_mask_size = 8,
        .green_mask_shift = 8,
        .blue_mask_size = 8,
        .blue_mask_shift = 0,
    }).?;
    ctx.renderer = renderer.Renderer.init(&ctx.fb);
}

test "drawRect writes colored pixels via renderer" {
    var ctx: Context = undefined;
    initCtx(&ctx);
    ctx.renderer.drawRect(2, 2, 5, 3, 0xFF0000);
    try std.testing.expectEqual(@as(u32, 0xFF0000), ctx.fb.getPixel(2, 2));
    try std.testing.expectEqual(@as(u32, 0xFF0000), ctx.fb.getPixel(6, 4));
    try std.testing.expectEqual(@as(u32, 0x000000), ctx.fb.getPixel(1, 2));
}

test "drawRect fully outside bounds is a no-op" {
    var ctx: Context = undefined;
    initCtx(&ctx);
    ctx.renderer.fillScreen(0x111111);
    ctx.renderer.drawRect(FbWidth, 0, 5, 5, 0xFF0000);
    try std.testing.expectEqual(@as(u32, 0x111111), ctx.fb.getPixel(0, 0));
}

test "drawGlyph draws at position and clips out of bounds" {
    var ctx: Context = undefined;
    initCtx(&ctx);
    const a = font.glyph('A');
    var expected_ink: usize = 0;
    for (a) |row| {
        for (0..font.glyph_width) |bit| {
            const mask: u8 = @as(u8, 1) << @intCast(7 - @as(u5, @intCast(bit)));
            if (row & mask != 0) expected_ink += 1;
        }
    }
    ctx.renderer.drawGlyph('A', 0, 0, 0xFFFFFF);
    var drawn: usize = 0;
    for (0..font.glyph_height) |row| {
        for (0..font.glyph_width) |bit| {
            if (ctx.fb.getPixel(@intCast(bit), @intCast(row)) == 0xFFFFFF) drawn += 1;
        }
    }
    try std.testing.expectEqual(expected_ink, drawn);
}

test "drawText writes sequential glyphs" {
    var ctx: Context = undefined;
    initCtx(&ctx);
    ctx.renderer.drawText("hi", 0, 0, 0xFFFFFF);
    var drawn: usize = 0;
    for (ctx.memory) |b| {
        if (b != 0) drawn += 1;
    }
    try std.testing.expect(drawn > 0);
}

fn memoryEqual(a: *const Context, b: *const Context) bool {
    return std.mem.eql(u8, &a.memory, &b.memory);
}

test "drawText renders a multi-byte UTF-8 char as one fallback glyph, not byte noise" {
    // Audit 2026-08-15: drawText used to iterate bytes, so 'ž' (2 bytes)
    // drew two garbage glyphs. A multi-byte code point must decode to a
    // single glyph — the ASCII font's fallback '?' for non-ASCII — and the
    // following character must land right after it (monospace 8px advance).
    var ctx: Context = undefined;
    initCtx(&ctx);
    ctx.renderer.drawText("ž", 0, 0, 0xFFFFFF);

    var ref: Context = undefined;
    initCtx(&ref);
    ref.renderer.drawText("?", 0, 0, 0xFFFFFF);
    try std.testing.expect(memoryEqual(&ctx, &ref));

    // Mixed text: "ažb" == "a?b", byte for byte.
    initCtx(&ctx);
    ctx.renderer.drawText("ažb", 0, 0, 0xFFFFFF);
    initCtx(&ref);
    ref.renderer.drawText("a?b", 0, 0, 0xFFFFFF);
    try std.testing.expect(memoryEqual(&ctx, &ref));
}

test "drawText decodes a malformed UTF-8 byte as a single fallback glyph" {
    var ctx: Context = undefined;
    initCtx(&ctx);
    // A lone continuation byte (0x80) and an unterminated lead (0xC4 at the
    // end) must not draw per-byte noise — each becomes one fallback glyph.
    ctx.renderer.drawText(&.{ 0x41, 0x80, 0x42, 0xC4 }, 0, 0, 0xFFFFFF);

    var ref: Context = undefined;
    initCtx(&ref);
    ref.renderer.drawText("A?B?", 0, 0, 0xFFFFFF);
    try std.testing.expect(memoryEqual(&ctx, &ref));
}

test "roundRect fills interior and rounds corners" {
    var ctx: Context = undefined;
    initCtx(&ctx);
    ctx.renderer.roundRect(2, 2, 10, 10, 4, 0xFF0000);
    try std.testing.expectEqual(@as(u32, 0xFF0000), ctx.fb.getPixel(6, 6)); // center
    try std.testing.expectEqual(@as(u32, 0x000000), ctx.fb.getPixel(3, 3)); // corner cut (inside the arc)
    try std.testing.expectEqual(@as(u32, 0xFF0000), ctx.fb.getPixel(5, 5)); // inside the rounded corner
    try std.testing.expectEqual(@as(u32, 0xFF0000), ctx.fb.getPixel(6, 2)); // top edge
}

test "rectBorder draws outline only, leaves interior empty" {
    var ctx: Context = undefined;
    initCtx(&ctx);
    ctx.renderer.rectBorder(2, 2, 10, 10, 2, 0xFF0000);
    try std.testing.expectEqual(@as(u32, 0xFF0000), ctx.fb.getPixel(2, 2)); // top-left
    try std.testing.expectEqual(@as(u32, 0xFF0000), ctx.fb.getPixel(11, 11)); // bottom-right
    try std.testing.expectEqual(@as(u32, 0x000000), ctx.fb.getPixel(6, 6)); // interior
}

test "gradientBorder interpolates colors along the diagonal" {
    var ctx: Context = undefined;
    initCtx(&ctx);
    ctx.renderer.gradientBorder(0, 0, 8, 8, 1, 0x000000, 0xFFFFFF);
    try std.testing.expectEqual(@as(u32, 0x000000), ctx.fb.getPixel(0, 0)); // start (top-left)
    const top_right = ctx.fb.getPixel(7, 0);
    try std.testing.expect(top_right > 0x000000); // interpolated towards white
    const bottom_right = ctx.fb.getPixel(7, 7);
    try std.testing.expect(bottom_right >= top_right); // monotonic to the bottom-right
}

test "gradientBorder is a uniform ring on all edges" {
    var ctx: Context = undefined;
    initCtx(&ctx);
    ctx.renderer.gradientBorder(0, 0, 10, 10, 2, 0xFFFFFF, 0xFFFFFF);
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), ctx.fb.getPixel(5, 0)); // top edge, 2px
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), ctx.fb.getPixel(5, 1));
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), ctx.fb.getPixel(0, 5)); // left edge, 2px
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), ctx.fb.getPixel(1, 5));
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), ctx.fb.getPixel(9, 5)); // right edge, 2px
    try std.testing.expectEqual(@as(u32, 0x000000), ctx.fb.getPixel(5, 5)); // interior empty
}
