---
layout: home
title: Home
nav_order: 1
---

# Aster OS

> **Aster is an experimental desktop operating system written in Zig.**

Aster currently targets **x86_64** (QEMU `q35`) — the only implemented
architecture for now. The first implementation deliberately favors
**simplicity over isolation**: the desktop, scripting engine, and runtime share
a single address space to minimize complexity and maximize iteration speed. The
public interfaces are designed as **stable abstractions**, so individual
subsystems can later be moved into isolated processes **without changing
application APIs**.

This is an alpha prototype — the goal is a working, measurable system, not
yet a usable OS. Milestone **M6 (Storage)** is in progress; the project is
building on M0–M5 (boot, memory, CPU, graphics, Lua, UI).

## What it does today

Boots deterministically in QEMU (via Limine) and brings up, in order:

```
/-\STER OS  0.7.0-alpha.1
[ OK ] bootloader       limine handoff
[ OK ] interrupts       idt · pic
[ OK ] cpu              page tables · apic timer
[ OK ] input            ps/2 keyboard + mouse
[ OK ] storage          virtio-blk
[ OK ] gpt              1 partition(s)
[ OK ] fs               ext2
  lost+found
  README
  apps
  theme.lua           bg=0x0f1117
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

- A Lua 5.4.8 shell with an interactive REPL and hot reload (F5).
- A desktop shell in Lua — tiling window manager, taskbar, launcher,
  workspaces, mouse cursor, live theme changes.
- PS/2 keyboard + mouse, an 800x600 framebuffer with a software renderer.
- A page frame allocator, a first-fit heap allocator, IDT/APIC timer/IOAPIC.
- **M6 (Storage) complete:** virtio-blk sector reads, GPT partitions, a
  read-only ext2 with the thin file API.
- **M7 (Runtime) in progress:** wasm apps, multitasking, app isolation.

## Explore

- [Status](status.html) — what works right now.
- [Milestones](milestones.html) — M0–M10 roadmap.
- [Architecture](architecture.html) — design overview.
- [Development](development.html) — build, test, and verification.
- [Source code](https://github.com/Xelvra/aster-os) on GitHub.

---

Source: [`README.md`](https://github.com/Xelvra/aster-os/blob/main/README.md)
(Czech original lives in the spec, see
[`spec/`](https://github.com/Xelvra/aster-os/tree/main/spec)).
Synced: 2026-08-08.
