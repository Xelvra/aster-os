// Trap test program for the wasm runtime (M7): deliberately traps (wasm
// `unreachable`, the same containment path as division by zero / OOB). The
// kernel must catch the wasm3 trap and drop the program without touching the
// desktop.
export fn start() void {
    @trap();
}
