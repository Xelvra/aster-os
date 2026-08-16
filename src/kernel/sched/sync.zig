const std = @import("std");
const irq = @import("../cpu/irq.zig");
const task = @import("task.zig");

/// Blocking synchronization primitives (ADR-017). The scheduler is
/// single-core with interrupt-gate preemption, so a blocking primitive is just
/// a waiters list guarded by the RFLAGS-based interrupt mask — no lock, no
/// CAS (spec/invariants.md Architecture).
///
/// Only spawned native kernel tasks may wait on a semaphore: blocking task 0
/// (the kernel main context / event loop / desktop) would freeze the shell.
pub const Semaphore = struct {
    count: u32 = 0,
    waiters: [task.max_tasks - 1]task.TaskId = undefined,
    waiter_count: u32 = 0,

    pub fn init(count: u32) Semaphore {
        return .{ .count = count };
    }

    /// Decrement `count` or block the current task until a signal wakes it.
    /// Registration and the blocking switch run under one interrupt guard, so
    /// a signal cannot interleave between them and get lost.
    pub fn wait(self: *Semaphore) void {
        while (true) {
            const guard = irq.begin();
            defer guard.end();
            if (self.count > 0) {
                self.count -= 1;
                return;
            }
            const id = task.currentId();
            self.unregister(id); // drop a stale self-switch registration
            self.waiters[self.waiter_count] = id;
            self.waiter_count += 1;
            task.blockUntilWoken();
            // resumed: re-check the count (the slot may have been taken by a
            // task that arrived between the signal and this task's resume)
        }
    }

    /// Increment `count`; if a task is waiting, hand the slot to the oldest
    /// waiter instead (FIFO) and wake it.
    pub fn signal(self: *Semaphore) void {
        const guard = irq.begin();
        defer guard.end();
        self.count += 1;
        if (self.waiter_count > 0) {
            const w = self.waiters[0];
            self.unregister(w);
            task.wake(w);
        }
    }

    fn unregister(self: *Semaphore, id: task.TaskId) void {
        for (self.waiters[0..self.waiter_count], 0..) |w, i| {
            if (w == id) {
                for (i..self.waiter_count - 1) |j| self.waiters[j] = self.waiters[j + 1];
                self.waiter_count -= 1;
                return;
            }
        }
    }
};

/// Ownership-based binary lock: only the task that locked the mutex may unlock
/// it; unlock hands ownership to the oldest waiter (FIFO) and wakes it, so the
/// lock is never released while a waiter holds the intent to lock. Locking a
/// mutex the current task already owns is a programming bug and deadlocks (the
/// task blocks forever) instead of silently allowing a nested critical section
/// without a recursion counter.
pub const Mutex = struct {
    locked: bool = false,
    owner: task.TaskId = 0,
    waiters: [task.max_tasks - 1]Waiter = undefined,
    waiter_count: u32 = 0,

    const Waiter = struct {
        id: task.TaskId,
        /// Handed ownership by unlock and woken; the slot stays occupied until
        /// the task resumes and consumes the grant, so a third party cannot
        /// steal the lock in between (FIFO).
        granted: bool = false,
    };

    pub fn init() Mutex {
        return .{};
    }

    pub fn lock(self: *Mutex) void {
        while (true) {
            const guard = irq.begin();
            defer guard.end();
            // unlock handed this task ownership (FIFO): consume the grant and
            // acquire. A current owner that calls lock() again is never a
            // waiter, so it deadlocks instead of nesting.
            if (self.grantedTo(task.currentId())) {
                self.unregister(task.currentId());
                self.locked = true;
                self.owner = task.currentId();
                return;
            }
            if (!self.locked) {
                self.locked = true;
                self.owner = task.currentId();
                return;
            }
            const id = task.currentId();
            self.unregister(id);
            self.waiters[self.waiter_count] = .{ .id = id };
            self.waiter_count += 1;
            task.blockUntilWoken();
            // resumed: only an unlock that granted this task ownership wakes
            // it; the granted flag is consumed on the next pass
        }
    }

    pub fn unlock(self: *Mutex) void {
        const guard = irq.begin();
        defer guard.end();
        if (self.waiter_count > 0) {
            self.waiters[0].granted = true;
            task.wake(self.waiters[0].id);
            return;
        }
        self.locked = false;
        self.owner = 0;
    }

    fn grantedTo(self: *Mutex, id: task.TaskId) bool {
        for (self.waiters[0..self.waiter_count]) |w| {
            if (w.id == id and w.granted) return true;
        }
        return false;
    }

    fn unregister(self: *Mutex, id: task.TaskId) void {
        for (self.waiters[0..self.waiter_count], 0..) |w, i| {
            if (w.id == id) {
                for (i..self.waiter_count - 1) |j| self.waiters[j] = self.waiters[j + 1];
                self.waiter_count -= 1;
                return;
            }
        }
    }
};

pub const EventMode = enum { any, all };

/// Event group (ADT-017): a set of event flags tasks wait on (any/all). `set`
/// raises flags and wakes every waiter whose condition is now met; `clear`
/// lowers flags. Flags are not consumed on a wait (an event stays set until
/// explicitly cleared), so a wake re-checks the condition and returns.
pub const EventGroup = struct {
    flags: u32 = 0,
    waiters: [task.max_tasks - 1]Waiter = undefined,
    waiter_count: u32 = 0,

    const Waiter = struct {
        id: task.TaskId,
        wanted: u32,
        mode: EventMode,
    };

    pub fn init(initial: u32) EventGroup {
        return .{ .flags = initial };
    }

    pub fn set(self: *EventGroup, bits: u32) void {
        const guard = irq.begin();
        defer guard.end();
        self.flags |= bits;
        var i: usize = 0;
        while (i < self.waiter_count) {
            const w = self.waiters[i];
            const met = if (w.mode == .any) (self.flags & w.wanted) != 0 else (self.flags & w.wanted) == w.wanted;
            if (met) {
                for (i..self.waiter_count - 1) |j| self.waiters[j] = self.waiters[j + 1];
                self.waiter_count -= 1;
                task.wake(w.id);
            } else {
                i += 1;
            }
        }
    }

    pub fn wait(self: *EventGroup, wanted: u32, mode: EventMode) void {
        while (true) {
            const guard = irq.begin();
            defer guard.end();
            const met = if (mode == .any) (self.flags & wanted) != 0 else (self.flags & wanted) == wanted;
            if (met) return;
            self.unregister(task.currentId());
            self.waiters[self.waiter_count] = .{ .id = task.currentId(), .wanted = wanted, .mode = mode };
            self.waiter_count += 1;
            task.blockUntilWoken();
        }
    }

    pub fn clear(self: *EventGroup, bits: u32) void {
        const guard = irq.begin();
        defer guard.end();
        self.flags &= ~bits;
    }

    fn unregister(self: *EventGroup, id: task.TaskId) void {
        for (self.waiters[0..self.waiter_count], 0..) |w, i| {
            if (w.id == id) {
                for (i..self.waiter_count - 1) |j| self.waiters[j] = self.waiters[j + 1];
                self.waiter_count -= 1;
                return;
            }
        }
    }
};

/// Blocking byte FIFO with message boundaries: `put` blocks until the whole
/// message fits, `get` blocks until `out.len` bytes are available, and each
/// put/get hands the slot to a waiter (FIFO) so capacity is never wasted.
/// The backing buffer is static (the scheduler allocates nothing); a message
/// larger than the buffer would deadlock, so callers must fit.
pub const MessageQueue = struct {
    buffer: []u8,
    head: usize = 0,
    tail: usize = 0,
    size: usize = 0,
    get_waiters: [task.max_tasks - 1]task.TaskId = undefined,
    get_waiter_count: u32 = 0,
    put_waiters: [task.max_tasks - 1]task.TaskId = undefined,
    put_waiter_count: u32 = 0,

    pub fn init(buffer: []u8) MessageQueue {
        return .{ .buffer = buffer };
    }

    pub fn put(self: *MessageQueue, data: []const u8) void {
        while (true) {
            const guard = irq.begin();
            defer guard.end();
            if (self.size + data.len <= self.buffer.len) {
                for (data) |b| {
                    self.buffer[self.tail] = b;
                    self.tail = (self.tail + 1) % self.buffer.len;
                }
                self.size += data.len;
                if (self.get_waiter_count > 0) {
                    const w = self.get_waiters[0];
                    self.unregisterGet(w);
                    task.wake(w);
                }
                return;
            }
            self.unregisterPut(task.currentId());
            self.put_waiters[self.put_waiter_count] = task.currentId();
            self.put_waiter_count += 1;
            task.blockUntilWoken();
        }
    }

    /// Read exactly `out.len` bytes (blocks until that many are available).
    pub fn get(self: *MessageQueue, out: []u8) void {
        while (true) {
            const guard = irq.begin();
            defer guard.end();
            if (self.size >= out.len) {
                for (0..out.len) |i| {
                    out[i] = self.buffer[self.head];
                    self.head = (self.head + 1) % self.buffer.len;
                }
                self.size -= out.len;
                if (self.put_waiter_count > 0) {
                    const w = self.put_waiters[0];
                    self.unregisterPut(w);
                    task.wake(w);
                }
                return;
            }
            self.unregisterGet(task.currentId());
            self.get_waiters[self.get_waiter_count] = task.currentId();
            self.get_waiter_count += 1;
            task.blockUntilWoken();
        }
    }

    fn unregisterGet(self: *MessageQueue, id: task.TaskId) void {
        for (self.get_waiters[0..self.get_waiter_count], 0..) |w, i| {
            if (w == id) {
                for (i..self.get_waiter_count - 1) |j| self.get_waiters[j] = self.get_waiters[j + 1];
                self.get_waiter_count -= 1;
                return;
            }
        }
    }

    fn unregisterPut(self: *MessageQueue, id: task.TaskId) void {
        for (self.put_waiters[0..self.put_waiter_count], 0..) |w, i| {
            if (w == id) {
                for (i..self.put_waiter_count - 1) |j| self.put_waiters[j] = self.put_waiters[j + 1];
                self.put_waiter_count -= 1;
                return;
            }
        }
    }
};
