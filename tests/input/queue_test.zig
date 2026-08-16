const std = @import("std");
const queue = @import("kernel").queue;

test "SPSC push and pop preserve order" {
    var q = queue.EventQueue.init();
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        q.push(.{ .key = .{ .code = @enumFromInt(@as(u8, @intCast(i))), .pressed = true } });
    }
    try std.testing.expect(!q.isEmpty());
    i = 0;
    while (i < 10) : (i += 1) {
        const ev = q.pop().?;
        const key = ev.key;
        try std.testing.expectEqual(@as(usize, i), @intFromEnum(key.code));
        try std.testing.expect(key.pressed);
    }
    try std.testing.expect(q.isEmpty());
    try std.testing.expect(q.pop() == null);
}

test "SPSC wrap-around reuses slots" {
    var q = queue.EventQueue.init();
    // Push past one lap so write_index wraps and slots are reused correctly.
    // The drop policy keeps the OLD events and drops the NEW ones while full,
    // so the surviving events are the first capacity-1 in order.
    var i: usize = 0;
    while (i < queue.queue_capacity + 50) : (i += 1) q.push(.{ .timer_tick = i });
    var popped: usize = 0;
    while (q.pop()) |ev| {
        try std.testing.expectEqual(@as(usize, ev.timer_tick), popped);
        popped += 1;
    }
    try std.testing.expectEqual(@as(usize, queue.queue_capacity - 1), popped);
    try std.testing.expectEqual(@as(usize, 51), q.dropped.load(.monotonic));
}

test "SPSC full queue drops and counts" {
    var q = queue.EventQueue.init();
    var i: usize = 0;
    while (i < queue.queue_capacity) : (i += 1) q.push(.{ .timer_tick = i });
    // The queue stores capacity-1 events; the rest are dropped and counted.
    try std.testing.expectEqual(@as(usize, 1), q.dropped.load(.monotonic));
    var popped: usize = 0;
    while (q.pop()) |_| popped += 1;
    try std.testing.expectEqual(@as(usize, queue.queue_capacity - 1), popped);
}

test "SPSC peek leaves the event queued" {
    var q = queue.EventQueue.init();
    q.push(.{ .timer_tick = 7 });
    const peeked = q.peek().?;
    try std.testing.expectEqual(@as(u64, 7), peeked.timer_tick);
    try std.testing.expect(!q.isEmpty());
    const popped = q.pop().?;
    try std.testing.expectEqual(@as(u64, 7), popped.timer_tick);
    try std.testing.expect(q.isEmpty());
}
