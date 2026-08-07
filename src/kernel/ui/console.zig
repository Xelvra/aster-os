const std = @import("std");
const renderer_mod = @import("../render/renderer.zig");
const font = @import("../render/font.zig");

pub const Renderer = renderer_mod.Renderer;

pub const Console = struct {
    cols: usize,
    rows: usize,
    cells: []u8,
    cursor_col: usize,
    cursor_row: usize,
    cursor_visible: bool,
    dirty: bool,

    pub fn init() Console {
        return .{
            .cols = 0,
            .rows = 0,
            .cells = &.{},
            .cursor_col = 0,
            .cursor_row = 0,
            .cursor_visible = true,
            .dirty = true,
        };
    }

    pub fn reset(self: *Console, cols: usize, rows: usize, cells: []u8) void {
        self.cols = cols;
        self.rows = rows;
        self.cells = cells;
        self.cursor_col = 0;
        self.cursor_row = 0;
        self.dirty = true;
        self.clear();
    }

    pub fn clear(self: *Console) void {
        @memset(self.cells, ' ');
        self.dirty = true;
    }

    pub fn newline(self: *Console) void {
        self.cursor_col = 0;
        if (self.cursor_row + 1 < self.rows) {
            self.cursor_row += 1;
        } else {
            self.scroll();
        }
        self.dirty = true;
    }

    pub fn backspace(self: *Console) void {
        if (self.cursor_col > 0) {
            self.cursor_col -= 1;
            self.cellPtr(self.cursor_col, self.cursor_row).* = ' ';
        } else if (self.cursor_row > 0) {
            self.cursor_row -= 1;
            self.cursor_col = self.cols - 1;
            self.cellPtr(self.cursor_col, self.cursor_row).* = ' ';
        }
        self.dirty = true;
    }

    pub fn typeChar(self: *Console, c: u8) void {
        if (c == '\n') {
            self.newline();
            return;
        }
        if (self.cursor_col >= self.cols) {
            self.newline();
        }
        self.cellPtr(self.cursor_col, self.cursor_row).* = c;
        self.cursor_col += 1;
        self.dirty = true;
    }

    pub fn render(self: *const Console, r: *const Renderer, x: i32, y: i32, color: u32) void {
        for (0..self.rows) |row| {
            for (0..self.cols) |col| {
                const c = self.cells[row * self.cols + col];
                if (c == ' ') continue;
                r.drawGlyph(
                    c,
                    x + @as(i32, @intCast(col * font.glyph_width)),
                    y + @as(i32, @intCast(row * font.glyph_height)),
                    color,
                );
            }
        }
        if (self.cursor_visible) {
            const cx = x + @as(i32, @intCast(self.cursor_col * font.glyph_width));
            const cy = y + @as(i32, @intCast(self.cursor_row * font.glyph_height));
            r.drawRect(cx, cy + @as(i32, @intCast(font.glyph_height - 1)), font.glyph_width, 1, 0x00FF00);
        }
    }

    fn cellPtr(self: *Console, col: usize, row: usize) *u8 {
        return &self.cells[row * self.cols + col];
    }

    fn scroll(self: *Console) void {
        for (1..self.rows) |row| {
            @memcpy(self.cells[(row - 1) * self.cols .. row * self.cols], self.cells[row * self.cols .. (row + 1) * self.cols]);
        }
        @memset(self.cells[(self.rows - 1) * self.cols ..], ' ');
    }
};
