const std = @import("std");
const idt = @import("../cpu/idt.zig");
const time = @import("../time.zig");

/// Minimum preemptive round-robin scheduler (ADR-017, audit §3.5, brief Task 7).
///
/// Single-core: the switch points are the APIC timer IRQ (vector 0x20) for
/// preemption and the voluntary `sleepMs` bridge (spec/timer.md §5) for
/// blocking sleeps. The IDT uses interrupt gates, so the timer ISR runs with
/// IF masked — the TCB manipulation in `schedPickNext` is therefore a natural
/// critical section (no lock, no CAS; spec/invariants.md Architecture); the
/// sleep bridge masks interrupts for the same reason. Task 0 is the kernel
/// main context (event loop / runtime tests); `spawnTask` adds up to three
/// native kernel tasks, each resumed through a hand-assembled initial
/// interrupt frame.
///
/// No dynamic allocation: the TCB table and all task stacks are static
/// (`.bss`). The kernel image is not reserved in the PFA bitmap, so task
/// stacks must never come from `allocPages` (brief Task 7.1).
pub const max_tasks = 4;
pub const TaskId = usize;

const task_stack_size = 16384;
var task_stacks: [max_tasks][task_stack_size]u8 align(16) = undefined;

/// Layout of the top of a task stack while suspended in the timer ISR
/// (see isr.s): the return address of the `callq sched_switch` (the
/// restore-sequence label), then the 256-byte XMM save area, then the
/// InterruptFrame. In 64-bit mode the CPU pushes a five-element machine
/// frame on interrupt entry — SS, RSP, RFLAGS, CS, RIP — and `iretq` pops
/// all five, so the fake frame must supply `rsp` and `ss` too. A suspended
/// task and a freshly spawned task must have the same layout here, because
/// resuming either of them is the same `ret`.
const return_slot_bytes = 8;
const xmm_area_bytes = 256;

const TaskState = enum { unused, ready, running, blocked };

const Task = struct {
    state: TaskState = .unused,
    saved_sp: u64 = 0,
    wake_at: u64 = 0,
};

var tasks: [max_tasks]Task = undefined;
var running: TaskId = 0;
var task_count: usize = 0;

const sched_restore = @extern([*]u8, .{ .name = "sched_restore" });

/// Establish the initial kernel context as task 0. Called from kernelMain
/// before interrupts are enabled, so the first timer IRQ already sees a
/// consistent TCB table. This call also anchors the module in the build: its
/// exported symbol `sched_pick_next` is referenced by the asm bridge in
/// `cpu/isr.s` unconditionally, so the module must be linked even when no
/// runtime test spawns tasks.
pub fn init() void {
    for (&tasks) |*t| t.* = .{};
    tasks[0] = .{ .state = .running };
    running = 0;
    task_count = 1;
}

/// Kernel code selector used by the IDT; a fresh task's interrupt frame must
/// iretq into it (matches `idt.zig` `setEntry`).
const kernel_cs: u64 = 0x28;
/// Kernel data (stack) selector: matches the segment the limine protocol set
/// up at boot (the CPU's SS while executing in the ISR).
const kernel_ss: u64 = 0x30;
/// rflags with IF set (bit 9) plus the always-one reserved bit — the fake
/// frame enables interrupts so the timer can preempt the new task.
const kernel_rflags: u64 = 0x202;

/// Pick the next task to run and return its saved stack pointer. Called from
/// the asm bridge `sched_switch` inside the timer ISR; `current_rsp` points
/// at the caller's return-address slot, which is exactly what a suspended
/// task needs so that `movq saved_sp, %rsp; ret` lands on the restore
/// sequence. Round-robin over the tasks in table order.
pub fn schedPickNext(current_rsp: u64) callconv(.c) u64 {
    tasks[running].state = .ready;
    tasks[running].saved_sp = current_rsp;
    return pickNext();
}

/// Voluntary blocking switch for `sleepMs`: the current task is marked
/// `.blocked` with its wake deadline and the next runnable task is picked.
/// Called from the asm bridge `sched_sleep_switch` in normal context (with
/// interrupts masked by that bridge), so the TCB table is still the natural
/// critical section.
pub fn schedSleepPickNext(current_rsp: u64, wake_at: u64) callconv(.c) u64 {
    tasks[running].state = .blocked;
    tasks[running].wake_at = wake_at;
    tasks[running].saved_sp = current_rsp;
    return pickNext();
}

/// Shared round-robin pick. First wakes every blocked task whose deadline
/// has passed (a blocked task is resumed only from here, so the wake check
/// cannot be missed), then picks the next ready task. When nothing is ready —
/// only possible on the voluntary path, because the ISR path always marks the
/// preempted task ready — the current task's state is left untouched and its
/// own saved_sp is returned: `sleepMs` re-checks its deadline and re-enters.
fn pickNext() u64 {
    const now = time.ticks();
    for (tasks[0..task_count]) |*t| {
        if (t.state == .blocked and t.wake_at <= now) t.state = .ready;
    }

    var next = running;
    var found = false;
    var scanned: usize = 0;
    while (scanned < task_count) : (scanned += 1) {
        next = (next + 1) % task_count;
        if (tasks[next].state == .ready) {
            found = true;
            break;
        }
    }
    if (found) {
        tasks[next].state = .running;
        running = next;
        return tasks[next].saved_sp;
    }
    return tasks[running].saved_sp;
}

comptime {
    @export(&schedPickNext, .{ .name = "sched_pick_next" });
    @export(&schedSleepPickNext, .{ .name = "sched_sleep_pick_next" });
}

pub const SpawnError = error{TaskTableFull};

/// Create a new native kernel task with a fake initial interrupt frame on its
/// own static stack. Must be called from normal context (interrupts enabled),
/// never from an ISR: the TCB table is a critical section and is guarded by
/// `cli`/`sti` here.
pub fn spawnTask(entry: *const fn () callconv(.c) noreturn) SpawnError!TaskId {
    asm volatile ("cli" ::: .{ .memory = true });
    defer asm volatile ("sti" ::: .{ .memory = true });

    if (task_count >= max_tasks) return error.TaskTableFull;
    const id = task_count;
    tasks[id] = .{
        .state = .ready,
        .saved_sp = buildFakeFrame(id, entry),
    };
    task_count += 1;
    return id;
}

/// Hand-assemble the top of the new task's stack so that resuming it runs
/// exactly the same code path as resuming a preempted task: the restore
/// sequence of `isr_common` (see the layout comment above).
fn buildFakeFrame(id: TaskId, entry: *const fn () callconv(.c) noreturn) u64 {
    const stack_top = @intFromPtr(&task_stacks[id]) + task_stack_size;
    const saved_sp = stack_top - return_slot_bytes - xmm_area_bytes - @sizeOf(idt.InterruptFrame);

    const sp: [*]u8 = @ptrFromInt(saved_sp);
    const return_slot: *u64 = @ptrCast(@alignCast(sp));
    return_slot.* = @intFromPtr(sched_restore);

    @memset(sp[return_slot_bytes .. return_slot_bytes + xmm_area_bytes], 0);

    const frame: *idt.InterruptFrame = @ptrCast(@alignCast(sp + return_slot_bytes + xmm_area_bytes));
    frame.* = .{
        .rdi = 0,
        .rsi = 0,
        .rcx = 0,
        .rdx = 0,
        .r8 = 0,
        .r9 = 0,
        .r10 = 0,
        .r11 = 0,
        .r12 = 0,
        .r13 = 0,
        .r14 = 0,
        .r15 = 0,
        .rbx = 0,
        .rbp = 0,
        .rax = 0,
        .vector = 0,
        .error_code = 0,
        .rip = @intFromPtr(entry),
        .cs = kernel_cs,
        .rflags = kernel_rflags,
        .rsp = stack_top - return_slot_bytes,
        .ss = kernel_ss,
    };
    return saved_sp;
}

/// Blocking sleep of the current native kernel task (spec/timer.md §5): the
/// task blocks until `ticks() + ms` and the scheduler runs something else.
/// `sched_sleep_switch` (cpu/isr.s) is an asm bridge that saves the task's
/// callee-saved registers and its resume point into a small save area, hands
/// the wake deadline to `schedSleepPickNext` and switches away; resuming later
/// is the register-restore path `sched_sleep_restore`. The loop re-checks the
/// deadline because the fallback self-switch (no other runnable task) resumes
/// immediately without the deadline having passed.
extern fn sched_sleep_switch(wake: u64) void;

pub fn sleepMs(ms: u64) void {
    const wake = time.ticks() + ms;
    while (true) {
        if (time.ticks() >= wake) return;
        sched_sleep_switch(wake);
    }
}
