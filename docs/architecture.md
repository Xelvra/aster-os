---
layout: default
title: Architecture
nav_order: 4
---

# Architecture

Aster is an **evolutionary SASOS** (Single Address Space Operating System):
everything runs in one address space in Ring 0, over stable interfaces that
make later isolation into Ring 3 possible without changing application APIs.
The first implementation deliberately favors **simplicity over isolation** —
no MMU boundaries between components; protection is language-level (Lua and,
later, Wasm managed runtimes) plus a no-preemption discipline for shared state.

The architecture spec is the **canonical source**:
[`spec/architecture.md`](https://github.com/Xelvra/aster-os/blob/main/spec/architecture.md)
(Czech). This page is a curated, English public overview.

## Four pillars

1. **Evolutionary SASOS** — one address space, Ring 0, no MMU/syscall/IPC
   overhead. Lua, Wasm, and the UI are plain function calls.
2. **Stable seams from day one (KI)** — the Kernel Interface does not know
   everything is in Ring 0. Tomorrow the direct calls become IPC messages
   *without changing the calling code*.
3. **No premature optimization** — the simplest thing that works; measured
   after every milestone.
4. **Bootable commit** — every commit must leave the system runnable in QEMU.

## Layers

```
APPLICATIONS (in-process)
  Shell / UI (Lua)         Apps (Wasm, native)
        |                       |
        +---- Runtime API ------+
        ▼
KERNEL INTERFACE (KI)
  Graphics API | Input API | Runtime API | Sys.Dispatch
        ▼           ▼            ▼            ▼
  Renderer     Event loop     Runtime        Sys
   (FB)        (PS/2)      (Lua / Wasm)     Core
```

- **Renderer** — layer between the Graphics API and the framebuffer; today
  `fillRect` / `blit` / glyph rendering, tomorrow GPU or IPC.
- **Runtime** — responsible for spawning programs (`Runtime.spawn`),
  abstracting Lua / Wasm / Native.
- **Event loop** — `poll() → update() → render()`.
- **KI (Kernel Interface)** — the stable boundary between the kernel and the
  rest of the system; the future basis of an ABI.

Key performance targets (per-milestone values in
[`spec/roadmap.md`](https://github.com/Xelvra/aster-os/blob/main/spec/roadmap.md)):

| Metric | Target |
|---|---|
| Kernel image | < 512 KB (with Lua) |
| Kernel Entry → First Frame | < 40 ms (KVM) |
| GUI memory (idle) | < 32 MB RAM |
| UI drawing | 0 syscalls, 0 framebuffer copies (Ring 0 phase) |
| Compilation | reproducible |

## Known risks (accepted)

- **Single address space:** a native Zig bug can corrupt anything. Mitigation:
  managed runtimes, invariants, review.
- **Embedded Lua in the kernel:** a VM or binding bug can crash the system.
  Mitigation: vendored stable version, minimal binding surface, marshalling tests.
- **No MMU isolation:** no hardware boundary between components. Mitigation:
  language isolation, ADR-002, deliberate non-goal for now.

## Decisions

All architectural decisions are recorded as ADRs — one file per decision in
[`spec/adr/`](https://github.com/Xelvra/aster-os/tree/main/spec/adr)
(23 accepted so far, including: SASOS evolution, single address space, stable
interfaces, KI not ABI, vendored Lua 5.4, Limine bootloader, deterministic
build, bootable commit, and the ext2 read-only filesystem backend). Decisions
are never edited after the fact — a change of mind is a new ADR.

---

Source: [`spec/architecture.md`](https://github.com/Xelvra/aster-os/blob/main/spec/architecture.md)
(Czech original).
Synced: 2026-08-08.
