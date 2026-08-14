const renderer_mod = @import("../render/renderer.zig");
const sys = @import("sys.zig");
const validate = @import("validate.zig");

pub const Renderer = renderer_mod.Renderer;

pub const GraphicsOp = enum(u64) {
    draw_rect = 0,
    /// Reserved: the number is frozen by the KI rule "numbers are never
    /// removed" (spec/kernel-interface.md §4), but blit has no caller today
    /// and is not registered in the Lua bindings. Dispatch returns
    /// NotSupported for it (YAGNI, spec/code-style.md §1).
    blit = 1,
    draw_glyph = 2,
    draw_text = 3,
    fill_screen = 4,
    present = 5,
    invalidate = 6,
    round_rect = 7,
    rect_border = 8,
    gradient_border = 9,
    width = 10,
    height = 11,
};

/// Set by a client (Lua) when the shell needs a redraw. The event loop
/// checks and clears it each iteration; this is how the shell requests a
/// repaint without a key press ("config is code").
pub var invalidate_requested = false;
const RectArgs = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    color: u32,
};

const GlyphArgs = struct {
    codepoint: u32,
    x: i32,
    y: i32,
    color: u32,
};

const TextArgs = struct {
    text: u64,
    len: u64,
    x: i32,
    y: i32,
    color: u32,
};

const RoundRectArgs = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    radius: u32,
    color: u32,
};

const BorderArgs = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    thickness: u32,
    color: u32,
};

const GradientBorderArgs = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    thickness: u32,
    color_a: u32,
    color_b: u32,
};

/// Composition-root exception (spec/code-style.md §1, brief Task 3): a single
/// Renderer set once by main.zig at boot and read by dispatch. Not a growing
/// global — adding a KI op never adds state here.
pub var renderer: ?Renderer = null;

pub fn init(renderer_instance: Renderer) void {
    renderer = renderer_instance;
}

pub fn dispatch(args: sys.SyscallArgs) u64 {
    const r = renderer orelse return @intFromEnum(sys.KiStatus.NotSupported);
    const op: GraphicsOp = @enumFromInt(args.a);
    switch (op) {
        .width => return @intCast(r.fb.width),
        .height => return @intCast(r.fb.height),
        .draw_rect => {
            const rect = validate.checkPtr(args.b, RectArgs) orelse return @intFromEnum(sys.KiStatus.InvalidArgument);
            r.drawRect(rect.x, rect.y, rect.w, rect.h, rect.color);
        },
        // Reserved (see GraphicsOp.blit): no implementation until a caller
        // exists. The KI dispatch must be exhaustive over the enum.
        .blit => return @intFromEnum(sys.KiStatus.NotSupported),
        .draw_glyph => {
            const glyph = validate.checkPtr(args.b, GlyphArgs) orelse return @intFromEnum(sys.KiStatus.InvalidArgument);
            r.drawGlyph(glyph.codepoint, glyph.x, glyph.y, glyph.color);
        },
        .draw_text => {
            const text = validate.checkPtr(args.b, TextArgs) orelse return @intFromEnum(sys.KiStatus.InvalidArgument);
            if (text.text == 0) return @intFromEnum(sys.KiStatus.InvalidArgument);
            const str: [*]const u8 = @ptrFromInt(@as(usize, @intCast(text.text)));
            r.drawText(str[0..@intCast(text.len)], text.x, text.y, text.color);
        },
        .fill_screen => {
            r.fillScreen(@intCast(args.b));
        },
        .present => {},
        .invalidate => {
            invalidate_requested = true;
        },
        .round_rect => {
            const rr_args = validate.checkPtr(args.b, RoundRectArgs) orelse return @intFromEnum(sys.KiStatus.InvalidArgument);
            r.roundRect(rr_args.x, rr_args.y, rr_args.w, rr_args.h, rr_args.radius, rr_args.color);
        },
        .rect_border => {
            const b_args = validate.checkPtr(args.b, BorderArgs) orelse return @intFromEnum(sys.KiStatus.InvalidArgument);
            r.rectBorder(b_args.x, b_args.y, b_args.w, b_args.h, b_args.thickness, b_args.color);
        },
        .gradient_border => {
            const gb_args = validate.checkPtr(args.b, GradientBorderArgs) orelse return @intFromEnum(sys.KiStatus.InvalidArgument);
            r.gradientBorder(gb_args.x, gb_args.y, gb_args.w, gb_args.h, gb_args.thickness, gb_args.color_a, gb_args.color_b);
        },
    }
    return @intFromEnum(sys.KiStatus.Success);
}
