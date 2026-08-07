const std = @import("std");
const pfa_test = @import("mem/pfa_test.zig");
const heap_test = @import("mem/heap_test.zig");
const framebuffer_test = @import("graphics/framebuffer_test.zig");
const renderer_test = @import("graphics/renderer_test.zig");
const font_test = @import("graphics/font_test.zig");
const layout_test = @import("input/layout_test.zig");
const mouse_test = @import("input/mouse_test.zig");

test {
    std.testing.refAllDecls(@This());
    _ = pfa_test;
    _ = heap_test;
    _ = framebuffer_test;
    _ = renderer_test;
    _ = font_test;
    _ = layout_test;
    _ = mouse_test;
}
