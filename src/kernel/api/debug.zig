const sys = @import("sys.zig");
const serial = @import("../serial.zig");
const validate = @import("validate.zig");

pub const DebugOp = enum(u64) {
    write = 0,
    status = 1,
};

pub fn dispatch(args: sys.SyscallArgs) u64 {
    const op = validate.opEnum(DebugOp, args.a) orelse return @intFromEnum(sys.KiStatus.NotSupported);
    return switch (op) {
        .write => {
            const checked = validate.checkPtr(args.b, u8) orelse return @intFromEnum(sys.KiStatus.InvalidArgument);
            const ptr: [*]const u8 = @ptrCast(checked);
            const len: usize = @intCast(args.c);
            for (0..len) |i| {
                serial.writeChar(ptr[i]);
            }
            return @intFromEnum(sys.KiStatus.Success);
        },
        .status => 1,
    };
}
