const std = @import("std");
const pfa_test = @import("mem/pfa_test.zig");
const heap_test = @import("mem/heap_test.zig");
const framebuffer_test = @import("graphics/framebuffer_test.zig");
const renderer_test = @import("graphics/renderer_test.zig");
const font_test = @import("graphics/font_test.zig");
const console_test = @import("graphics/console_test.zig");
const input_test = @import("graphics/input_test.zig");

test {
    std.testing.refAllDecls(@This());
    _ = pfa_test;
    _ = heap_test;
    _ = framebuffer_test;
    _ = renderer_test;
    _ = font_test;
    _ = console_test;
    _ = input_test;
}
