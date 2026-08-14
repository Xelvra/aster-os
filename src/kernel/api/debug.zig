const sys = @import("sys.zig");
const serial = @import("../serial.zig");

pub const DebugOp = enum(u64) {
    write = 0,
    status = 1,
};

pub fn dispatch(args: sys.SyscallArgs) u64 {
    const op: DebugOp = @enumFromInt(args.a);
    return switch (op) {
        .write => {
            if (args.b == 0) return @intFromEnum(sys.KiStatus.InvalidArgument);
            const ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(args.b)));
            const len: usize = @intCast(args.c);
            for (0..len) |i| {
                serial.writeChar(ptr[i]);
            }
            return @intFromEnum(sys.KiStatus.Success);
        },
        .status => 1,
    };
}
