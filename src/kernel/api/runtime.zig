const std = @import("std");
const sys = @import("sys.zig");
const lua = @import("../lua/lua.zig");
const wasm = @import("../wasm/wasm.zig");
const file_mod = @import("../fs/file.zig");
// Composition-root exception (spec/invariants.md §3, spec/adr/026): api/runtime
// is the seam a spawned wasm program needs two other api modules through —
// api/graphics (the render target its surface blits into) and api/storage
// (loading a disk app's bytes from /apps/, spec/adr/026) — no other layer
// sees wasm-specific code.
const graphics = @import("graphics.zig");
const storage = @import("storage.zig");
const validate = @import("validate.zig");

pub const RuntimeKind = enum(u8) {
    Lua = 0,
    Wasm = 1,
    Native = 2,
};

pub const SpawnOptions = struct {
    kind: RuntimeKind,
    entry: []const u8,
    args: []const u8 = &.{},
};

pub const Program = struct {
    kind: RuntimeKind,
    handle: u64,
};

pub const RuntimeOp = enum(u64) {
    spawn = 0,
    kill = 1,
    status = 2,
    reload = 3,
    /// Composite a wasm program's surface into the render target (spec/adr/026).
    surface_render = 4,
    /// Forward a resolved key character to a wasm program (spec/adr/026).
    key_input = 5,
};

/// Args for RuntimeOp.surface_render: the program handle and the content origin
/// of the window that owns it.
pub const SurfaceRenderArgs = struct {
    handle: u64,
    x: i32,
    y: i32,
};

/// Args for RuntimeOp.key_input: the program handle and the character (the
/// WM has already resolved layout/shift; 0 is never sent).
pub const KeyInputArgs = struct {
    handle: u64,
    char: u8,
};

/// Composition-root exception (spec/code-style.md §1): module-level handle
/// counter, the first-spawn shell marker and the reload flag, set/read by the
/// event loop and dispatch. Single instances, not per-feature state.
var next_handle: u64 = 1;
var shell_spawned = false;
var reload_requested = false;

pub fn init(allocator: std.mem.Allocator, initrd: ?[]const u8) void {
    lua.init(allocator);
    lua.setInitrd(initrd);
    wasm.init(allocator, initrd);
}

/// Re-initialize the Lua shell state without restarting the system
/// (hot reload, spec/runtime.md §5). Safe only when no Lua frame is on
/// the stack — the event loop is the single caller (performReload).
pub fn reload() void {
    lua.reload();
    lua.runMain("main.lua") catch |err| {
        const serial = @import("../serial.zig");
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "shell: reload failed ({s})", .{@errorName(err)}) catch "shell: reload failed";
        serial.writeLine(line);
    };
}

/// Request a shell reload. Safe from anywhere, including inside a Lua
/// call (e.g. `runtime.reload()` from the session menu): the reload
/// itself is deferred to the event loop, which performs it outside the
/// Lua call frame (never close a lua_State that is currently executing).
pub fn requestReload() void {
    reload_requested = true;
}

pub fn reloadRequested() bool {
    return reload_requested;
}

/// Perform the pending reload and clear the flag. Called by the event
/// loop only (no Lua frame on the stack).
pub fn performReload() void {
    if (!reload_requested) return;
    reload_requested = false;
    reload();
}
/// Read a wasm app's whole bytes from disk `/apps/<name>` into a fresh heap
/// allocation the caller owns (spec/adr/026). Null when no disk is mounted or
/// the file doesn't exist there — not an error, just "fall back to initrd".
fn loadWasmSourceFromDisk(name: []const u8) ?[]u8 {
    const fs = if (storage.mounted) |*m| m else return null;
    var path_buf: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/apps/{s}", .{name}) catch return null;
    const f = file_mod.File.open(fs, path) catch return null;
    const buf = wasm.heapAllocator().alloc(u8, f.fileSize()) catch return null;
    // readFile (not File.read) is the guaranteed-whole-file call: File.read
    // is an offset-incrementing single readAt, fine for buf.len == file size
    // but readFile documents the "whole file in one call" contract directly.
    _ = fs.readFile(f.ino, buf) catch {
        wasm.heapAllocator().free(buf);
        return null;
    };
    return buf;
}

pub fn spawn(opts: SpawnOptions) !Program {
    switch (opts.kind) {
        .Lua => {
            if (!shell_spawned) {
                // The first Lua spawn is the desktop shell bootstrap: it runs
                // in the single shell state (lua.runMain loads the /wm/ shell
                // modules).
                shell_spawned = true;
                const handle = next_handle;
                next_handle = if (next_handle == std.math.maxInt(u64)) 1 else next_handle + 1;
                try lua.runMain(opts.entry);
                return .{ .kind = .Lua, .handle = handle };
            }
            // Every later Lua spawn is a program, isolated in its own lua_State
            // (lua.spawnProgram): a program error or infinite loop is contained
            // to that program and cannot touch the desktop. The program's
            // source is a file in the initrd, looked up by its flat name.
            const source = try lua.loadProgramSource(opts.entry);
            const handle = try lua.spawnProgram(source, opts.entry);
            return .{ .kind = .Lua, .handle = handle };
        },
        .Wasm => {
            // Persistent program (spec/adr/026): the slot handle is the program
            // handle; start runs inside wasm.spawn, update/render are ticked by
            // wasm.tickPrograms each frame. Dedup per name makes a repeated
            // spawn idempotent (F5-safe).
            //
            // Disk apps under /apps/ (spec/adr/026) take priority over the
            // initrd: the launcher discovers apps by scanning /apps/, so a
            // name it offers must resolve to the disk copy, not a stale
            // initrd one. hello.wasm/fault.wasm (wasm3 smoke tests, never
            // launcher entries) only ever exist in the initrd.
            if (loadWasmSourceFromDisk(opts.entry)) |owned| {
                const wasm_handle = try wasm.spawnOwned(owned, opts.entry);
                return .{ .kind = .Wasm, .handle = wasm_handle };
            }
            const source = try wasm.loadProgramSource(opts.entry);
            const wasm_handle = try wasm.spawn(source, opts.entry);
            return .{ .kind = .Wasm, .handle = wasm_handle };
        },
        else => return error.NotSupported,
    }
}

/// Blit a program's surface into the render target at (x, y) and remember the
/// placement, so input_mouse_x/y report the mouse relative to the surface
/// origin. Success for a live wasm program, NotFound for an unknown handle
/// (spec/adr/026); a Lua-program handle is indistinguishable from an unknown
/// one in Phase B, so it reports NotFound too.
pub fn surfaceRender(handle: u64, x: i32, y: i32) u64 {
    const program = wasm.byHandle(handle) orelse return @intFromEnum(sys.KiStatus.NotFound);
    const renderer = graphics.renderer orelse return @intFromEnum(sys.KiStatus.NotSupported);
    program.placed_x = x;
    program.placed_y = y;
    renderer.blit(
        @ptrCast(program.surface.ptr),
        0,
        0,
        x,
        y,
        wasm.surface_width,
        wasm.surface_height,
    );
    return @intFromEnum(sys.KiStatus.Success);
}

/// Forward a resolved key character to a wasm program's one-slot latch
/// (spec/adr/026), read by its `input_key()` import. Success for a live wasm
/// program, NotFound for an unknown handle.
pub fn keyInput(handle: u64, char: u8) u64 {
    const program = wasm.byHandle(handle) orelse return @intFromEnum(sys.KiStatus.NotFound);
    program.pending_key = char;
    return @intFromEnum(sys.KiStatus.Success);
}

pub fn dispatch(args: sys.SyscallArgs) u64 {
    const op = validate.opEnum(RuntimeOp, args.a) orelse return @intFromEnum(sys.KiStatus.NotSupported);
    switch (op) {
        .spawn => {
            const opts = validate.checkPtr(args.b, SpawnOptions) orelse return @intFromEnum(sys.KiStatus.InvalidArgument);
            if (spawn(opts.*)) |program| {
                // Return the handle packed with the status, mirroring the
                // storage KI: `(status << 32) | handle`.
                return (@as(u64, @intFromEnum(sys.KiStatus.Success)) << 32) | program.handle;
            } else |_| {
                return @intFromEnum(sys.KiStatus.NotSupported);
            }
        },
        .kill, .status => return @intFromEnum(sys.KiStatus.NotSupported),
        .reload => {
            // Deferred: the event loop performs the reload outside the
            // Lua call that triggered it (spec/runtime.md §5).
            requestReload();
            return @intFromEnum(sys.KiStatus.Success);
        },
        .surface_render => {
            const surface_args = validate.checkPtr(args.b, SurfaceRenderArgs) orelse return @intFromEnum(sys.KiStatus.InvalidArgument);
            return surfaceRender(surface_args.handle, surface_args.x, surface_args.y);
        },
        .key_input => {
            const key_args = validate.checkPtr(args.b, KeyInputArgs) orelse return @intFromEnum(sys.KiStatus.InvalidArgument);
            return keyInput(key_args.handle, key_args.char);
        },
    }
}
