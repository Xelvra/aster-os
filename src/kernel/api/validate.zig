const std = @import("std");

/// Minimal sanity check for pointers passed across the KI boundary
/// (spec/kernel-interface.md §Argument contract, brief Task 5). Today the only
/// caller is the trusted Lua binding, so the check is deliberately cheap:
/// non-null and aligned per the target type. Full "does this address belong
/// to the caller" requires per-task memory-region tracking, which the single
/// address space does not have (spec/non-goals.md) — adding it now would be
/// premature. A failed check yields null and the caller returns
/// `KiStatus.InvalidArgument` instead of dereferencing garbage.
///
/// No allocation, no locks: usable from the render/update hot path
/// (Performance invariants).
pub fn checkPtr(addr: u64, comptime T: type) ?*const T {
    if (addr == 0) return null;
    if (addr % @alignOf(T) != 0) return null;
    return @ptrFromInt(@as(usize, @intCast(addr)));
}

/// Mutable variant of `checkPtr` for output buffers written by the kernel.
pub fn checkPtrMut(addr: u64, comptime T: type) ?*T {
    if (addr == 0) return null;
    if (addr % @alignOf(T) != 0) return null;
    return @ptrFromInt(@as(usize, @intCast(addr)));
}

/// Convert a raw KI op integer to its enum, returning null when the value is
/// not a declared tag. The KI dispatchers use this instead of `@enumFromInt`,
/// which panics the kernel on an out-of-range value (2026-08-15-self-audit); a
/// garbage op then maps to `NotSupported` instead of a halt.
pub fn opEnum(comptime T: type, value: u64) ?T {
    inline for (@typeInfo(T).@"enum".fields) |f| {
        if (value == f.value) return @enumFromInt(value);
    }
    return null;
}
