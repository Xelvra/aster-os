const std = @import("std");
const input = @import("input.zig");

pub var global: EventQueue = EventQueue.init();
pub var mouse: EventQueue = EventQueue.init();

const queue_capacity = 256;

pub const Event = union(enum) {
    timer_tick: u64,
    key: input.KeyEvent,
    mouse: input.MouseEvent,
};

pub const EventQueue = struct {
    buffer: [queue_capacity]Event,
    read_index: std.atomic.Value(usize),
    write_index: std.atomic.Value(usize),
    dropped: std.atomic.Value(usize),

    pub fn init() EventQueue {
        return .{
            .buffer = undefined,
            .read_index = std.atomic.Value(usize).init(0),
            .write_index = std.atomic.Value(usize).init(0),
            .dropped = std.atomic.Value(usize).init(0),
        };
    }

    pub fn push(self: *EventQueue, event: Event) void {
        // SPSC: the producer may only overwrite a slot after the consumer has
        // read it, so read_index is loaded with acquire; the buffer write must
        // be visible before the slot is published, so write_index is stored
        // with release (audit 2026-08-15 — monotonic ordering is masked by
        // x86 TSO but wrong on weaker memory models).
        const write = self.write_index.load(.monotonic);
        const next = (write + 1) % queue_capacity;
        if (next == self.read_index.load(.acquire)) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        }
        self.buffer[write] = event;
        self.write_index.store(next, .release);
    }

    pub fn pop(self: *EventQueue) ?Event {
        // SPSC: the consumer may only read a slot after the producer has
        // published it (acquire on write_index), and must publish its read
        // before the producer can overwrite the slot (release on read_index).
        const read = self.read_index.load(.monotonic);
        if (read == self.write_index.load(.acquire)) return null;
        const event = self.buffer[read];
        self.read_index.store((read + 1) % queue_capacity, .release);
        return event;
    }

    pub fn peek(self: *EventQueue) ?Event {
        const read = self.read_index.load(.monotonic);
        if (read == self.write_index.load(.acquire)) return null;
        return self.buffer[read];
    }

    pub fn isEmpty(self: *EventQueue) bool {
        return self.read_index.load(.monotonic) == self.write_index.load(.acquire);
    }
};
