const std = @import("std");
const serial = @import("../serial.zig");
const tar_mod = @import("../fs/tar.zig");
const c = @import("cimport.zig").c;

/// Wasm runtime (M7, Phase A): wasm3 WebAssembly interpreter. Programs are Zig
/// binaries compiled to wasm32-freestanding and run against the kernel heap
/// through the shared kernel libc. Isolation is the manifest's managed-runtime
/// boundary: wasm3 traps (OOB, division by zero) surface as a call error and
/// drop the program without touching the desktop.
/// Home-wasm import surface (M7): the thin host API a program may call. The
/// module/function names and signatures are a stable contract (wasm import
/// surface ADR). Zig targets import from the module "env" and name the import
/// after the extern symbol, so the surface uses `debug_write` (no dot — that
/// is reserved for the Lua binding's dotted globals).
const env_module_name = "env";

var environment: ?*c.M3Environment = null;
var initrd: ?[]const u8 = null;
var heap_allocator: std.mem.Allocator = undefined;

/// debug_write(strOffset): write a NUL-terminated string from the program's
/// linear memory to the kernel serial console. Signature "v(i)".
export fn wasm_debug_write(runtime: ?*c.M3Runtime, ctx: [*c]c.M3ImportContext, sp: [*c]u64, mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = runtime;
    _ = ctx;
    const offset: u32 = @truncate(sp[0]);
    const bytes: [*]u8 = @ptrCast(@alignCast(mem));
    const str = std.mem.span(@as([*:0]const u8, @ptrCast(bytes + offset)));
    serial.write(str);
    return null;
}

fn linkImports(module: ?*c.M3Module) !void {
    const res = c.m3_LinkRawFunction(module, env_module_name, "debug_write", "v(i)", &wasm_debug_write);
    if (res != null) return error.LinkFailed;
}

pub fn init(allocator: std.mem.Allocator, initrd_data: ?[]const u8) void {
    heap_allocator = allocator;
    initrd = initrd_data;
    environment = c.m3_NewEnvironment();
}

/// Read a wasm program's bytes from the initrd tar by its flat file name. The
/// slice points into the archive — no copy — and stays valid for the boot.
pub fn loadProgramSource(name: []const u8) ![]const u8 {
    const tar = initrd orelse return error.NoInitrd;
    return tar_mod.find(tar, name);
}

pub const WasmError = error{
    NotReady,
    OutOfMemory,
    ParseFailed,
    LinkFailed,
    LoadFailed,
    NoEntryPoint,
    CallFailed,
};

/// A running wasm instance: its runtime, module, entry function and linear
/// memory. The instance lives for the whole program lifetime and is freed
/// with `free`.
pub const Program = struct {
    runtime: ?*c.M3Runtime,
    module: ?*c.M3Module,
    function: ?*c.M3Function,
    memory: [*]u8,
    memory_size: usize,

    pub fn free(self: *Program) void {
        const rt = self.runtime;
        c.m3_FreeRuntime(rt);
        self.* = undefined;
    }

    /// Call the entry function (trap containment: any wasm3 trap — OOB,
    /// division by zero — surfaces as CallFailed, the program is dropped and
    /// the desktop keeps running).
    pub fn call(self: *const Program) WasmError!void {
        const res = c.m3_CallV(self.function);
        if (res != null) {
            serial.writeLine("wasm: program faulted (trap), dropping");
            return error.CallFailed;
        }
    }
};

pub fn spawn(source: []const u8, name: []const u8) WasmError!Program {
    _ = name;
    const env = environment orelse return error.NotReady;
    const runtime = c.m3_NewRuntime(env, 65536, null) orelse return error.OutOfMemory;
    errdefer c.m3_FreeRuntime(runtime);

    var module: ?*c.M3Module = undefined;
    const parse = c.m3_ParseModule(env, &module, @ptrCast(@constCast(source.ptr)), @intCast(source.len));
    if (parse != null) return error.ParseFailed;
    errdefer c.m3_FreeModule(module);

    try linkImports(module);

    const load = c.m3_LoadModule(runtime, module);
    if (load != null) return error.LoadFailed;

    // Entry point: the kernel's home-wasm convention is an exported `start`
    // function; `_start` is accepted as the generic fallback.
    var func: ?*c.M3Function = undefined;
    var res = c.m3_FindFunction(&func, runtime, "start");
    if (res != null) res = c.m3_FindFunction(&func, runtime, "_start");
    if (res != null) return error.NoEntryPoint;

    var memory_size: u32 = 0;
    const memory = c.m3_GetMemory(runtime, &memory_size, 0);

    return .{
        .runtime = runtime,
        .module = module,
        .function = func,
        .memory = @ptrCast(@alignCast(memory)),
        .memory_size = memory_size,
    };
}
