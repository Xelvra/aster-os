const std = @import("std");
const serial = @import("../serial.zig");
const tar_mod = @import("../fs/tar.zig");
const input_service = @import("../input/service.zig");
const fb = @import("../fb/framebuffer.zig");
const render = @import("../render/renderer.zig");
const c = @import("cimport.zig").c;

/// Wasm runtime (M7): wasm3 WebAssembly interpreter. Programs are Zig binaries
/// compiled to wasm32-freestanding. Isolation is the manifest's managed-runtime
/// boundary: wasm3 traps (OOB, division by zero) surface as a call error and
/// drop the program without touching the desktop.
/// Home-wasm import surface (M7, Phase B): the thin host API a program may call
/// (spec/adr/026). The module/function names and signatures are a stable
/// contract. Zig targets import from the module "env" and name the import after
/// the extern symbol, so the surface uses `debug_write` (no dot — that is
/// reserved for the Lua binding's dotted globals).
const env_module_name = "env";

/// Fixed surface size for Phase B (spec/adr/026): a program's offscreen pixel
/// buffer is 224x160 px, 32bpp 0x00RRGGBB, allocated at spawn. Per-program
/// size is a future, not Phase B.
pub const surface_width = 224;
pub const surface_height = 160;

/// Static program table (spec/adr/026): no allocation for the slots themselves.
/// One slot per live program; a slot is recycled when its program is dropped.
const max_programs = 4;

var environment: ?*c.M3Environment = null;
var initrd: ?[]const u8 = null;
var heap_allocator: std.mem.Allocator = undefined;
var programs: [max_programs]Program = initPrograms();

fn initPrograms() [max_programs]Program {
    var table: [max_programs]Program = undefined;
    for (&table) |*slot| slot.* = .{ .alive = false };
    return table;
}

/// A running wasm instance: its runtime, module, entry functions, linear memory
/// and the program's offscreen surface. Lives for the whole program lifetime
/// and is freed with `free` (trap containment drops the program).
pub const Program = struct {
    alive: bool = false,
    name: [32]u8 = undefined,
    runtime: ?*c.M3Runtime = null,
    module: ?*c.M3Module = null,
    /// Whether wasm3 took ownership of the module (m3_LoadModule success). The
    /// runtime frees an owned module; a module that failed to load — or was
    /// never loaded — must be freed explicitly.
    module_owned: bool = false,
    start_func: ?*c.M3Function = null,
    update_func: ?*c.M3Function = null,
    render_func: ?*c.M3Function = null,
    memory: [*]u8 = undefined,
    memory_size: usize = 0,
    /// Owned 32bpp pixels (0x00RRGGBB), `surface_width * surface_height`.
    surface: []u32 = &.{},
    /// The surface as a renderable framebuffer/renderer (same primitives as the
    /// main framebuffer, so draw_rect/draw_text share font, clipping and pixel
    /// format).
    framebuffer: fb.Framebuffer = undefined,
    renderer: render.Renderer = undefined,
    /// Last placement from api/runtime.surface_render; input_mouse_x/y report
    /// the mouse relative to it, so the program lives in its own coordinate
    /// space and window moves (drag/tiling/ws) are transparent to it.
    placed_x: i32 = 0,
    placed_y: i32 = 0,
    /// Owned copy of the module bytes for a disk-loaded program (spawnOwned);
    /// wasm3 keeps referencing the source buffer for the module's lifetime
    /// (function bodies are parsed lazily), so it must outlive the module and
    /// is freed alongside it. Empty for an initrd-loaded program — the tar
    /// archive backing it lives for the whole kernel lifetime.
    owned_source: []u8 = &.{},
    /// One-slot key latch (spec/adr/026): api/runtime.keyInput sets this from
    /// the focused window's key press (a resolved character, layout/shift
    /// already applied, forwarded by the WM); `input_key()` reads and clears
    /// it, so a program sees each press exactly once.
    pending_key: u8 = 0,

    /// Call a program export under trap containment: any wasm3 trap surfaces as
    /// CallFailed and the caller drops the program (its runtime is invalid
    /// after a trap).
    pub fn invoke(func: ?*c.M3Function) WasmError!void {
        const f = func orelse return;
        const res = c.m3_CallV(f);
        if (res != null) {
            serial.writeLine("wasm: program faulted (trap), dropping");
            return error.CallFailed;
        }
    }

    pub fn free(self: *Program) void {
        const rt = self.runtime;
        c.m3_FreeRuntime(rt);
        // The runtime owns a loaded module; a module that failed to load (or
        // was never loaded) keeps module_owned == false and must be freed
        // explicitly.
        if (self.module != null and !self.module_owned) {
            c.m3_FreeModule(self.module);
        }
        if (self.surface.len > 0) heap_allocator.free(self.surface);
        if (self.owned_source.len > 0) heap_allocator.free(self.owned_source);
        self.* = .{ .alive = false };
    }
};

fn programFromRuntime(runtime: ?*c.M3Runtime) ?*Program {
    const userdata = c.m3_GetUserData(runtime) orelse return null;
    return @ptrCast(@alignCast(userdata));
}

/// Read a NUL-terminated string from the program's linear memory, bounded by
/// the memory size so a hostile offset cannot run past the end of memory.
fn boundedString(bytes: [*]u8, offset: u32, memory_size: usize) []const u8 {
    if (offset >= memory_size) return "";
    const start: usize = offset;
    const max_len = memory_size - start;
    var len: usize = 0;
    while (len < max_len and bytes[start + len] != 0) : (len += 1) {}
    return bytes[start .. start + len];
}

/// First stack slot of an `i()` import: the 32-bit return value (wasm3 reads
/// it as an i32). Writing the bit pattern of a signed value lets a negative
/// surface-local mouse coordinate reach the program correctly.
fn writeReturn(sp: [*c]u64, value: i32) void {
    sp[0] = @as(u32, @bitCast(value));
}

/// debug_write(strOffset): write a NUL-terminated string from the program's
/// linear memory to the kernel serial console. Signature "v(i)".
export fn wasm_debug_write(runtime: ?*c.M3Runtime, ctx: [*c]c.M3ImportContext, sp: [*c]u64, mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = ctx;
    const program = programFromRuntime(runtime) orelse return null;
    const offset: u32 = @truncate(sp[0]);
    const bytes: [*]u8 = @ptrCast(@alignCast(mem));
    const text = boundedString(bytes, offset, program.memory_size);
    serial.write(text);
    return null;
}

/// draw_rect(x, y, w, h, color): fill a rect on the program's surface. Colors
/// are 32bpp 0x00RRGGBB. Signature "v(iiiii)".
export fn wasm_draw_rect(runtime: ?*c.M3Runtime, ctx: [*c]c.M3ImportContext, sp: [*c]u64, mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = ctx;
    _ = mem;
    const program = programFromRuntime(runtime) orelse return null;
    const x: i32 = @bitCast(@as(u32, @truncate(sp[0])));
    const y: i32 = @bitCast(@as(u32, @truncate(sp[1])));
    const w: u32 = @truncate(sp[2]);
    const h: u32 = @truncate(sp[3]);
    const color: u32 = @truncate(sp[4]);
    program.renderer.drawRect(x, y, w, h, color);
    return null;
}

/// draw_text(strOffset, x, y, color): draw a NUL-terminated string from linear
/// memory onto the surface (monospace glyphs, shared font). Signature "v(iiii)".
export fn wasm_draw_text(runtime: ?*c.M3Runtime, ctx: [*c]c.M3ImportContext, sp: [*c]u64, mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = ctx;
    const program = programFromRuntime(runtime) orelse return null;
    const offset: u32 = @truncate(sp[0]);
    const x: i32 = @bitCast(@as(u32, @truncate(sp[1])));
    const y: i32 = @bitCast(@as(u32, @truncate(sp[2])));
    const color: u32 = @truncate(sp[3]);
    const bytes: [*]u8 = @ptrCast(@alignCast(mem));
    const text = boundedString(bytes, offset, program.memory_size);
    program.renderer.drawText(text, x, y, color);
    return null;
}

/// surface_width(): the program's surface width in px. Signature "i()".
export fn wasm_surface_width(runtime: ?*c.M3Runtime, ctx: [*c]c.M3ImportContext, sp: [*c]u64, mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = runtime;
    _ = ctx;
    _ = mem;
    sp[0] = surface_width;
    return null;
}

/// surface_height(): the program's surface height in px. Signature "i()".
export fn wasm_surface_height(runtime: ?*c.M3Runtime, ctx: [*c]c.M3ImportContext, sp: [*c]u64, mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = runtime;
    _ = ctx;
    _ = mem;
    sp[0] = surface_height;
    return null;
}

/// input_mouse_x(): mouse X relative to the surface origin (the last
/// surface_render placement). Signature "i()".
export fn wasm_input_mouse_x(runtime: ?*c.M3Runtime, ctx: [*c]c.M3ImportContext, sp: [*c]u64, mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = ctx;
    _ = mem;
    const program = programFromRuntime(runtime) orelse return null;
    writeReturn(sp, input_service.mouseX() - program.placed_x);
    return null;
}

/// input_mouse_y(): mouse Y relative to the surface origin. Signature "i()".
export fn wasm_input_mouse_y(runtime: ?*c.M3Runtime, ctx: [*c]c.M3ImportContext, sp: [*c]u64, mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = ctx;
    _ = mem;
    const program = programFromRuntime(runtime) orelse return null;
    writeReturn(sp, input_service.mouseY() - program.placed_y);
    return null;
}

/// input_mouse_left(): state of the left mouse button (0/1). Signature "i()".
export fn wasm_input_mouse_left(runtime: ?*c.M3Runtime, ctx: [*c]c.M3ImportContext, sp: [*c]u64, mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = ctx;
    _ = mem;
    _ = runtime;
    sp[0] = if (input_service.mouseLeft()) 1 else 0;
    return null;
}

/// input_key(): the next forwarded key character (0 if none since the last
/// call), read-and-clear. Signature "i()".
export fn wasm_input_key(runtime: ?*c.M3Runtime, ctx: [*c]c.M3ImportContext, sp: [*c]u64, mem: ?*anyopaque) callconv(.c) ?*const anyopaque {
    _ = ctx;
    _ = mem;
    const program = programFromRuntime(runtime) orelse return null;
    sp[0] = program.pending_key;
    program.pending_key = 0;
    return null;
}

const RawHandler = fn (?*c.M3Runtime, [*c]c.M3ImportContext, [*c]u64, ?*anyopaque) callconv(.c) ?*const anyopaque;

fn linkImports(module: ?*c.M3Module) WasmError!void {
    const imports = [_]struct {
        name: [*:0]const u8,
        signature: [*:0]const u8,
        handler: *const RawHandler,
    }{
        .{ .name = "debug_write", .signature = "v(i)", .handler = &wasm_debug_write },
        .{ .name = "draw_rect", .signature = "v(iiiii)", .handler = &wasm_draw_rect },
        .{ .name = "draw_text", .signature = "v(iiii)", .handler = &wasm_draw_text },
        .{ .name = "surface_width", .signature = "i()", .handler = &wasm_surface_width },
        .{ .name = "surface_height", .signature = "i()", .handler = &wasm_surface_height },
        .{ .name = "input_mouse_x", .signature = "i()", .handler = &wasm_input_mouse_x },
        .{ .name = "input_mouse_y", .signature = "i()", .handler = &wasm_input_mouse_y },
        .{ .name = "input_mouse_left", .signature = "i()", .handler = &wasm_input_mouse_left },
        .{ .name = "input_key", .signature = "i()", .handler = &wasm_input_key },
    };
    for (imports) |import| {
        const res = c.m3_LinkRawFunction(module, env_module_name, import.name, import.signature, @ptrCast(import.handler));
        // A program need not use every host function (hello.zig imports only
        // debug_write); wasm3 reports functionLookupFailed when the module
        // simply does not reference this particular one (the wasm3 authors'
        // own idiom for optional imports, e.g. m3_api_libc.c). Any other
        // non-null result — a real signature mismatch or OOM — is a link error.
        if (res != null and res != c.m3Err_functionLookupFailed) return error.LinkFailed;
    }
}

pub fn init(allocator: std.mem.Allocator, initrd_data: ?[]const u8) void {
    heap_allocator = allocator;
    initrd = initrd_data;
    environment = c.m3_NewEnvironment();
}

/// The kernel heap allocator wasm.zig was initialized with, so a caller
/// loading a program's bytes from elsewhere (api/runtime, disk apps under
/// /apps/) can allocate a buffer sized for `spawnOwned`.
pub fn heapAllocator() std.mem.Allocator {
    return heap_allocator;
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

/// Spawn (or reuse) a program by name, sourced from the initrd. `source` must
/// outlive the program (wasm3 keeps referencing it) — true for a tar slice,
/// which lives for the kernel's whole lifetime. See `spawnOwned` for a
/// heap-owned source (disk-loaded apps).
pub fn spawn(source: []const u8, name: []const u8) WasmError!u64 {
    return spawnImpl(source, name, &.{});
}

/// Spawn (or reuse) a program by name from a heap-allocated source buffer the
/// caller transfers ownership of (spec/adr/026: disk apps under /apps/, read
/// into a fresh allocation per spawn attempt). Freed alongside the program,
/// including on every error path below — a fetch that never reaches a live
/// slot must not leak.
pub fn spawnOwned(source: []u8, name: []const u8) WasmError!u64 {
    return spawnImpl(source, name, source);
}

/// Spawn (or reuse) a program by name. A live program with the same name is a
/// singleton: its handle is returned and `start` is not called again (desktop
/// convention "one running instance per app"). Otherwise a free slot is used
/// (no allocation), the surface is allocated, the runtime is created with
/// `userdata = *Program`, and `start` runs under trap containment.
/// The returned handle is the slot index; 0 is a valid handle.
fn spawnImpl(source: []const u8, name: []const u8, owned: []u8) WasmError!u64 {
    if (findByName(name)) |existing| {
        if (owned.len > 0) heap_allocator.free(owned);
        return existing;
    }

    const env = environment orelse {
        if (owned.len > 0) heap_allocator.free(owned);
        return error.NotReady;
    };
    const slot = findFreeSlot() orelse {
        if (owned.len > 0) heap_allocator.free(owned);
        return error.OutOfMemory;
    };
    const program = &programs[slot];

    program.* = .{ .alive = true, .owned_source = owned };
    const name_len = @min(name.len, program.name.len - 1);
    @memcpy(program.name[0..name_len], name[0..name_len]);
    program.name[name_len] = 0;

    const runtime = c.m3_NewRuntime(env, 65536, program) orelse {
        program.* = .{ .alive = false };
        return error.OutOfMemory;
    };
    program.runtime = runtime;

    var module: ?*c.M3Module = undefined;
    if (c.m3_ParseModule(env, &module, @ptrCast(@constCast(source.ptr)), @intCast(source.len)) != null) {
        program.free();
        return error.ParseFailed;
    }
    program.module = module;

    // m3_LoadModule must run before linking: it sets module->runtime, which
    // m3_LinkRawFunction (via AcquireCodePageWithCapacity) dereferences to
    // reach the runtime's code page pool. Linking first leaves that pointer
    // null — undefined behaviour, not a caught error.
    if (c.m3_LoadModule(runtime, module) != null) {
        program.free();
        return error.LoadFailed;
    }
    program.module_owned = true;

    linkImports(module) catch {
        program.free();
        return error.LinkFailed;
    };

    // Entry points: `start` is the kernel convention, `update`/`render` are
    // the per-frame lifecycle (optional — a one-shot program like hello sits
    // idle after start).
    var func: ?*c.M3Function = null;
    if (c.m3_FindFunction(&func, runtime, "start") != null) {
        _ = c.m3_FindFunction(&func, runtime, "_start");
    }
    if (func == null) {
        program.free();
        return error.NoEntryPoint;
    }
    program.start_func = func;
    if (c.m3_FindFunction(&func, runtime, "update") == null) {
        program.update_func = func;
    }
    if (c.m3_FindFunction(&func, runtime, "render") == null) {
        program.render_func = func;
    }

    var memory_size: u32 = 0;
    const memory = c.m3_GetMemory(runtime, &memory_size, 0);
    program.memory = @ptrCast(@alignCast(memory));
    program.memory_size = memory_size;

    const surface = heap_allocator.alloc(u32, surface_width * surface_height) catch {
        program.free();
        return error.OutOfMemory;
    };
    // Zero-filled at spawn: the surface is blitted only after the first render,
    // but a fresh surface must never show garbage if a program's start draws
    // nothing before its first update/render tick.
    @memset(surface, 0);
    program.surface = surface;
    program.framebuffer = fb.Framebuffer{
        .base = @ptrCast(surface.ptr),
        .width = surface_width,
        .height = surface_height,
        .pitch = surface_width * 4,
        .bytes_per_pixel = 4,
        .red_shift = 16,
        .green_shift = 8,
        .blue_shift = 0,
    };
    program.renderer = render.Renderer.init(&program.framebuffer);

    Program.invoke(program.start_func) catch {
        program.free();
        return error.CallFailed;
    };
    return slot;
}

/// Tick every live program's update() and render() under trap containment.
/// Called from the kernel update() phase after lua.tickPrograms; a trapping
/// program is dropped and the rest keep running.
pub fn tickPrograms() void {
    for (&programs) |*program| {
        if (!program.alive) continue;
        Program.invoke(program.update_func) catch {
            program.free();
            continue;
        };
        Program.invoke(program.render_func) catch {
            program.free();
            continue;
        };
    }
}

/// The live program for a spawn handle, or null (unknown handle / free slot).
pub fn byHandle(handle: u64) ?*Program {
    if (handle >= programs.len) return null;
    const p = &programs[@intCast(handle)];
    return if (p.alive) p else null;
}

fn findByName(name: []const u8) ?u64 {
    for (&programs, 0..) |*program, i| {
        if (!program.alive) continue;
        const stored_ptr: [*:0]const u8 = @ptrCast(&program.name);
        const stored = std.mem.span(stored_ptr);
        if (stored.len == name.len and std.mem.eql(u8, stored, name)) return @intCast(i);
    }
    return null;
}

fn findFreeSlot() ?u64 {
    for (&programs, 0..) |*program, i| {
        if (!program.alive) return @intCast(i);
    }
    return null;
}
