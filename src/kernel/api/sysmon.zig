const sys = @import("sys.zig");
const mem = @import("../mem/mem.zig");
/// System metrics for the shell (RAM, CPU, ...). The shell reads them via
/// bindings; the kernel never pulls data from Lua in the other direction.
pub const SysmonOp = enum(u64) {
    ram_total_mb = 0,
    ram_free_mb = 1,
};

/// Composition-root exception (spec/code-style.md §1): the Memory instance set
/// once by main.zig at boot and read by dispatch. Not per-feature state.
var memory: ?*mem.Memory = null;

pub fn init(memory_instance: *mem.Memory) void {
    memory = memory_instance;
}

pub fn dispatch(args: sys.SyscallArgs) u64 {
    const op: SysmonOp = @enumFromInt(args.a);
    return switch (op) {
        .ram_total_mb => ramTotalMb(),
        .ram_free_mb => ramFreeMb(),
    };
}

fn ramTotalMb() u64 {
    const m = memory orelse return 0;
    return m.stats().total_bytes / (1024 * 1024);
}

fn ramFreeMb() u64 {
    const m = memory orelse return 0;
    return m.stats().free_bytes / (1024 * 1024);
}
