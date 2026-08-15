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
