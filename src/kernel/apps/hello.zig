// Hello test program for the wasm runtime (M7). Exports `start`, the
// home-wasm entry convention, and writes a string through the debug_write
// import — the first end-to-end proof that a wasm program runs in the kernel
// with working imports. `extern fn` becomes a wasm import (module "env").
extern fn debug_write(ptr: [*:0]const u8) void;

export fn start() void {
    debug_write("hello from wasm\n");
}
