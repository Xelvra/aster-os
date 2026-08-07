# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Project initialization with Zig 0.16.0 pinned in `.zig-version` (ADR-013).
- Full architecture specification in `spec/`:
  - Architecture overview, manifest, non-goals, coding style, invariants.
  - Kernel Interface (KI) with frozen operation numbers (ADR-003, ADR-004).
  - Subsystem specs: graphics, input, timer, memory, runtime.
  - Milestone roadmap M0–M8 with quality metrics (ADR-015).
  - Verification pipeline and bootable-commit rule (ADR-016).
  - Debugging Survival Guide.
- Architecture Decision Records ADR-001..ADR-020:
  - Evolutionary SASOS, single address space Ring 0, stable interfaces.
  - Renderer layer, generic runtime API, Lua 5.4 vendored, event loop.
  - Minimal rendering primitives, no filesystem yet, wasm3 later, Limine.
  - Zig version pinning, deterministic build, measure every milestone.
  - Bootable commit, concurrency model M7, Ring 3 KI transport.
  - Bootloader gate, future extensibility (new KI modules).

### Milestone M0 — Boot

- `build.zig`: `zig build` produces a bootable ISO, `zig build run` boots it in QEMU,
  `zig build iso` assembles the Limine ISO, `zig build test` runs host tests.
- Kernel boots from Limine (long mode, serial, GOP framebuffer), prints `ASTER BOOT OK`.
- Boot handoff translated to kernel-owned `BootInfo` (ADR-019).
- Vendored toolchain: Limine 12.5.2 (binaries + protocol header + host tool),
  Lua 5.4.8 source.
- `tools/qemu-smoke.sh` (serial marker + timeout, fast FIFO exit) and
  `tools/bench.sh` (measurement of boot time and image size).
- Deterministic build verified: same commit + same Zig = identical kernel hash
  (ADR-014). Kernel image 12.0 KB (target < 64 KB).

### Project setup

- MIT license (LICENSE).
- English README for public repo (early deviation from the M4+ language plan, documented
  in `spec/README.md`).
- `spec/troubleshooting.md`: known pitfalls and lessons (Zig 0.16 API, Limine protocol,
  determinism, tooling); mandatory DoD entry in `spec/verification.md`.
- `tools/verify-reproducible.sh`: deterministic build check (ADR-014), mandatory in DoD.

### Milestone M1 — Memory

- Limine memory map parsing into `BootInfo` (usable/reserved regions, RAM filter for MMIO).
- Bitmap Page Frame Allocator (`src/kernel/mem/pfa.zig`): 4 KiB pages, 1 bit per page,
  deterministic first-free allocation, zeroing on request, OOM as error (never panic).
- First-fit heap allocator (`src/kernel/mem/heap.zig`): boundary tags, coalescing,
  dynamic growth from PFA, implements `std.mem.Allocator`.
- Host unit tests for PFA and heap: alloc/free, reuse, fragmentation, OOM, coalescing,
  realloc (16 tests).
- Boot prints RAM layout (usable bytes, free pages) and heap alloc self-test.
- Framebuffer cache attribute verified from PTE + PAT MSR (`cache_attr.zig`):
  Limine maps the framebuffer as **WC** (no M3 frame latency risk).
- Kernel image 17.4 KB (target < 80 KB).

### Architecture note — WASI as a future compatibility layer

- Clarified Wasm has two roles: native Aster bindings (M7) and a future **WASI layer**
  (M9+) for third-party Wasm applications. WASI lives in the runtime (over wasm3), not
  the kernel — it maps WASI syscalls to KI calls, keeping the "no POSIX in kernel"
  non-goal intact (`runtime.md` §7.1, `non-goals.md`, ADR-020).

### Milestone M2 — CPU

- GDT/IDT setup (`src/kernel/cpu/idt.zig`, `isr.s`): 256 uniform ISR stubs (9 B each via
  `.byte 0x6a`), exception/fault policy, `lidt` via `[10]u8` descriptor buffer.
- PIC 8259 remap to vectors 0x20–0x2F (legacy fallback; active ISA IRQs run over IOAPIC).
- Local APIC timer (`src/kernel/cpu/apic.zig`): 1 kHz periodic tick, LAPIC EOI, MMIO
  mapping via PFA-backed `page_map`. SVR initialized explicitly (APIC enable + spurious
  vector 0xFF); spurious interrupt handled as silent no-op without EOI (IDT vector 0xFF).
- IOAPIC: maps 0xFEC00000 and programs redirection entry for IRQ1 (keyboard) to vector
  0x21 — required for ISA IRQ delivery while the APIC is enabled.
- **Input subsystem** (`src/kernel/input.zig`): hardware-neutral `KeyCode` enum +
  `KeyEvent` (code + pressed). Driver/PS/2 is only a producer; KI and applications never
  see scancodes. USB HID can later map usage → same `KeyCode` without touching KI.
- PS/2 keyboard (`src/kernel/drivers/ps2.zig`): i8042 config (IRQ1 enable + translation),
  enable scanning, scancode set-1 → `KeyCode` map, push `KeyEvent` into `input_queue`.
- Event loop prints tick counter and key events; verified in QEMU via `sendkey`
  (`key a down/up`, `key enter down/up`).
- **Fault policy + freestanding backtrace** (`src/kernel/cpu/idt.zig`): `ASTER FAULT`
  dump (vec, err, rip, cr2, rbp) + frame-pointer backtrace; no `std.fmt` in fault
  context (recursive fault, see troubleshooting C12).
- **Dispatch layer** (`src/kernel/api/sys.zig`): KI enumeration (`Syscall`), `KiStatus`,
  `Debug.write` via pointer args; self-test at boot.
- **Runtime tests in QEMU** (`src/kernel/runtime_test.zig`, `tools/qemu-test.sh`,
  `zig build runtime-test -Druntime-tests=true`): in-kernel tests exit QEMU via
  `isa-debug-exit` (pass = write 0x31 → exit 99, fail = 0x30 → exit 97); first test:
  APIC timer ticks through the event queue.
- Removed `link_gc_sections = false`: it bloated the kernel ~7× (196 KB → 28.8 KB) by
  disabling DCE over `std`; ISR stubs survive because `idt.zig` references them via
  `@extern` (troubleshooting C6).
- `spec/troubleshooting.md`: new section 6 with IDT/APIC/IOAPIC/PS/2 lessons (C1–C13);
  `spec/input.md` updated with driver/subsystem/KI layering.
- Kernel image 28.8 KB (target < 96 KB).

### Milestone M3 — Graphics

- **Framebuffer** (`src/kernel/fb/framebuffer.zig`): Limine GOP framebuffer wrapped in a
  `Framebuffer` struct (base, width/height, pitch, bpp, color shifts). `address` from
  Limine is already in the higher-half — written directly, no hhdm offset added
  (verified empirically; `graphics.md` §4 updated).
- **Renderer** (`src/kernel/render/renderer.zig`): `drawRect`, `blit`, `fillScreen`,
  `drawGlyph`, `drawText` with mandatory clipping. No heap allocation on the draw path.
- **Embedded bitmap font** (`src/kernel/render/font_data.zig`): VGA 8×16 console font
  (public domain), generated once into Zig source, glyphs 0x20–0x7E with `?` fallback.
- **Graphics API** (`src/kernel/api/graphics.zig`): `GraphicsOp` sub-op numbers
  0–5 (`draw_rect`, `blit`, `draw_glyph`, `draw_text`, `fill_screen`, `present`)
  wired into `sys.dispatch`; composite args passed by pointer.
- **Event loop** `poll() → update() → render()`: renders only when the console is dirty
  (event-driven, not spin-rendering); `hlt` between iterations.
- **Keyboard → text**: `KeyCode` → ASCII codepoint with shift (`input.keyToCodepoint`),
  console line buffer with wrap/scroll/backspace, cursor; typing visible in QEMU
  (verified via `sendkey` + screendump: `>hi`, uppercase `A`).
- **ISR fix**: `isr_common` now also saves/restores `%rax` (and `InterruptFrame` gained
  `rax`) — the timer IRQ corrupted a live register during render, causing a #GP
  (troubleshooting C14).
- Host tests for framebuffer (fill/clip/blit), renderer (drawGlyph/drawText), font,
  console, and input mapping; runtime test for framebuffer writes in QEMU.
- Kernel image 33.8 KB (target < 128 KB).

### Milestone M4 — Lua

- **Lua 5.4.8 runtime** embedded in the kernel: 27 core `.c` files compiled into the
  kernel module (`build.zig`), no system libc dependency for the target.
- **Freestanding libc shim** for Lua (`libs/lua-5.4/include/` headers +
  `src/kernel/lua/libc.zig`): string/ctype/`snprintf`/`strtod`/`pow`/`frexp`/`ldexp`/
  `acos`/`asin`/`atan2`, `setjmp`/`longjmp` in assembler (`setjmp.s`), deterministic
  `time`/`clock`, and file I/O stubs (for the never-used `luaL_loadfilex`).
- **Runtime module** (`src/kernel/api/runtime.zig`): `RuntimeKind` enum, `spawn`,
  `reload` (hot reload), wired into `sys.dispatch` as the `Runtime` syscall.
- **Lua wrapper** (`src/kernel/lua/lua.zig`): `lua_State` on the kernel heap via a
  `lua_Alloc` callback, custom `openLibraries` (base/coroutine/table/string/utf8/math —
  io/os/package/debug excluded, no FS/dynamic loading), GC step budget,
  `render`/`update` hooks.
- **Lua bindings** (`src/kernel/lua/bindings.zig`): `gfx.*` (`draw_rect`, `draw_text`,
  `fill_screen`, `present`), `input.next_event`, `time.ticks`; strict type validation —
  floats are rejected (`nil, err`), never a kernel panic (runtime.md §4/§5).
- **Keyboard layout** (`src/kernel/input/layout.zig`): the single place that maps a
  `KeyCode` + shift/ctrl to a character (US 105+). `input.next_event` sends the shell a
  ready `char`; Lua does no mapping. Host tests in `tests/input/layout_test.zig`.
- **main.lua** embedded via `@embedFile`, runs at boot; starts an interactive Lua REPL
  (banner + `> ` prompt, Enter runs a line via `load`/`pcall`, `print()` writes to the
  screen, characters come from the kernel layout).
- **Event loop**: `update()` calls Lua `update` + GC step; `render()` calls Lua
  `render`. Key events stay queued for `input.next_event`; F5 triggers hot reload
  (re-initializes `lua_State`, spec/runtime.md §5).
- **Console removed** (`ui/console.zig` + host tests): replaced by the Lua shell in M4;
  the M3 console no longer draws its `>` prompt on first frame.
- **HeapAllocator fixes** (troubleshooting C17):
  - `coalesce` computed the previous block address from the current block size instead
    of the boundary-tag footer, and after a backward merge `rawFree` linked the
    already-absorbed block — two overlapping free blocks corrupted the heap after
    ~150 Lua allocations (#6 invalid opcode).
  - `remapFn` copied with `@memcpy(dst[0..@min(...)], src)` — Zig's ReleaseSafe overlap
    check emitted `ud2`; fixed with explicit equal-length slices.
  - `grow()` now allocates 4 pages (16 KiB) at once — Lua's loadbuffer needs
    allocations larger than a single 4 KiB page.
- Runtime tests for Lua bindings in QEMU (state, gfx table, render function, render
  runs without fault).
- Kernel image 343 KiB (target < 512 KB with Lua).

### Milestone M5 — UI (live transformation, PS/2 mouse)

- **Live transformation**: `gfx.invalidate()` — the Lua shell can request a repaint
  without a key press (Hyprland-style "config is code"). `main.lua` has a declarative
  `theme` table; assigning `theme.background = 0x...` from the REPL repaints the shell
  immediately. `debug.write` binding for serial output from scripts.
- **PS/2 mouse driver** (IRQ12, second controller port):
  - 3-byte packet decode into `input.MouseEvent` (dx, dy, buttons), resync on the
    packet-start bit 3 (0x08), overflow-delta rejection (bits 6/7), dy axis inverted
    once (PS/2 +dy = up, screen y grows down).
  - Mouse packets live in their own queue (`input_queue.mouse`), fully independent of
    the keyboard queue, so a busy mouse cannot starve the keyboard/Lua update.
  - **Kernel cursor overlay** (`render/mouse_cursor.zig`): the pointer is drawn by the
    kernel (saves/restores the pixels under it), so a mouse move repaints only the
    12×19 px cursor instead of the whole screen — smooth, no flicker.
  - Robust init: port-2 test before touching the device, bounded waits for input-empty
    and ACK, read-modify-write of the shared config byte.
- **Merged PS/2 driver** (`drivers/ps2.zig`): keyboard (IRQ1) and mouse (IRQ12) back in
  one file — they share the i8042 controller, data port and status register. Each IRQ
  handler consumes only bytes whose status bit 5 marks them as its own device.
- **PS/2 fixes from hard debugging** (troubleshooting C18–C26): IRQ1 must not read
  mouse bytes; every controller write waits for input-empty; stale ACK drained before
  the port test; 0xFA/0xAA are valid mouse data after streaming starts; keyboard init
  read-modify-writes config instead of hardcoding 0x41.
- **QEMU window scaling**: `zig build run` uses `-display gtk,zoom-to-fit=on` so the
  1280×800 window fits the host screen (framebuffer and mouse coords stay native).
- New host tests: `tests/input/mouse_test.zig` (movement, dy inversion, buttons, sign
  extension, out-of-sync, overflow rejection). 49 tests total.
- Render optimization: REPL repaints only the text area when the background is
  unchanged (was a full `fill_screen` per key).
