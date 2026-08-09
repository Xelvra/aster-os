---
layout: default
title: Status
nav_order: 2
source: spec/roadmap.md, CHANGELOG.md
synced: 2026-08-09
---

# Status

Aster is at milestone **M7 (Runtime), in progress**. Milestones M0–M6 are
complete. Current focus: wasm apps, multitasking and app isolation — wasm3
vendored, `Runtime.spawn(.Wasm, ...)`, a preemptive round-robin scheduler
(ADR-017) and per-program `lua_State`s. Multi-layout keyboard is already done
(ADR-024, US/CZ switchable at runtime).

## Milestones completed

| M | Milestone | What it delivered |
|---|---|---|
| M0 | Boot | Deterministic, reproducible build; boots in QEMU via Limine; serial marker `ASTER BOOT OK`. |
| M1 | Memory | Limine memory map parsed into `BootInfo`; bitmap page frame allocator; first-fit heap allocator implementing `std.mem.Allocator`; host unit tests; framebuffer verified as write-combining. |
| M2 | CPU | GDT/IDT (256 ISR stubs) with fault policy and freestanding backtrace; Local APIC timer (1 kHz) + IOAPIC routing for IRQ1; PS/2 keyboard with hardware-neutral `KeyCode`/`KeyEvent` input subsystem; Kernel Interface dispatch layer; in-QEMU runtime tests. |
| M3 | Graphics | Limine GOP framebuffer; renderer (`drawRect`, `blit`, `fillScreen`, `drawGlyph`, `drawText`) with clipping; embedded VGA 8×16 bitmap font; Graphics API module; event loop `poll → update → render`. |
| M4 | Lua | Lua 5.4.8 runtime embedded in the kernel (freestanding libc shim + custom openlibs); `RuntimeKind.Lua` with hot reload (F5); bindings `gfx.*`, `input.next_event`, `time.ticks` with strict type validation; interactive Lua REPL. |
| M5 | UI | Desktop shell in Lua split into `ui/` modules; tiling window manager; Noctalia-style bar; launcher with search; PS/2 mouse with kernel cursor overlay; Super key + keybindings; error containment (a script error hot-reloads the shell instead of crashing the kernel); sysmon module exposing live RAM usage. |
| M6 | Storage | initfs from a Limine initrd (tar), virtio-blk block device (sector reads, modern transport), GPT partition discovery, read-only ext2 with the thin Aster file API, deterministic test-disk infrastructure and a CI job with a disk. |
| M7 | Runtime | In progress: wasm apps, multitasking, app isolation. |

## Verified properties

- **Bootable-commit rule:** every commit must leave the system runnable in
  QEMU (ADR-016).
- **Deterministic build:** same commit + same Zig version = same binary hash
  (ADR-014).
- **Metrics recorded per milestone:** kernel image size, RAM usage, and
  Kernel Entry → First Frame timing in [`spec/roadmap.md`](https://github.com/Xelvra/aster-os/blob/main/spec/roadmap.md).

The complete feature history is in the
[`CHANGELOG.md`](https://github.com/Xelvra/aster-os/blob/main/CHANGELOG.md)
(one version per milestone, e.g. `0.6.0` = M6 Storage).

---

Last synced from [`spec/roadmap.md`](https://github.com/Xelvra/aster-os/blob/main/spec/roadmap.md) and [`CHANGELOG.md`](https://github.com/Xelvra/aster-os/blob/main/CHANGELOG.md) on 2026-08-09.
