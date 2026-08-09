---
layout: default
title: Architecture
nav_order: 4
source: spec/architecture.md
synced: 2026-08-09
---

# Aster OS — Architecture Overview

**Version:** 1.1 (draft)
**Status:** Current design — approved for implementation (Milestones M0–M6)

> This document is the **main architectural overview** of the project. It captures the
> current design and its decisions. It serves as the reference point for design
> consultation and as the starting point for writing code.
>
> Individual decisions live as separate records in `spec/adr/`. Detailed sub-specs in
> `spec/*.md` (see the index below). This document is **an overview**: it is read in
> full; the sub-documents only on demand.
>
> **Two levels:** §3 describes the **Current architecture** (what is implemented in
> M0–M6, `src/`). §4 describes the **Target architecture** (M7+: Wasm runtime,
> per-program states, separation into Ring 3). The document does not present the
> target as done — where Current and Target differ, it is stated explicitly.

---

## 1. Summary

Aster is an experimental desktop operating system written in Zig. The first
implementation deliberately favors **simplicity over isolation**: the desktop, scripting
engine and runtime share a single address space to minimize complexity and maximize
iteration speed. The public interfaces are designed as **stable abstractions**, so
individual subsystems can later be moved into isolated processes **without changing
application APIs**.

The architecture is an **evolutionary SASOS** (Single Address Space, Ring 0): everything
runs in one address space, but over stable interfaces that enable later separation into
Ring 3.

**Target platform:** currently **x86_64** (QEMU `q35`) — the only implemented
architecture. A future port (e.g. ARM, RISC-V) is not excluded by design, but is not a
goal today and would require its own scope change (`spec/non-goals.md`).

**Main goals (KPIs):**

| Metric | Target |
|---|---|
| Kernel image size | < 512 KB (with Lua; see `roadmap.md` §2) |
| Kernel Entry → First Frame (from Limine handoff) | < 40 ms (target M4/M5; measured ≈ 90 ms in QEMU TCG — see `roadmap.md` note ³) |
| GUI memory (idle) | < 32 MB RAM |
| UI drawing | 0 syscalls, 0 framebuffer copies *(applies to the Ring 0 phase; from Ring 3 — M8+ — ring transitions are added, see `roadmap.md`; exception: the mouse cursor saves/restores 12×19 px under itself)* |
| Compilation | reproducible (see `spec/verification.md`) |

> Concrete per-milestone values live in `spec/roadmap.md` as ranges and targets, not
> falsely precise numbers — nobody knows exact numbers before the system runs.

---

## 2. Philosophy and Manifesto

### 2.1 Manifesto (current wording)

> **Aster is an experimental desktop operating system written in Zig.**
>
> The first implementation deliberately favors simplicity over isolation: the desktop,
> scripting engine and runtime share a single address space to minimize complexity and
> maximize iteration speed. The public interfaces are designed as stable abstractions, so
> individual subsystems can later be moved into isolated processes **without changing
> application APIs**.

The manifesto captures the project's current reason for existence and its current
trade-offs. All decisions described in this document and in `spec/adr/` must be
interpretable as consequences of the manifesto.

---

## 3. Architectural overview

### 3.1 Current architecture (M0–M6, implemented)

```text
Lua shell (desktop, vendored Lua 5.4)
   │  KI bindings → sys.dispatch()
   ▼
KERNEL INTERFACE (KI) — api/* (dispatch layer)
   │
   ├── graphics API ──→ renderer ──→ framebuffer (GOP/Limine)
   ├── input API ─────→ input/service ──→ queue ← PS/2 IRQ, APIC timer
   ├── runtime API ───→ lua (single embedded program)
   ├── timer API ─────→ time.zig (monotonic tick)
   ├── sysmon API ────→ mem.Memory.stats()
   ├── debug API ─────→ serial (privileged diagnostic sink)
   └── power API ─────→ i8042 reset

kernel/main.zig = the single privileged composition root
   │  (assembles mem, cpu/idt+apic, drivers, fs, renderer, cursor, lua)
   ▼
subsystems: mem/pfa+heap, cpu/idt+apic+time, drivers (ps2, virtio-blk),
            fs (gpt, ext2, file), render (renderer, font, mouse_cursor)
```

**The mouse cursor is a privileged graphics overlay**, not part of the Renderer or the
Input subsystem: `render/mouse_cursor.zig` saves/restores pixels and draws the sprite
directly into the framebuffer (12×19 px). The event loop applies mouse events to the
overlay and writes the resulting state into `input/service`; the service knows nothing
about the framebuffer. The framebuffer is an internal resource of the graphics
subsystem — ordinary drawing goes exclusively through the Renderer, the privileged
overlay through `mouse_cursor` (see `spec/graphics.md` §7).

**M6 storage:** `virtio-blk → Block Device API → GPT → ext2 → File API`. The File API is
an **ext2-specific adapter** (ADR-023 — backend abstraction only once a second backend
exists).

### 3.2 Target architecture (M7+, separation)

The interface described above stays; the content of the layers changes:

```text
Shell / UI (Lua)    Apps (Wasm — wasm3, M7)
   │                 │
   └───── KI ────────┘  (apps written for Aster call Aster bindings)
   ▼
Runtime (generic): per-program lua_State/Wasm → scheduler (ADR-017)
   ▼
Program lifecycle: spawn / kill / status (M7)
```

- **M7:** the Runtime stops being "one embedded Lua program" — `spawn()` creates
  per-program states, the scheduler preempts, `Program` is a schedulable execution
  context (until M6 it is a logical placeholder, `spec/runtime.md` §2).
- **M8+ (separation):** subsystems move behind the stable KI into Ring 3 (ADR-018); KI
  calls become IPC messages — **without changing the calling code**. Memory protection,
  syscalls and an MMU are added (no MMU in M0–M6).
- **Wasm is hosted behind the generic Runtime API** (ADR-011): the kernel accepts no
  Wasm-specific code, everything goes through `Runtime.spawn`.

### 3.3 Four pillars

1. **Evolutionary SASOS** — one address space, Ring 0, no MMU/syscall/IPC overhead.
   Lua, Wasm, UI = plain function calls.
2. **Stable seams from day one (KI)** — the interfaces do not know everything is in
   Ring 0. Tomorrow the direct calls become IPC messages **without changing the calling
   code**.
3. **No premature optimization** — the simplest thing that works. Measured after every
   milestone (see `spec/roadmap.md`).
4. **Bootable commit** — every commit must leave the system runnable in QEMU. No "it
   will be broken for the next three commits".

---

## 4. Decision protocol (ADR)

Each decision has a number, a verdict, a rationale and consequences. The full wording of
each ADR is a separate file in [`spec/adr/`](adr/README.md) — here is only the overview.
Written down so that later design consultation has the *why* available, not just the *what*.

| ADR | Decision | Status |
|-----|----------|--------|
| [001](adr/001-evolutionary-sasos.md) | Evolutionary architecture (SASOS → microkernel later) | Accepted |
| [002](adr/002-single-address-space-ring0.md) | Single Address Space, Ring 0 | Accepted |
| [003](adr/003-stable-interfaces-day-one.md) | Stable interfaces from day one | Accepted |
| [004](adr/004-kernel-interface-not-abi.md) | Kernel Interface (KI), not an ABI | Accepted |
| [005](adr/005-renderer-layer.md) | Renderer as a separate layer | Accepted |
| [006](adr/006-generic-runtime-api.md) | Generic Runtime API | Accepted |
| [007](adr/007-lua-5-4-vendored.md) | Lua 5.4 vendored, statically, not LuaJIT | Accepted |
| [008](adr/008-event-loop-not-mlfq.md) | Scheduler: event loop, not MLFQ | Accepted |
| [009](adr/009-minimal-rendering-primitives.md) | Minimal rendering primitives | Accepted |
| [010](adr/010-no-filesystem-yet.md) | No filesystem until needed | Accepted |
| [011](adr/011-wasm3-later.md) | wasm3 later, seam Runtime → Program | Accepted |
| [012](adr/012-limine-bootloader.md) | Limine bootloader | Accepted |
| [013](adr/013-zig-version-pinning.md) | Pinning Zig outside the project name (.zig-version) | Accepted |
| [014](adr/014-deterministic-build.md) | Deterministic build | Accepted |
| [015](adr/015-measure-every-milestone.md) | Measure after every milestone | Accepted |
| [016](adr/016-bootable-commit.md) | Bootable commit | Accepted |
| [017](adr/017-concurrency-model-m7.md) | Concurrency model M7 (preemptive RR, critical sections without locks) | Accepted |
| [018](adr/018-ring3-ki-transport.md) | KI transport in Ring 3: mailbox IPC, comptime dispatch, IRQ routing | Accepted |
| [019](adr/019-bootloader-gate.md) | Bootloader gate: kernel does not depend on bootloader types (BootInfo) | Accepted |
| [020](adr/020-future-extensibility.md) | Extensibility: new features as new KI modules appended | Accepted |
| [021](adr/021-extended-rendering-primitives.md) | Extended rendering primitives for UI (roundRect, border, gradient) | Accepted |
| [022](adr/022-network.md) | Network as KI module `net.*` — minimal stack (virtio-net, ARP/IPv4/ICMP/UDP), M9 | Accepted |
| [023](adr/023-filesystem-ext2-non-posix.md) | Persistence: ext2 backend (read-only), non-POSIX semantics, thin interface | Accepted |
| [024](adr/024-keyboard-layout-registry.md) | Multi-layout keyboard: KL registry + runtime switching (`input.set_layout`) | Accepted |

**ADR rules:** decisions are never edited after the fact — a change of mind is a new ADR
referring to the old one. Numbers are never renumbered or deleted.

---

## 5. Known risks

Acknowledged up front so they are not a later "discovery". Risks are managed, not ignored:

| Risk | Description | Mitigation |
|---|---|---|
| **Single address space** | A bug in native Zig code can corrupt anything (kernel, framebuffer, other modules). | Lua/Wasm run in a managed runtime; native code goes through invariants (`spec/invariants.md`) and review. |
| **Embedded Lua in the kernel** | The Lua VM runs with full privilege; a VM or binding bug = system crash. | Vendored stable version, minimal binding surface, host marshalling tests. |
| **No MMU isolation** | No hardware boundary between components. | Language isolation (Lua/Wasm); ADR-002; non-goal for now. |
| **No userspace drivers** | Drivers (PS/2, timer) run in the kernel; their bug = crash. | Small, controlled code; QEMU smoke test as a catch. |
| **No persistence before M6** | Cannot save config/editor until M6. | Deliberate non-goal (`spec/non-goals.md`); embedded assets compensate. |
| **Single core** | Single-core; SMP would be an overhaul of the scheduler and memory. | Non-goal (`spec/non-goals.md`); single-core architecture makes measurement possible. |
| **Docs heavier than code** | Planning overgrowth into infinity. | This document is an overview; details on demand; every measurable decision is verified in code. |

---

## 6. Terminology

| Term | Meaning |
|---|---|
| **SASOS** | Single Address Space Operating System — one address space, everything Ring 0. **A more radical variant of classic SASOS** (Opal, Nemesis etc.): academic systems had hardware protection between domains, Aster has none — protection is purely language-level (Lua/Wasm managed) and shared state is protected by forbidding preemption (ADR-017). |
| **KI** | Kernel Interface — the stable interface between the kernel and the rest of the system. The future basis of an ABI. |
| **Renderer** | The layer between the Graphics API and the Framebuffer; today `fillRect`/`blit`/`glyph`, tomorrow GPU/IPC. |
| **Runtime** | The layer responsible for spawning programs (`Runtime.spawn`), abstracting Lua/Wasm/Native. |
| **Program** | The result of `spawn()` — a handle to a running module. |
| **Event loop** | The main loop `poll() → update() → render()`. |
| **Embedded asset** | A resource (lua script, font) compiled into the binary. |

---

## 7. Repository structure

```
aster-os/
├── build.zig / build.zig.zon     # `zig build run` → QEMU, `zig build test` → host tests
├── .zig-version                  # exact toolchain version (0.16.0)
├── README.md                     # manifesto + link to .zig-version
├── spec/                         # THIS FILE + sub-specs
│   ├── README.md
│   ├── architecture.md           # this document
│   ├── manifest.md
│   ├── non-goals.md              # what the system deliberately does not do
│   ├── code-style.md             # code philosophy and rules
│   ├── adr/                      # architectural decisions (ADR-001..024)
│   ├── kernel-interface.md       # KI: sys.dispatch + interface modules
│   ├── graphics.md               # Graphics API → Renderer → Framebuffer
│   ├── desktop-ui.md             # desktop UI port (bar, launcher, windows, widgets)
│   ├── input.md                  # input events
│   ├── runtime.md                # Runtime.spawn + RuntimeKind
│   ├── timer.md                  # time: tick source (M2), KI timer, cooperative sleep
│   ├── memory.md                 # memory: PFA, heap allocator, lua_Alloc
│   ├── invariants.md             # Safety / Performance / Architecture
│   ├── roadmap.md                # M0–M8 + quality metrics
│   ├── verification.md           # verification pipeline + deterministic build
│   ├── debugging.md              # Debugging Survival Guide (GDB, serial dump)
│   ├── troubleshooting.md        # solved pitfalls and lessons (C1..C27, H1..H2)
│   ├── handoff.md                # procedure for unresolved problems
│   └── handoffs/                 # handoff documents (open/closed)
├── src/
│   ├── kernel/                   # boot, mem/pfa+heap, cpu/idt+timer, drivers/ps2,
│   │   │                         # fb/framebuffer, render/renderer+font+text, api/,
│   │   │                         # time.zig (monotonic tick), lua/ (Lua 5.4 binding +
│   │   │                         # ui/ shell modules), sys/
│   └── kernel/lua/ui/            # desktop shell in Lua: theme, wm, repl, launcher,
│                                 # input, main (concatenated into one chunk)
├── libs/
│   ├── limine/                   # vendored bootloader + headers
│   └── lua-5.4/                  # vendored Lua 5.4 source
├── tests/                        # host unit tests (PFA, font blit, binding marshalling)
├── tools/
│   ├── qemu-smoke.sh             # serial marker + timeout
│   └── bench.sh                  # metric measurement
└── images/                       # generated ISO / disk image
```

---

## 8. Specification index

| Document | Contents |
|---|---|
| `manifest.md` | Project philosophy — simplicity over isolation, evolvable interfaces. |
| `non-goals.md` | What the system deliberately does not do (POSIX, SMP, USB, networking, ...). |
| `code-style.md` | Code structure and module design rules (review checklist). |
| `adr/` | Architectural decisions (ADR-001..024), each in its own file. |
| `kernel-interface.md` | KI: sys.dispatch, syscall numbers, interface modules, versioning rules. |
| `graphics.md` | Graphics API / Renderer / Framebuffer — layers and allowed operations. |
| `desktop-ui.md` | Desktop UI — port of look/behavior from cachyos-hypr-noctalia, reimplemented (bar, launcher, windows, widgets). |
| `input.md` | Input events: PS/2 keyboard, queue, mapping to Lua. |
| `runtime.md` | Runtime.spawn, RuntimeKind, Runtime → Program binding, error containment. |
| `timer.md` | Time: tick source (M2), KI `timer`, cooperative sleep. |
| `memory.md` | Memory: PFA, general allocator, `lua_Alloc`, cache attributes. |
| `invariants.md` | Safety, performance and architecture invariants (review checklist). |
| `roadmap.md` | Milestones M0–M8 with "done" criteria + quality metrics table. |
| `verification.md` | Verification pipeline (Zig), deterministic build, bootable-commit rule. |
| `debugging.md` | Debugging Survival Guide — GDB+QEMU, reading the serial dump, IRQ rules. |
| `troubleshooting.md` | Solved pitfalls and lessons (Zig 0.16, Limine, heap, PS/2 mouse). |
| `handoff.md` | Formal procedure for unresolved problems + handoff list. |

---

Last synced from [`spec/architecture.md`](https://github.com/Xelvra/aster-os/blob/main/spec/architecture.md) on **2026-08-09**.
