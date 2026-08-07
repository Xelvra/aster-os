# Aster OS

[![status](https://img.shields.io/badge/status-pre--alpha-red.svg)](spec/roadmap.md)
[![milestone](https://img.shields.io/badge/milestone-M2%20CPU-informational.svg)](spec/roadmap.md)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d.svg)](.zig-version)
[![architecture](https://img.shields.io/badge/arch-x86__64-blue.svg)](spec/architecture-overview.md)
[![bootloader](https://img.shields.io/badge/bootloader-Limine-808080.svg)](libs/limine)
[![Lua](https://img.shields.io/badge/Lua-5.4.8-2C2D72.svg)](libs/lua-5.4)
[![license](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

> **Aster is an experimental desktop operating system written in Zig.**
>
> Aster targets **x86_64 exclusively** (QEMU `q35`; see [`spec/non-goals.md`](spec/non-goals.md)).
> The first implementation deliberately favors **simplicity over isolation**: the desktop,
> scripting engine, and runtime share a single address space to minimize complexity and
> maximize iteration speed. The public interfaces are designed as **stable abstractions**,
> so individual subsystems can later be moved into isolated processes **without changing
> application APIs**.

> Full manifesto (including what Aster is NOT and accepted trade-offs):
> [`spec/manifest.md`](spec/manifest.md).

This project requires the Zig version listed in [`.zig-version`](.zig-version).

## Status

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
zig build run          # boot in QEMU
zig build test         # host unit tests
./tools/qemu-smoke.sh  # automated boot test (serial marker + timeout)
./tools/qemu-test.sh   # in-QEMU runtime tests (isa-debug-exit)
./tools/verify-reproducible.sh  # deterministic build check (ADR-014)
```

## Architecture at a glance

```
BIOS / UEFI
     ↓
Limine (bootloader)
     ↓
Zig kernel (Ring 0)
     ↓
KI (api/*)
     ├──→ Lua userland (shell/UI)
     └──→ WASI → WASM (standalone processes)
```

Detailed layers, interfaces, and diagram: [`spec/architecture-overview.md`](spec/architecture-overview.md) §3.

## Documentation

The complete architecture specification lives in [`spec/`](spec/README.md).
Start with the [architecture overview](spec/architecture-overview.md).

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
| M3 | Graphics: framebuffer, renderer, text on screen |
| M4 | Lua: "Hello from Lua" on screen, hot reload |
| M5–M8 | UI (shell in Lua), storage, runtime (wasm), stabilization |

Details in [`spec/roadmap.md`](spec/roadmap.md).

## License

MIT — see [LICENSE](LICENSE).
