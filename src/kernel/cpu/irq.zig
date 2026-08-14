const builtin = @import("builtin");

/// RFLAGS interrupt-enable flag (IF, bit 9).
const if_bit: u64 = 1 << 9;

/// RAII-style interrupt mask for single-core kernel critical sections
/// (ADR-017, spec/invariants.md Architecture): shared state between tasks is
/// protected by disabling preemption, not by locks. On entry the guard masks
/// interrupts only if they were enabled; on exit it re-enables them only if
/// this guard was the one that masked them. That makes nesting safe — x86
/// `cli`/`sti` are not refcounted, so the restore decision must come from
/// RFLAGS, not a counter — and keeps boot-time code safe: before the first
/// `sti` the guard is a no-op and can never enable interrupts prematurely.
///
/// On the host unit-test target (not freestanding) the guard is a no-op:
/// `cli`/`sti` are privileged and would #GP in userland.
pub fn begin() InterruptGuard {
    if (comptime builtin.os.tag != .freestanding) return .{ .must_sti = false };
    const flags = readRflags();
    if (flags & if_bit != 0) {
        asm volatile ("cli" ::: .{ .memory = true });
        return .{ .must_sti = true };
    }
    return .{ .must_sti = false };
}

pub const InterruptGuard = struct {
    must_sti: bool,

    pub fn end(self: InterruptGuard) void {
        if (!self.must_sti) return;
        if (comptime builtin.os.tag != .freestanding) return;
        asm volatile ("sti" ::: .{ .memory = true });
    }
};

fn readRflags() u64 {
    return asm volatile ("pushfq\n\tpopq %[flags]"
        : [flags] "=r" (-> u64),
    );
}
