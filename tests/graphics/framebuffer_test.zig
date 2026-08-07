const std = @import("std");
const framebuffer = @import("kernel").framebuffer;
const boot_info = @import("kernel").boot_info;

const FbWidth = 40;
const FbHeight = 20;

const Context = struct {
    memory: [FbWidth * FbHeight * 4]u8 align(16),
    fb: framebuffer.Framebuffer,
};

fn initFb(ctx: *Context) void {
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
    });
}

fn readColor(ctx: *Context, x: u32, y: u32) u32 {
    return ctx.fb.getPixel(x, y);
}

test "fillScreen fills all pixels" {
    var ctx: Context = undefined;
    initFb(&ctx);
    ctx.fb.fillScreen(0xFF0000);
    try std.testing.expectEqual(@as(u32, 0xFF0000), readColor(&ctx, 0, 0));
    try std.testing.expectEqual(@as(u32, 0xFF0000), readColor(&ctx, FbWidth - 1, FbHeight - 1));
    try std.testing.expectEqual(@as(u32, 0xFF0000), readColor(&ctx, FbWidth / 2, FbHeight / 2));
}

test "fillRect within bounds" {
    var ctx: Context = undefined;
    initFb(&ctx);
    ctx.fb.fillRect(5, 5, 10, 4, 0x00FF00);
    try std.testing.expectEqual(@as(u32, 0x00FF00), readColor(&ctx, 5, 5));
    try std.testing.expectEqual(@as(u32, 0x00FF00), readColor(&ctx, 14, 8));
    try std.testing.expectEqual(@as(u32, 0x000000), readColor(&ctx, 4, 5));
    try std.testing.expectEqual(@as(u32, 0x000000), readColor(&ctx, 15, 8));
    try std.testing.expectEqual(@as(u32, 0x000000), readColor(&ctx, 5, 4));
}

test "fillRect clipped at right edge" {
    var ctx: Context = undefined;
    initFb(&ctx);
    ctx.fb.fillRect(FbWidth - 5, 3, 10, 4, 0x0000FF);
    try std.testing.expectEqual(@as(u32, 0x0000FF), readColor(&ctx, FbWidth - 5, 3));
    try std.testing.expectEqual(@as(u32, 0x0000FF), readColor(&ctx, FbWidth - 1, 6));
}

test "fillRect clipped at bottom edge" {
    var ctx: Context = undefined;
    initFb(&ctx);
    ctx.fb.fillRect(2, FbHeight - 3, 4, 10, 0xFFFFFF);
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), readColor(&ctx, 2, FbHeight - 3));
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), readColor(&ctx, 5, FbHeight - 1));
}

test "fillRect with negative origin" {
    var ctx: Context = undefined;
    initFb(&ctx);
    ctx.fb.fillRect(-3, -2, 10, 8, 0x00FFFF);
    try std.testing.expectEqual(@as(u32, 0x00FFFF), readColor(&ctx, 0, 0));
    try std.testing.expectEqual(@as(u32, 0x00FFFF), readColor(&ctx, 6, 5));
}

test "fillRect fully outside returns without writing" {
    var ctx: Context = undefined;
    initFb(&ctx);
    ctx.fb.fillScreen(0x111111);
    ctx.fb.fillRect(FbWidth, 0, 5, 5, 0xFF0000);
    ctx.fb.fillRect(-5, 0, 5, 5, 0xFF0000);
    ctx.fb.fillRect(0, FbHeight, 5, 5, 0xFF0000);
    ctx.fb.fillRect(0, -5, 5, 5, 0xFF0000);
    try std.testing.expectEqual(@as(u32, 0x111111), readColor(&ctx, 0, 0));
    try std.testing.expectEqual(@as(u32, 0x111111), readColor(&ctx, FbWidth - 1, FbHeight - 1));
}

test "blit copies block" {
    var ctx: Context = undefined;
    initFb(&ctx);
    var src: [8 * 4 * 4]u8 = undefined;
    for (0..src.len) |i| src[i] = 0xAB;
    ctx.fb.blit(&src, 0, 0, 2, 2, 4, 4);
    try std.testing.expectEqual(@as(u32, 0xABABABAB), readColor(&ctx, 2, 2));
    try std.testing.expectEqual(@as(u32, 0xABABABAB), readColor(&ctx, 5, 5));
    try std.testing.expectEqual(@as(u32, 0x000000), readColor(&ctx, 1, 2));
}

test "blit clipped at edge" {
    var ctx: Context = undefined;
    initFb(&ctx);
    var src: [8 * 4 * 4]u8 = undefined;
    for (0..src.len) |i| src[i] = 0xCD;
    ctx.fb.blit(&src, 0, 0, FbWidth - 2, FbHeight - 2, 4, 4);
    try std.testing.expectEqual(@as(u32, 0xCDCDCDCD), readColor(&ctx, FbWidth - 2, FbHeight - 2));
    try std.testing.expectEqual(@as(u32, 0xCDCDCDCD), readColor(&ctx, FbWidth - 1, FbHeight - 1));
}

test "pixelColor encodes RGB24 to RGBA" {
    var ctx: Context = undefined;
    initFb(&ctx);
    try std.testing.expectEqual(@as(u32, 0x00FFFFFF), ctx.fb.pixelColor(0xFFFFFF));
    try std.testing.expectEqual(@as(u32, 0x00FF0000), ctx.fb.pixelColor(0xFF0000));
    try std.testing.expectEqual(@as(u32, 0x0000FF00), ctx.fb.pixelColor(0x00FF00));
}
