const std = @import("std");
const idt = @import("../cpu/idt.zig");
const irq = @import("../cpu/irq.zig");
const time = @import("../time.zig");
const serial = @import("../serial.zig");

/// Stack-overflow canary (brief Task 7a, audit §3.5). The task stacks and the
/// kernel stack are plain static arrays with no guard pages (the single
/// address space has no per-task page tables — spec/non-goals.md), so an
/// overflowing task silently writes into the neighbouring stack. Following
/// the heap canary pattern (`mem/heap.zig` block_magic) each stack carries a
/// magic word at its lowest address, checked on every context switch: a
/// clobbered canary halts with a serial diagnostic instead of corrupting a
/// sibling task. This is a software check with detection delay — it fires at
/// the next switch, not at the moment of the write.
const stack_canary_magic: u64 = 0xA57E5CA42C4CA1AE; // "ASTERSTK"

/// Minimum preemptive round-robin scheduler (ADR-017, audit §3.5, brief Task 7).
///
/// Single-core: the switch points are the APIC timer IRQ (vector 0x20) for
/// preemption and the voluntary `sleepMs` bridge (spec/timer.md §5) for
/// blocking sleeps. The IDT uses interrupt gates, so the timer ISR runs with
/// IF masked — the TCB manipulation in `schedPickNext` is therefore a natural
/// critical section (no lock, no CAS; spec/invariants.md Architecture); the
/// sleep bridge masks interrupts for the same reason. Task 0 is the kernel
/// main context (event loop / runtime tests); `spawnTask` adds up to four
/// native kernel tasks, each resumed through a hand-assembled initial
/// interrupt frame.
///
/// No dynamic allocation: the TCB table and all task stacks are static
/// (`.bss`). The kernel image is not reserved in the PFA bitmap, so task
/// stacks must never come from `allocPages` (brief Task 7.1). max_tasks = 10
/// (one main + nine spawnable) so the runtime test suite can hold all its
/// task-spawning tests at once — tasks are never torn down.
pub const max_tasks = 10;
pub const TaskId = usize;

/// Stack for each spawned native task. Sized for the deepest supported call
/// path: freeing a triple-indirect ext2 file walks three 4 KiB block buffers
/// recursively (~12 KiB) plus the block-driver frames, so a file operation
/// must fit even when it runs on a task stack.
const task_stack_size = 32768;
var task_stacks: [max_tasks][task_stack_size]u8 align(16) = undefined;

/// Lowest address of the kernel main stack (task 0), set from main.zig at
/// boot. Canary-checked on switch like every task stack.
var kernel_stack_base: usize = 0;

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
/// runtime test spawns tasks. `kernel_stack_address` is the lowest address of
/// the kernel main stack (task 0), used for its overflow canary.
pub fn init(kernel_stack_address: usize) void {
    kernel_stack_base = kernel_stack_address;
    writeCanary(kernel_stack_base);
    for (&task_stacks) |*stack| {
        writeCanary(@intFromPtr(stack));
    }
    for (&tasks) |*t| t.* = .{};
    tasks[0] = .{ .state = .running };
    running = 0;
    task_count = 1;
}

fn writeCanary(base: usize) void {
    const canary: *u64 = @ptrFromInt(base);
    canary.* = stack_canary_magic;
}

/// Check the overflow canary at the lowest address of a stack; halt with a
/// diagnostic when it is gone — the stack ran to its bottom (overflow risk).
/// Follows the heap `checkBlock()` fault policy (spec/invariants.md §1):
/// halt, do not continue on corrupt state.
fn checkCanary(owner: []const u8, base: usize) void {
    const canary: *const u64 = @ptrFromInt(base);
    if (canary.* == stack_canary_magic) return;
    var buf: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "STACK OVERFLOW: {s} canary clobbered (base {x})", .{ owner, base }) catch "STACK OVERFLOW";
    serial.writeLine(line);
    asm volatile ("cli" ::: .{ .memory = true });
    while (true) asm volatile ("hlt" ::: .{ .memory = true });
}

/// Check the canary of the task that is about to be switched away (its stack
/// was live during the previous quantum). Task 0 lives on the kernel stack.
fn checkCurrentStack() void {
    if (running == 0) {
        checkCanary("kernel", kernel_stack_base);
    } else {
        checkCanary("task", @intFromPtr(&task_stacks[running]));
    }
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
    checkCurrentStack();
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
    checkCurrentStack();
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
/// the RFLAGS-based interrupt guard so a caller that already masked
/// interrupts is not wrongly re-enabled (audit 2026-08-15).
pub fn spawnTask(entry: *const fn () callconv(.c) noreturn) SpawnError!TaskId {
    const guard = irq.begin();
    defer guard.end();

    if (task_count >= max_tasks) return error.TaskTableFull;
    const id = task_count;
    tasks[id] = .{
        .state = .ready,
        .saved_sp = buildFakeFrame(id, entry),
    };
    task_count += 1;
    return id;
}

/// Spawn a task whose body is `anyerror!void`: when it returns an error, the
/// `on_error` handler runs (e.g. records the failure); the task then idles
/// forever (tasks are never torn down). Wraps both into a `noreturn` body, so
/// a task error is contained instead of escaping the task entry.
pub fn spawnTaskChecked(comptime entry: anytype, comptime on_error: anytype) SpawnError!TaskId {
    return spawnTask(struct {
        fn run() callconv(.c) noreturn {
            entry() catch |err| on_error(err);
            while (true) asm volatile ("hlt" ::: .{ .memory = true });
        }
    }.run);
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
    const wake_at = time.ticks() + ms;
    while (true) {
        if (time.ticks() >= wake_at) return;
        sched_sleep_switch(wake_at);
    }
}

/// Id of the currently running native task (blocking sync primitives register
/// themselves as waiters by this id).
pub fn currentId() TaskId {
    return running;
}

/// Wake a blocked task: it becomes runnable and resumes at its sleep save
/// area. No-op when the task is not blocked. Called under an interrupt guard
/// by the sync primitives.
pub fn wake(id: TaskId) void {
    if (id >= task_count) return;
    if (tasks[id].state == .blocked) tasks[id].state = .ready;
}

/// Block the current task until `wake` is called. Uses the sleep bridge with a
/// never-firing deadline, so only an explicit wake resumes it (the scheduler's
/// no-other-runnable self-switch fallback is handled by the caller re-checking
/// its wait condition).
pub fn blockUntilWoken() void {
    sched_sleep_switch(std.math.maxInt(u64));
}
