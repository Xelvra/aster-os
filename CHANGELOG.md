# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version number matches the project milestone (0.0.0 = M0 Boot, 0.6.0 = M6
Storage). Newer versions are listed first.

> This file is **hand-curated** (what the system can do). The raw commit
> history is regenerated separately by `tools/generate-changelog.sh` — never
> point it at this file; it writes `CHANGELOG-commits.md` instead. See Dev
> tools below.

---

## [0.6.0-alpha.1] — Milestone M6 — Storage (in progress)

### Added

* **virtio-blk block device driver:** Modern (capability-based) PCI transport,
  VIRTIO_F_VERSION_1 negotiation, split virtqueue and sector reads. Works on
  both the transitional and modern-only QEMU device; the boot log gains
  `[ OK ] storage virtio-blk` when a disk is attached.
* **initfs — shell from a tar initrd:** The UI modules (`ui/*.lua`) are packed
  into a tar, loaded by Limine as an initrd module and read at runtime instead
  of being `@embedFile`'d.
* **Persistent filesystem (ADR-023):** ext2 read-only chosen as the first
  persistent backend — used only as an on-disk representation, no POSIX
  semantics in the API, stable `open/read/close` interface, door left open for
  FAT32, EROFS, 9P and ext4.
* **Boot log as proof of work:** A styled colored boot log (`/-\STER OS`, status
  lines, boot sequence) plus a capture tool that verifies the recorded boot
  never drifts from the code (CI + pre-push hook).
* **KVM acceleration:** `zig build run` auto-detects `/dev/kvm` — KVM is closer
  to real hardware than TCG, TCG stays the fast path for automated tests.
* **Changelog dev tool:** `tools/generate-changelog.sh` regenerates the full
  commit history with a single command (see Dev tools below).

### Fixed

* **Static code check:** Deduplicated I/O helpers, removed dead code, errors
  propagated instead of empty `catch {}`, virtio descriptor-table overflow
  guarded.
* **Debugging guide:** Rewritten with a verified GDB workflow (ISO boot +
  higher-half breakpoints), what works and what does not for embedded Lua.

---

## [0.5.0-alpha.1] — Milestone M5 — UI (desktop shell)

### Added

* **Desktop environment & window manager:** Shell split into `ui/` modules
  (theme, wm, repl, launcher, input, main); tiling (60/40 split, focus ring via
  gradient border) and floating windows; Hyprland-standard keybindings (Super
  key); Noctalia-style bar (launcher, clock, workspace capsules,
  volume/session placeholders); launcher with search; workspace switching,
  fullscreen, togglesplit and UI hot reload (F5).
* **Live transformation ("config is code"):** `gfx.invalidate()` repaints the
  environment without a key press; the `theme` table is data — changing a color
  takes effect live.
* **PS/2 mouse:** 3-byte packets, smooth kernel cursor (repaints only the
  pointer), independent mouse queue, robust device detection.
* **Error containment:** A Lua script error is caught by `pcall`, the shell
  hot-reloads — the desktop recovers without crashing the kernel.
* **Sysmon KI module:** Exposes real RAM from the page frame allocator and shows
  live used/total/percent.
* **Session menu:** Lock (fullscreen overlay), Logout (shell reload), Reboot
  (i8042 reset) via the new `power` KI module.

### Fixed

* **Input freeze:** Fixed concurrent mouse movement and typing — separate
  queues, shared i8042 controller handling (input-empty, read-modify-write
  config, stale ACK).
* **Mouse desync:** Packet resync on start bit 3, overflowed deltas rejected,
  valid data bytes 0xFA/0xAA no longer filtered.
* **Reload use-after-free:** `runtime.reload()` from the menu closed a
  mid-call `lua_State` — reload is now deferred out of the Lua call frame.

---

## [0.4.0-alpha.1] — Milestone M4 — Lua runtime

### Added

* **Lua 5.4.8 in the kernel:** Embedded interpreter (27 `.c` files) with a
  freestanding libc shim (custom openlibs: `base`, `coroutine`, `table`,
  `string`, `utf8`, `math`) — scripts run directly in the kernel, no host OS
  dependency.
* **Interactive REPL:** A Lua console starts after boot — type code, Enter runs
  it, `print()` writes to the screen; line editing and command history.
* **Lua bindings:** `gfx.*`, `input.next_event`, `time.ticks`, `sysmon.*` with
  strict type validation (floats rejected); the shell receives a ready `char`.
* **Hot reload (F5):** UI script changes take effect without a system restart.
* **GC budget per frame:** a `collectgarbage("step", ...)` budget in every
  `update()` keeps GC pauses off the hot render path.
* **Runtime tests for the bindings in QEMU:** the bindings are exercised in the
  real kernel context (a real `lua_State`), not host mocks.
* **Keyboard layout:** `input/layout.zig` infrastructure (US 105+) — maps
  `KeyCode`+shift/ctrl to a character, numpad, extended keys, Alt/AltGr layer.

### Fixed

* **Shift release:** 0xAA is the shift break scancode, not a self-test —
  `shift_pressed` no longer sticks after the first press.
* **Heap allocator:** Coalescing fix (previous + absorbed block), remapFn
  overlap, growth in contiguous blocks.

---

## [0.3.0-alpha.1] — Milestone M3 — Graphics

### Added

* **Framebuffer:** Limine GOP wrapped in a `Framebuffer` (base, width/height,
  pitch, bpp, color shifts).
* **Rendering engine:** `drawRect`, `blit`, `fillScreen`, `drawGlyph`,
  `drawText` with clipping — no heap allocation on the draw path.
* **Embedded VGA font (8×16):** Bitmap font (public domain) with `?` fallback.
* **Graphics API in KI:** `api/graphics.zig` with `GraphicsOp` 0–5 wired into
  `sys.dispatch`; host tests for renderer clipping/blit.
* **Event loop:** `poll → update → render` with render-on-dirty.
* **Text on screen:** Keyboard → ASCII with shift; console with wrap, scroll,
  backspace and cursor; typing visible in QEMU.

### Fixed

* **ISR register corruption:** `isr_common` saves/restores `%rax` — the timer
  IRQ interrupted a render and clobbered a live register.

---

## [0.2.0-alpha.1] — Milestone M2 — CPU

### Added

* **GDT/IDT:** 256 uniform ISR stubs, fault policy, `lidt` via a descriptor
  buffer.
* **Local APIC timer (1 kHz):** Periodic tick, LAPIC EOI, SVR init (APIC enable
  + spurious vector 0xFF ignored without EOI).
* **IOAPIC:** Maps 0xFEC00000 and programs IRQ1 → vector 0x21 for ISA IRQ
  delivery in APIC mode.
* **Input subsystem:** Hardware-neutral `KeyCode`/`KeyEvent` — the driver is only
  a producer, applications never see scancodes; USB HID can map to the same
  `KeyCode` without touching KI.
* **KI dispatch layer:** `api/sys.zig` — `Syscall`/`KiStatus`, `Debug.write`,
  self-test at boot.
* **Fault policy + backtrace:** `ASTER FAULT` dump (vec, err, rip, cr2, rbp)
  with a freestanding frame-pointer backtrace.
* **Runtime tests in QEMU:** In-kernel tests exit QEMU via `isa-debug-exit`
  (pass = exit 99, fail = exit 97).

### Fixed

* **PIC 8259 remap:** To vectors 0x20–0x2F (legacy fallback; active ISA IRQs run
  over IOAPIC).
* **Kernel size:** Removed `link_gc_sections = false`, which bloated the kernel
  7× (196 KB → 28.8 KB).

---

## [0.1.0-alpha.1] — Milestone M1 — Memory

### Added

* **Bitmap Page Frame Allocator:** 4 KiB pages, 1 bit per page, deterministic
  first-free allocation, zeroing on request, OOM as an error (never a panic);
  host unit tests (16).
* **First-fit heap allocator:** Boundary tags, coalescing, dynamic growth from
  the PFA — implements `std.mem.Allocator`.
* **Boot memory dump:** RAM layout (usable bytes, free pages) + heap allocator
  self-test.
* **Framebuffer cache attribute:** Verified from PTE + PAT MSR that Limine maps
  the framebuffer as **WC** (no frame-latency risk).

---

## [0.0.0-alpha.1] — Milestone M0 — Boot

### Added

* **Basic OS architecture:** Complete architectural specification of the kernel
  and system in Zig (spec/).
* **Kernel boots via Limine:** Working x86_64 long-mode start through the Limine
  bootloader in QEMU, serial marker `ASTER BOOT OK`.
* **Deterministic build:** Same commit + same Zig = identical binary hash
  (ADR-014); verified by `tools/verify-reproducible.sh`.
* **Serial driver & diagnostics:** Serial output for logging + troubleshooting
  infrastructure.
* **Basic tooling:** `zig build` (boot/iso/test), `tools/qemu-smoke.sh`,
  `tools/bench.sh`; MIT license; English README for the public repo.

---

## Dev tools

**`CHANGELOG.md` is hand-curated — never overwrite it with a generator.**

The raw commit history is regenerated separately:

- `tools/generate-changelog.sh` writes `CHANGELOG-commits.md` (raw, oldest
  first, verbatim).
- `tools/generate-changelog.sh --log` prints it to stdout without writing.
- `tools/generate-changelog.sh --help` shows the options.

### Why two files

- **`CHANGELOG.md`** — the curated, aggregated view (what the system can do,
  one version per milestone). Read this.
- **`CHANGELOG-commits.md`** — the raw, verbatim commit log; regenerated on
  demand, never edited by hand.

### Regenerate the raw commit history

1. **One-time alias setup (in a terminal):**
   ```bash
   git config alias.changelog '!bash tools/generate-changelog.sh'
   ```

2. **Regenerate:**
   ```bash
   git changelog            # writes CHANGELOG-commits.md
   git changelog --log      # prints to stdout (no write)
   git changelog --help     # help
   ```

### Why this approach

* **Two layers, no accidents:** readers get the curated `CHANGELOG.md`; the raw
  history is one command away and can never clobber it.
* **Always up to date:** anyone regenerates the raw history exactly when needed.
* **No merge conflicts:** developers do not overwrite each other's file in
  merge requests.
