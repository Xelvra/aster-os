# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Version numbers track milestones (0.6.0-alpha.1 = M6 Storage). Versions
0.2.0–0.5.0 are skipped — milestones M2–M5 shipped inside 0.1.0-alpha.1
(history below).

## [Unreleased]

### Added

- **First-frame latency profiling**: measured the Kernel Entry → First Frame split
  (mem ~9 ms, ps2+apic ~2 ms, graphics ~4 ms, Lua createState ~27 ms, Lua load ~35 ms,
  first render ~23 ms). Finding: QEMU runs without KVM (pure TCG interpretation), so the
  Lua interpreter (createState + load of the 25 KB shell) dominates the boot time — an
  emulation artifact, not a kernel problem. Verified that allocations are not a
  bottleneck (1071 allocs / 157 KB during shell load). See the metric note ³ in
  `spec/roadmap.md`.
- **Live theme change runtime test**: changing `theme.*` fields from Lua and re-rendering
  stays healthy (M5 live transformation, `spec/runtime.md` §5a).
- **Session menu** (M5 close): the bar "Lock" placeholder is now a working menu —
  Lock (full-screen overlay, any key unlocks), Logout (`runtime.reload()` — fresh
  desktop), Reboot (`power.reboot()` — i8042 reset). New KI module `api/power.zig`
  (`Power = 7`), `RuntimeOp.reload = 3`, Lua bindings `runtime.reload()` and
  `power.reboot()`.
- **KVM acceleration**: `zig build run` auto-detects `/dev/kvm` and adds `-enable-kvm`
  (override with `-Dkvm=false` to force TCG, `-Dkvm=true` to force KVM);
  `tools/qemu-smoke.sh`, `tools/qemu-test.sh` and `tools/bench.sh` auto-add
  `-enable-kvm` via `tools/qemu-accel.sh` when `/dev/kvm` is available (TCG fallback
  otherwise). QEMU TCG is the quick-capture path; KVM is closer to real hardware.
- **Accelerator marker**: the boot log reports the accelerator (`[ OK ] accelerator kvm` /
  `tcg` / `hv`) via CPUID hypervisor leaf 0x40000000, vendor in EBX/ECX/EDX.
- **RAM idle marker**: the boot log's memory line shows `X MiB usable · Y MiB used` after
  the shell loads (PFA-managed memory: kernel image + heap + bitmap + stacks; the
  framebuffer is MMIO, not RAM) — closes the ADR-015 measurement gap.
- **M5 measurements under KVM** (recorded in `spec/roadmap.md` notes 4/5): Kernel Entry →
  First Frame ≈ 24 ms (vs 90 ms TCG), render throughput ≈ 32 renders/10 ticks (vs 3–4
  TCG), RAM idle ≈ 2 MiB. Confirms the < 40 ms target is reachable — TCG was the boot
  bottleneck.
- **Boot proof of work**: the serial boot sequence is a styled `[ OK ]` log — the
  `/-\STER OS` header, colored status lines (green OK / yellow warn / red fail), a memory
  summary and a "boot sequence complete" capstone separated by blank lines
  (`src/kernel/bootlog.zig`); boot markers (`ASTER KERNEL ENTRY` / `ASTER BOOT OK` /
  `ASTER FIRST FRAME`) preserved for the tools. `tools/capture-boot.sh` boots a real image,
  regenerates `boot-log.md` with metadata (date, host, accelerator, commit) and
  `--check` verifies it never drifts (CI + pre-push hook, `tools/install-hooks.sh`).
  README shows the full log as plain text.
- **Roadmap M9/M10**: new milestones in `spec/roadmap.md` and README — M9 Ecosystem
  (network, audio, browser, WASI) and M10 Adoption (real hardware, installable image,
  docs, contributors); the "M9+" shorthand is now a proper M9 milestone everywhere.
- **ADR-022 — network as a KI module**: planned for M9 (`net.*` — virtio-net,
  ARP/IPv4/ICMP/UDP), with the Ring 0 remote-DoS safety brake resolved (parser that
  never faults on foreign input, off by default, fuzz tests); `non-goals.md` updated.
- **ADR-023 — persistent filesystem**: ext2 read-only as the first persistent backend
  (M6.1), used only as on-disk representation (no POSIX semantics leak into the Aster
  API), explicit supported feature subset with mount-time feature check paired with the
  exact `mke2fs` invocation, and a thin stable `open/read/close` interface that keeps
  the door open for later backends (FAT32, EROFS, 9P, ext4); `spec/roadmap.md` M6.1
  breakdown added.
- **PCI configuration space**: minimal driver for the classic port-based mechanism
  (0xCF8/0xCFC) — `enumerate`, `findDevice` and BAR decoding (`src/kernel/drivers/pci.zig`).
- **virtio-blk driver** (M6.1.1): modern (capability-based) transport over PCI — capability
  parsing, MMIO BAR mapping via the page tables, feature negotiation (VIRTIO_F_VERSION_1),
  a split virtqueue and sector reads. Works on both the transitional (0x1af4:0x1001) and
  the modern-only (0x1af4:0x1042) device that QEMU exposes with/without `disable-legacy`.
  On boot with a disk attached the log gains `[ OK ] storage virtio-blk`
  (`src/kernel/drivers/virtio.zig`).
- **License transparency**: `LICENSE-THIRD-PARTY.md` now names
  [cachyos-hypr-noctalia](https://github.com/CachyOS/cachyos-hypr-noctalia) as the
  desktop inspiration (upstream has no license — we reimplement, not copy); sections
  alphabetized and trimmed to what is actually required.
- **initfs (M6)**: the shell modules (`ui/*.lua`) are packed into a tar and loaded as a
  Limine initrd module, read at runtime instead of `@embedFile`'d — Limine module
  request, `src/kernel/fs/tar.zig` parser, and the heap now grows to fit large
  allocations (a single contiguous block).

### Changed

- **Versioning**: bumped to `0.6.0-alpha.1` (tracking milestone M6). Versions
  0.2.0–0.5.0 are skipped — M2–M5 shipped inside 0.1.0-alpha.1.
- **Changelog**: merged the archive into a single `[0.1.0-alpha.1]` history
  section; boot-log proof of work moved from `docs/` to the repo root
  (`boot-log.md`).

### Fixed

- **Boot under KVM / real hardware (C28)**: Zig ReleaseSafe codegen for
  `asm volatile ("ldmxcsr %[v]")` with a `"m"` operand passed address-of-address,
  so `ldmxcsr` loaded a pointer instead of the value 0x1F80 → reserved MXCSR bits →
  #GP → triple fault before serial init. TCG does not validate reserved MXCSR bits,
  masking the bug. `write_mxcsr` now passes the address in a register and
  dereferences it explicitly (scratch-register pattern, `spec/troubleshooting.md` C28).

- **Live transformation**: the bar height was captured once at shell load (`bar_height`),
  so changing `theme.bar.height` at runtime desynced mouse hit-testing (launcher position,
  workspace capsules, drag clamp) from rendering. It is now read live from the theme
  everywhere (`input.lua`, `launcher.lua`).
- **Empty bar and missing window titles**: Lua `/` always yields a float, and the strict
  integer bindings reject floats, so every bar widget (launcher button, clock, workspace
  capsules, volume/session) and the window titles silently failed to draw. Switched the
  affected divisions to integer `//` (`wm.lua`).
- **Reload from within Lua was a use-after-free**: `runtime.reload()` from the session
  menu (Logout) closed the `lua_State` that was mid-call. Reload is now deferred — a
  trigger only sets a flag and the event loop performs it outside any Lua call frame
  (`api/runtime.zig` `requestReload`/`performReload`, runtime test "reload from Lua is
  deferred").

## [0.1.0-alpha.1] - 2026-08-08

First tagged version: an experimental desktop OS booting to a window manager in QEMU.

### Added

- **Boot (M0)**: deterministic, reproducible build (ADR-014); boots via Limine, prints
  `ASTER BOOT OK`; `zig build`/`iso`/`run`/`test` targets.
- **Memory (M1)**: bitmap Page Frame Allocator + first-fit heap allocator, both with
  host unit tests; WC framebuffer cache verified.
- **CPU (M2)**: GDT/IDT (256 ISR stubs), fault policy + freestanding backtrace, local
  APIC timer (1 kHz), IOAPIC routing, PS/2 keyboard with hardware-neutral `KeyCode`
  input subsystem; in-QEMU runtime tests via `isa-debug-exit`.
- **Graphics (M3)**: Limine GOP framebuffer, renderer (`drawRect`/`blit`/`fillScreen`/
  `drawGlyph`/`drawText`) with clipping, embedded VGA 8×16 font, Graphics API in KI
  dispatch, event loop `poll → update → render`.
- **Lua (M4)**: Lua 5.4.8 vendored into the kernel (freestanding libc shim), generic
  runtime API (`spawn`/`reload`), interactive REPL, `gfx.*`/`input`/`time` bindings,
  hot reload (F5). Kernel 336 KiB (ReleaseFast 259 KiB).
- **Desktop shell (M5)**: tiling window manager in Lua (`src/kernel/lua/ui/` modules)
  with a Noctalia-style bar, workspace capsules, working launcher with search, float +
  drag, fullscreen, togglesplit, Super key and Hyprland-standard keybindings; PS/2
  mouse with kernel cursor overlay; error containment (a script error hot-reloads the
  shell instead of crashing the kernel); sysmon KI module exposing live RAM; new
  graphics primitives `round_rect`/`rect_border`/`gradient_border` (frozen KI ops 7–9).
  Kernel 366 KiB, Kernel Entry → First Frame ≈ 90 ms.
- 53 host tests + in-QEMU runtime tests (timer, mouse, cursor, framebuffer, Lua
  bindings, error containment, render throughput).

### Fixed

- Heap allocator coalescing bug causing #6 invalid opcode after ~150 Lua allocations
  (C17).
- Debug build (`zig build -Doptimize=Debug`) rejected `(%[reg])` memory operands —
  Zig 0.16 mode inconsistency, worked around via a scratch register (C27, handoff H2).

### Project init

- Project initialization with Zig 0.16.0 pinned in `.zig-version` (ADR-013).
- Full architecture specification in `spec/`:
  - Architecture overview, manifest, non-goals, coding style, invariants.
  - Kernel Interface (KI) with frozen operation numbers (ADR-003, ADR-004).
  - Subsystem specs: graphics, input, timer, memory, runtime.
  - Milestone roadmap M0–M8 with quality metrics (ADR-015).
  - Verification pipeline and bootable-commit rule (ADR-016).
  - Debugging Survival Guide.
- Architecture Decision Records ADR-001..ADR-021:
  - Evolutionary SASOS, single address space Ring 0, stable interfaces.
  - Renderer layer, generic runtime API, Lua 5.4 vendored, event loop.
  - Minimal rendering primitives, no filesystem yet, wasm3 later, Limine.
  - Zig version pinning, deterministic build, measure every milestone.
  - Bootable commit, concurrency model M7, Ring 3 KI transport.
  - Bootloader gate, future extensibility (new KI modules).
  - Extended rendering primitives (roundRect, border, gradient) for the UI.


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
- **QEMU window scaling**: `zig build run` uses `-display gtk,zoom-to-fit=on` and
  `limine.conf` requests `resolution: 800x600`, so the window fits the host screen
  (framebuffer and mouse coords stay native). QEMU-specific; real-hardware behaviour
  must be re-verified once USB boot lands.
- **Desktop shell — window manager** (`main.lua`): the REPL-only screen becomes a small
  tiling WM driven by a declarative `theme` table (colors + geometry are data, hot
  reload via F5). Cachy-style dark palette, Noctalia-style 35px bar (launcher, clock,
  workspace capsules, volume/session placeholders), tiling 60/40 or stacked splits,
  focus ring via a 45° gradient border, opacity 0.95/0.85, border 2, radius 10,
  gaps 8/3. The REPL stays as a window inside the shell.
  - **Shortcuts**: Super+Enter terminal, Super+Q close, Super+Space launcher,
    Super+1/2/3 workspace, Alt+Tab cycle, F5 hot reload (Hyprland-standard bindings
    refined in a later commit).
  - **Mouse in Lua**: `input.mouse_x/y/left/right/middle` share the state the kernel
    cursor overlay uses; a click on a window header focuses it, on a workspace capsule
    switches workspace.
  - **Super key**: `KeyCode.super_left/right` from PS/2 ext codes 0x5B/0x5C, `ev.super`
    in Lua.
- **New graphics primitives** (frozen KI ops 7–9): `round_rect`, `rect_border` and
  `gradient_border` (linear interpolation for the active window border), implemented
  in framebuffer/renderer with bounds clipping.
- Fixed: a window on a non-active workspace had 0×0 size, underflowing u32 arithmetic
  in `fillRect` and faulting the kernel (#UD) — the shell renders only windows of the
  active workspace.
- **Floating windows**: Super+Alt+Space toggles tiled ↔ floating (centered, keeps
  position until tiled again); dragging a floating window header moves it;
  Super+Shift+arrows / +1/2/3 move the focused window to another workspace.
- **Hyprland-standard keybindings** (port of the reference binds): Super+Enter
  terminal (focus REPL), Super+Q close, Super+Space launcher, Super+Alt+Space float,
  Super+F / D fullscreen (hides the bar), Super+J togglesplit, Super+arrows focus,
  Super+S scratchpad, Alt+Tab cycle. `layout_mode` (splith/splitv) and fullscreen
  support in the tiling layout.
- **Error containment** (spec/runtime.md §5): `callUpdate`/`callRender` return a
  `CallResult` and log the Lua error; a script error is caught by `lua_pcall`, the
  event loop hot-reloads the shell so the desktop recovers instead of staying
  half-drawn. New in-QEMU runtime test injects a failing `render()` and verifies the
  kernel survives and the shell reloads.
- **Sysmon KI module**: `api/sysmon.zig` exposes real kernel metrics to the shell —
  `sysmon.ram_total_mb()` / `sysmon.ram_free_mb()` read the page frame allocator.
  The sysmon window now shows live RAM (used/total, percent, ticks) instead of
  placeholders. New Syscall number `Sysmon = 6` (frozen).
- **Working launcher**: typing filters the app list, up/down move the selection,
  Enter runs the selected app (open repl/sysmon/files, toggle fullscreen, close
  focused window). Fixed the "render error" at first Super+Space: `launcher_input`
  was a Lua `local` declared after the functions using it, so the first render
  indexed `nil` — now declared before use.
- **Shell split into modules**: `src/kernel/lua/ui/` — theme, wm, repl, launcher,
  input, main. `lua.zig` concatenates them into one chunk in dependency order, so
  `local` state stays shared (no `require`/FS dependency, no global rewrite).
- New host tests: `tests/input/mouse_test.zig` (movement, dy inversion, buttons, sign
  extension, out-of-sync, overflow rejection). 53 tests total.
- Render optimization: REPL repaints only the text area when the background is
  unchanged (was a full `fill_screen` per key).
