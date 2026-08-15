const std = @import("std");
const fb_mod = @import("../fb/framebuffer.zig");

const cursor_w: u32 = 12;
const cursor_h: u32 = 19;

/// The mouse cursor is drawn by the kernel as an overlay, not by the Lua
/// render loop. This keeps the pointer smooth: moving the mouse only
/// restores the saved pixels under the old position and draws the sprite
/// at the new one — no full-screen repaint, no Lua round-trip.
pub const MouseCursor = struct {
    x: i32 = 0,
    y: i32 = 0,
    saved: [cursor_w * cursor_h]u32 = undefined,
    valid: bool = false,

    /// Set the initial position and draw the cursor once.
    pub fn init(self: *MouseCursor, fb: *fb_mod.Framebuffer, x: i32, y: i32) void {
        self.x = x;
        self.y = y;
        self.saveAndDraw(fb);
    }

    /// Move the cursor by a relative delta, restoring the old pixels first.
    /// Pure 1:1 geometry — the input event loop applies any speed multiplier
    /// before calling this (main.zig), so the overlay stays testable.
    pub fn move(self: *MouseCursor, fb: *fb_mod.Framebuffer, dx: i16, dy: i16) void {
        if (self.valid) self.restore(fb);
        self.x +|= dx;
        self.y +|= dy;
        const max_x: i32 = @as(i32, @intCast(fb.width)) - @as(i32, @intCast(cursor_w));
        const max_y: i32 = @as(i32, @intCast(fb.height)) - @as(i32, @intCast(cursor_h));
        self.x = std.math.clamp(self.x, 0, @max(max_x, 0));
        self.y = std.math.clamp(self.y, 0, @max(max_y, 0));
        self.saveAndDraw(fb);
    }

    /// The Lua render loop has redrawn the whole screen, so capture the
    /// pixels under the cursor and draw it on top. The scene already erased
    /// the old cursor, so there is nothing to restore — restore() would
    /// write the stale saved pixels (captured before the redraw) over the
    /// fresh scene and leave a dark rectangle artifact.
    pub fn redraw(self: *MouseCursor, fb: *fb_mod.Framebuffer) void {
        self.saveAndDraw(fb);
    }

    fn saveAndDraw(self: *MouseCursor, fb: *fb_mod.Framebuffer) void {
        for (0..cursor_h) |row| {
            const py = self.y + @as(i32, @intCast(row));
            if (py < 0 or py >= fb.height) continue;
            for (0..cursor_w) |col| {
                const px = self.x + @as(i32, @intCast(col));
                if (px < 0 or px >= fb.width) continue;
                self.saved[row * cursor_w + col] = fb.getPixel(@intCast(px), @intCast(py));
            }
        }
        self.valid = true;
        self.draw(fb);
    }

    fn restore(self: *MouseCursor, fb: *fb_mod.Framebuffer) void {
        for (0..cursor_h) |row| {
            const py = self.y + @as(i32, @intCast(row));
            if (py < 0 or py >= fb.height) continue;
            for (0..cursor_w) |col| {
                const px = self.x + @as(i32, @intCast(col));
                if (px < 0 or px >= fb.width) continue;
                fb.setPixel(@intCast(px), @intCast(py), self.saved[row * cursor_w + col]);
            }
        }
        self.valid = false;
    }

    fn draw(self: *MouseCursor, fb: *fb_mod.Framebuffer) void {
        // Simple arrow: a diagonal shaft with a flat tail. White fill with
        // a black outline reads well on any background.
        const outline = fb.pixelColor(0x000000);
        const fill = fb.pixelColor(0xFFFFFF);
        var row: u32 = 0;
        while (row < cursor_h) : (row += 1) {
            var col: u32 = 0;
            while (col < cursor_w) : (col += 1) {
                const in_shaft = col <= row;
                const in_tail = row >= 11 and col <= 1;
                if (!in_shaft and !in_tail) continue;
                const px = self.x + @as(i32, @intCast(col));
                const py = self.y + @as(i32, @intCast(row));
                if (px < 0 or px >= fb.width or py < 0 or py >= fb.height) continue;
                const is_core = col + 1 < row and row < cursor_h - 1;
                const color = if (is_core) fill else outline;
                fb.setPixel(@intCast(px), @intCast(py), color);
            }
        }
    }
};

pub const width = cursor_w;
pub const height = cursor_h;
