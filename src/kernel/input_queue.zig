const std = @import("std");

pub var global: EventQueue = EventQueue.init();

const queue_capacity = 256;

pub const Event = union(enum) {
    timer_tick: u64,
    key_down: u8,
    key_up: u8,
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
        const write = self.write_index.load(.monotonic);
        const next = (write + 1) % queue_capacity;
        if (next == self.read_index.load(.monotonic)) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        }
        self.buffer[write] = event;
        self.write_index.store(next, .monotonic);
    }

    pub fn pop(self: *EventQueue) ?Event {
        const read = self.read_index.load(.monotonic);
        if (read == self.write_index.load(.monotonic)) return null;
        const event = self.buffer[read];
        self.read_index.store((read + 1) % queue_capacity, .monotonic);
        return event;
    }

    pub fn isEmpty(self: *EventQueue) bool {
        return self.read_index.load(.monotonic) == self.write_index.load(.monotonic);
    }
};
