# Aster OS

[![status](https://img.shields.io/badge/status-pre--alpha-red.svg)](spec/roadmap.md)
[![version](https://img.shields.io/badge/version-0.1.0--alpha.1-orange.svg)](.version)
[![milestone](https://img.shields.io/badge/milestone-M6%20Storage-informational.svg)](spec/roadmap.md)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d.svg)](.zig-version)
[![architecture](https://img.shields.io/badge/arch-x86__64-blue.svg)](spec/architecture.md)
[![bootloader](https://img.shields.io/badge/bootloader-Limine-808080.svg)](libs/limine)
[![Lua](https://img.shields.io/badge/Lua-5.4.8-2C2D72.svg)](libs/lua-5.4)
[![license](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

> **Aster is an experimental desktop operating system written in Zig.**
>
> Aster currently targets **x86_64** (QEMU `q35`) — the only implemented architecture for
> now. A future port (e.g. ARM, RISC-V) is not excluded by design, but it is not a goal
> today and would need its own scope change (see [`spec/non-goals.md`](spec/non-goals.md)).
> The first implementation deliberately favors **simplicity over isolation**: the desktop,
> scripting engine, and runtime share a single address space to minimize complexity and
> maximize iteration speed. The public interfaces are designed as **stable abstractions**,
> so individual subsystems can later be moved into isolated processes **without changing
> application APIs**.

> Full manifesto (including what Aster is NOT and accepted trade-offs):
> [`spec/manifest.md`](spec/manifest.md).

This project requires the Zig version listed in [`.zig-version`](.zig-version).

## Status

- **Milestone M5 (UI) complete:** desktop shell in Lua split into `ui/` modules
  (theme, wm, repl, launcher, input, main) concatenated into one chunk by `lua.zig`.
  Tiling window manager (60/40 split, focus ring via gradient border, float + drag,
  fullscreen, togglesplit), Noctalia-style 35px bar (launcher, clock, workspace
  capsules, volume/session placeholders), working launcher with search, PS/2 mouse with kernel
  cursor overlay, Super key + Hyprland-standard keybindings, error containment
  (a script error hot-reloads the shell instead of crashing the kernel), sysmon
  KI module exposing live RAM usage.
- **Milestone M4 (Lua) complete:** Lua 5.4.8 runtime embedded in the kernel (freestanding
  libc shim + custom openlibs: base/coroutine/table/string/utf8/math); `api/runtime.zig`
  with `RuntimeKind.Lua` and hot reload (F5); Lua bindings `gfx.*`, `input.next_event`,
  `time.ticks` with strict type validation (floats rejected); keyboard layout is
  infrastructure (`input/layout.zig`, US 105+) — bindings send a ready `char`; after boot
  an interactive **Lua REPL** starts (banner + `> ` prompt, type code, Enter runs it,
  `print()` writes to the screen); GC step budget per frame; runtime tests for Lua
  bindings in QEMU. Kernel image 336 KiB (< 512 KB target; ReleaseFast 259 KiB).
- **Milestone M3 (Graphics) complete:** Limine GOP framebuffer wrapped in `Framebuffer`;
  renderer (`drawRect`, `blit`, `fillScreen`, `drawGlyph`, `drawText`) with clipping;
  embedded VGA 8×16 bitmap font; Graphics API module (`api/graphics.zig`) in KI dispatch;
  event loop `poll → update → render` (render-on-dirty); keyboard types visible text
  on screen (shift-aware); host tests for renderer clipping/blit + runtime test.
- **Milestone M2 (CPU) complete:** GDT/IDT (256 ISR stubs), fault policy with
  freestanding backtrace; Local APIC timer (1 kHz) + IOAPIC routing for IRQ1; PS/2
  keyboard with hardware-neutral `KeyCode`/`KeyEvent` input subsystem; KI dispatch
  layer (`api/sys.zig`); in-QEMU runtime tests via `isa-debug-exit`.
- **Milestone M1 (Memory) complete:** Limine memory map parsed into `BootInfo`;
  bitmap Page Frame Allocator; first-fit heap allocator implementing `std.mem.Allocator`;
  host unit tests (16); boot prints RAM layout; framebuffer verified as **WC** cache.
- **Milestone M0 (Boot) complete:** deterministic, reproducible build; boots in QEMU via
  Limine; prints `ASTER BOOT OK` on serial.
- Bootable-commit rule: **every commit must leave the system runnable in QEMU.**
  See [`spec/verification.md`](spec/verification.md).
- Roadmap M0–M8: [`spec/roadmap.md`](spec/roadmap.md). This is a pre-alpha prototype,
  not a usable OS yet.

## Prerequisites

- **Zig** — exact version in [`.zig-version`](.zig-version) (0.16.0), not a distro package
  (see [`spec/verification.md`](spec/verification.md) §3).
- **QEMU** (`qemu-system-x86_64`) — target emulation.
- **Limine** — vendored in `libs/limine/` (ADR-012), no system packages.
- **xorriso / mtools** — building the bootable ISO / disk image.
- **Lua 5.4.8** — vendored in `libs/lua-5.4/` (ADR-007).

Full tool table and dependency status: [`spec/verification.md`](spec/verification.md) §6.

## Quick start

```bash
zig build run          # boot in QEMU (auto KVM when /dev/kvm is available)
zig build run -Dkvm=false  # force TCG emulation
zig build test         # host unit tests
./tools/qemu-smoke.sh  # automated boot test (serial marker + timeout; auto KVM)
./tools/qemu-test.sh   # in-QEMU runtime tests (isa-debug-exit; auto KVM)
./tools/verify-reproducible.sh  # deterministic build check (ADR-014)
```

Build modes (default is `ReleaseSafe`, the verified production mode):
`zig build -Doptimize=ReleaseFast` trades safety checks for ~20 % smaller
image and faster execution; `-Doptimize=Debug` for debugging. The Lua C
sources are always compiled with `-Os` regardless of the mode.

## Architecture at a glance

```
┌──────────────────┐
│    BIOS / UEFI   │
│       BOOT       │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│      LIMINE      │
│    BOOTLOADER    │
└────────┬─────────┘
         │
         ▼
╔════════════════════════════╗
║         ZIG KERNEL         ║
║           RING 0           ║
║                            ║
║       # M0/M1/M2/M3/M4     ║
║                            ║
║  CPU / MEMORY / IRQ        ║
║  DRIVERS / SCHEDULER (M7+) ║
║  / IPC (M8+) / CORE SRVS   ║
╚═══════════╤════════════════╝
            │
            ▼
┌──────────────────┐
│    KI (API/*)    │
│       # M2       │
└─────────┬────────┘
          │
  ┌───────┼───────┐
  │               │
  ▼               ▼
┌──────────────┐  ┌──────────────────────┐
│ LUA RUNTIME  │  │     WASM RUNTIME     │
│     # M4     │  │       # M7/M9+       │
└──────┬───────┘  │                      │
       │ ▲        │ ┌──────────────────┐ │
       │ └──────┐ │ │    ASTER APPS    │ │
       ▼        │ │ │      # M7        │ │
┌────────────┐  │ │ └──────────────────┘ │
│  SHELL/UI  │──┘ │                      │
│    # M5    │    │ ┌──────────────────┐ │
└────────────┘    │ │       WASI       │ │
                  │ │   FOREIGN APPS   │ │
                  │ │      # M9+       │ │
                  │ └──────────────────┘ │
                  └──────────────────────┘
```

Detailed layers, interfaces, and diagram: [`spec/architecture.md`](spec/architecture.md) §3.

### Boot

A sample of the kernel boot log from `zig build run` (the terminal shows it in
color; this excerpt is plain text and is maintained by hand):

```
ASTER KERNEL ENTRY

/-\STER OS  0.1.0-alpha.1
[ OK ] bootloader       limine handoff
[ OK ] interrupts       idt · pic
[ OK ] cpu              page tables · apic timer
[ OK ] input            ps/2 keyboard + mouse
[ OK ] graphics         800x600 framebuffer · wc
[ OK ] renderer         primitives + bitmap font
[ OK ] runtime          lua 5.4.8 shell
[ OK ] memory           509 MiB usable · 2 MiB used
[ OK ] kernel interface dispatch ready
[ OK ] accelerator      kvm
[ OK ] boot sequence    complete

ASTER BOOT OK
ASTER FIRST FRAME
```

The always-current capture (with date, host, accelerator and commit metadata) is in
[`docs/boot-log.md`](docs/boot-log.md), regenerated by `tools/capture-boot.sh`; a
pre-push hook and CI verify it never drifts from the code
(`./tools/capture-boot.sh --check`).

## Documentation

The complete architecture specification lives in [`spec/`](spec/README.md).
Start with the [architecture overview](spec/architecture.md).

The internal specs are written in Czech by design — this is the author's working
documentation, not marketing; see the language policy in
[`spec/README.md`](spec/README.md).

If the system crashes or hangs: [`spec/debugging.md`](spec/debugging.md)
(Debugging Survival Guide) and [`spec/troubleshooting.md`](spec/troubleshooting.md)
(known pitfalls).

## Roadmap

| Milestone | Goal |
|-----------|------|
| M0 ✅ | Boot: deterministic build, boots in QEMU, serial marker |
| M1 ✅ | Memory: PFA + heap allocator |
| M2 ✅ | CPU: IDT, APIC timer, IOAPIC, PS/2 keyboard |
| M3 ✅ | Graphics: framebuffer, renderer, text on screen |
| M4 ✅ | Lua: interactive REPL in kernel, hot reload |
| M5 ✅ | UI: desktop shell in Lua — tiling WM, bar, launcher, workspace, mouse, error containment, live transformation |
| M6 🔄 | Storage: initfs, virtio-blk, GPT, filesystem, cooperative reads |

Details in [`spec/roadmap.md`](spec/roadmap.md).

## License

MIT — see [LICENSE](LICENSE).
