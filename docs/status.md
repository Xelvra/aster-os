---
layout: default
title: Status
nav_order: 2
---

# Status

Aster is at milestone **M6 (Storage), in progress**. Milestones M0–M5 are
complete. Current focus: persistence foundation — PCI configuration space,
virtio-blk block device (modern transport, sector reads), initfs loading the
shell from a Limine initrd (tar). Planned next: GPT partition discovery and a
read-only ext2 backend (ADR-023).

## Milestones completed

| M | Milestone | What it delivered |
|---|---|---|
| M0 | Boot | Deterministic, reproducible build; boots in QEMU via Limine; serial marker `ASTER BOOT OK`. |
| M1 | Memory | Limine memory map parsed into `BootInfo`; bitmap page frame allocator; first-fit heap allocator implementing `std.mem.Allocator`; host unit tests (16); framebuffer verified as write-combining. |
| M2 | CPU | GDT/IDT (256 ISR stubs) with fault policy and freestanding backtrace; Local APIC timer (1 kHz) + IOAPIC routing for IRQ1; PS/2 keyboard with hardware-neutral `KeyCode`/`KeyEvent` input subsystem; Kernel Interface dispatch layer; in-QEMU runtime tests. |
| M3 | Graphics | Limine GOP framebuffer; renderer (`drawRect`, `blit`, `fillScreen`, `drawGlyph`, `drawText`) with clipping; embedded VGA 8×16 bitmap font; Graphics API module; event loop `poll → update → render`. |
| M4 | Lua | Lua 5.4.8 runtime embedded in the kernel (freestanding libc shim + custom openlibs); `RuntimeKind.Lua` with hot reload (F5); bindings `gfx.*`, `input.next_event`, `time.ticks` with strict type validation; interactive Lua REPL. |
| M5 | UI | Desktop shell in Lua split into `ui/` modules; tiling window manager (60/40 split, float + drag, fullscreen, togglesplit); Noctalia-style 35px bar; launcher with search; PS/2 mouse with kernel cursor overlay; Super key + Hyprland-standard keybindings; error containment (a script error hot-reloads the shell instead of crashing the kernel); sysmon module exposing live RAM usage. |
| M6 | Storage | In progress: initfs from a Limine initrd (tar), virtio-blk block device (sector reads, modern transport). GPT discovery and read-only ext2 next. |

## Verified properties

- **Bootable-commit rule:** every commit must leave the system runnable in
  QEMU (ADR-016).
- **Deterministic build:** same commit + same Zig version = same binary hash
  (ADR-014).
- **Metrics recorded per milestone:** kernel image size, RAM usage, and
  Kernel Entry → First Frame timing in [`spec/roadmap.md`](https://github.com/Xelvra/aster-os/blob/main/spec/roadmap.md).

The complete feature history is in the
[`CHANGELOG.md`](https://github.com/Xelvra/aster-os/blob/main/CHANGELOG.md)
(one version per milestone, e.g. `0.5.0` = M5 UI).

---

Source: [`README.md`](https://github.com/Xelvra/aster-os/blob/main/README.md)
and [`CHANGELOG.md`](https://github.com/Xelvra/aster-os/blob/main/CHANGELOG.md).
Synced: 2026-08-08.
