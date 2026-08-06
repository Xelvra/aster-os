const std = @import("std");
const pfa_test = @import("mem/pfa_test.zig");
const heap_test = @import("mem/heap_test.zig");

test {
    std.testing.refAllDecls(@This());
    _ = pfa_test;
    _ = heap_test;
}
