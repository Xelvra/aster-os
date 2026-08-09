---
layout: default
title: Development
nav_order: 5
source: spec/verification.md, spec/code-style.md
synced: 2026-08-09
---

# Development

## Code style

**Goal:** code that can be read in six months without context. Explicitness and small
modules over cleverness. The full style rules live in
[`spec/code-style.md`](https://github.com/Xelvra/aster-os/blob/main/spec/code-style.md);
the verification pipeline lives in
[`spec/verification.md`](https://github.com/Xelvra/aster-os/blob/main/spec/verification.md).

### 0. Language (code vs. documentation)

- **Code, comments, annotations, docstrings, identifiers and commit messages: English.**
  Code is a publicly shared artifact and English is its default language.
- **Public documentation (`README.md`): English** (the repo has been public since M0).
- **Internal specs (`spec/*.md`): Czech** (the author's second brain). Exceptions are
  established conventions — file/directory/service names, technical terms (framebuffer,
  syscall, Renderer, Runtime, ADR statuses etc.).
- A code comment explaining "why" is in English. Czech text does not belong in code.

### 1. Design principles

- **Prefer explicitness over implicitness.** No magic: no meta-models, background code
  generation, implicit conversions or hidden side effects.
- **Small modules, one responsibility.** A file does one clearly nameable thing. If a
  module's description needs "and", split it.
- **No singletons.** State is passed explicitly (struct instance), not shared globally.
- **No global mutable state unless it is hardware.** Exception: device registers,
  framebuffer memory, the atomic event queue — that is hardware/interrupt context, not a
  program-level global variable.
- **KISS + YAGNI.** The simplest solution that works. No abstraction "for future use" —
  see `spec/non-goals.md`.
- **DRY with reason.** Repeated logic is extracted; two things that will evolve
  independently are not artificially joined.

### 2. Contracts and visibility

- **Every public function has a contract.** A docstring (or an expressive name +
  documentation) states: input, output, errors, what may be called. See
  `spec/kernel-interface.md` for the KI.
- **Only what should be public is public.** Internal helpers are `pub` only when another
  module calls them; otherwise private. KI modules in `api/` are the only public surface.
- **No silent failure.** A function that can fail returns `KiStatus` / an error value. No
  empty `catch` without justification.

### 3. Memory

- **Alloc/free must be traceable.** The allocator is passed explicitly; ownership (who
  allocated, who frees) is visible from the signature. No hidden allocations in pure
  functions.
- **No allocation on critical paths** (IRQ, rendering, event loop render) — a
  Performance invariant, `spec/invariants.md`.
- **Prefer stack and static buffers** in the kernel and renderer.
- **Immutable where it makes sense** — `const`, immutable data as the default.

### 4. Structure and naming

- `snake_case` for functions and variables, `PascalCase` for types, `UPPER_SNAKE_CASE`
  for constants (Zig convention).
- No shadowing of built-in names (`list`, `id`, ...).
- Modules ordered by dependency: `api/*` on top (public), internal layers below.
- Comments explain "why", not "what". What the code does should be readable from the
  code itself.

### 5. Threads, IRQ, shared state

- IRQ handler: atomic operations on pre-allocated structures. No locks, no allocations,
  no recursion (a Safety invariant).
- Shared state between IRQ and the event loop only via a documented mechanism (ring queue).

### 6. Review checklist (code review)

Before approving any change:

- [ ] Code and comments are in English (documentation in Czech — see §0).
- [ ] File/function name matches one responsibility.
- [ ] No singleton / new global mutable state (except hardware).
- [ ] Public functions have a contract.
- [ ] Alloc/free are traceable from the signature.
- [ ] No allocation in IRQ / render / event loop render.
- [ ] No silent failure.
- [ ] No magic, no implicit conversion.
- [ ] `zig fmt --check` and `zig build test` passed (`spec/verification.md`).

---

## Verification pipeline (fail fast)

**Status:** V1 (draft). **Decisions:** ADR-013, ADR-014, ADR-016.
**Purpose:** project verification for Zig — fail fast, proven done, protection against
regression, deterministic build.

Steps run in exact order. On the first failure, stop, fix, and run the whole sequence
again from step 1.

### Step 0 — Baseline (before the first change)

```bash
zig build test
```

If the baseline fails before any change, we do not continue — the state is reported.

### Step 1 — Formatting

```bash
zig fmt --check .
```

No unformatted files.

### Step 2 — Compilation (release + debug)

```bash
zig build
```

The build must pass for the default configuration.

### Step 3 — Host unit tests

```bash
zig build test
```

All host unit tests (`tests/`) must be green. Host tests cover pure logic that can run
off the target hardware:
- PFA (alloc/free/fragmentation),
- heap allocator (coalescing, out-of-memory),
- framebuffer: `fillRect`/`blit`/`fillScreen` with clipping (edges, negative origins,
  fully outside), `pixelColor` encoding,
- renderer: `drawGlyph` (pixel-exact vs. the font), `drawText`,
  `roundRect` (center filled, corner clipped), `rectBorder` (outline without fill),
  `gradientBorder` (interpolation around the perimeter, monotonicity),
- font: fallback glyph, empty `space`,
- console: typing, wrap, backspace, scroll, clear,
- input: `KeyCode` → ASCII (lower/upper, digits, symbols, control → null),
- binding marshalling,
- ring event queue.

**Marshalling as a security boundary** (spec `runtime.md` §5): binding tests include
**negative/adversarial inputs** — wrong types, negative coordinates, overflowing buffer
lengths, codepoints outside the font — not just happy-path examples. Since M4 a fuzz
harness on Lua-side inputs is considered (the kernel runs in Ring 0; a wrong conversion
is as dangerous as a kernel bug). Lua binding marshalling is tested in QEMU runtime
tests since M4 (real `lua_State` + binding calls), because a host build of Lua would
duplicate the kernel configuration.

### Step 4 — QEMU smoke test

```bash
./tools/qemu-smoke.sh
```

Boot in QEMU with `-display none` + serial. The script:
1. starts QEMU with a timeout,
2. waits for the `ASTER BOOT OK` serial marker (or extended markers),
3. returns 0 when the marker is found, non-zero on timeout/error.

**This is the machine-checkable proof that "the system boots".** Without a green smoke
test the task is not done.

### Step 4b — Runtime tests in QEMU (M2+)

The smoke test only proves "it boots". Since M2 (IRQ/timer/PS2, where logic depends on
hardware) **runtime tests** are added — host tests are no longer enough:

- The kernel boots in QEMU with an **`isa-debug-exit`** device; tests run **inside the
  kernel** and **exit QEMU with a defined exit code** on success/failure.
  QEMU `debugexit` returns `(val << 1) | 1` — convention: **pass = 99** (the kernel
  writes `0x31`), **fail = 97** (the kernel writes `0x30`). The build step
  `expectExitCode(99)`; the script `tools/qemu-test.sh` checks for 99.
- Run via `zig build runtime-test -Druntime-tests=true` or `tools/qemu-test.sh`.
- Framework: a minimal runtime-test module with `expect` — no dependency on the host
  test runner. An error → print to serial + exit with the fail code (97).
- Tests are registered behind the normal code; stripped in production builds
  (compile-time flag `-Druntime-tests`, `comptime runtime_test.enabled`).
- **Idle watchdog:** if a test loops forever (infinite loop, deadlock), QEMU would
  otherwise run forever and end only on the script timeout (`QEMU_TEST_TIMEOUT`,
  default 30s). This separates "test failed" (97) from "test stuck" (timeout).
- **Scope:** things not host-testable by unit tests — PFA on real memory, IDT/fault
  policy, tick/timer, the input queue, later Lua bindings and the renderer (M4+).
- A milestone's DoD includes a green runtime test in addition to host tests and the
  smoke test.

> Decision for a future phase: the mechanism is implemented from M2, not earlier
> (M0–M1 only need the smoke test). The form is fixed now so `tools/` is not written
> twice.

---

## Definition of Done (DoD)

A task is done only when **everything** holds and the report includes real output:

- [ ] Step 0 (baseline) ran before the changes.
- [ ] `zig fmt --check .` — no changes.
- [ ] `zig build` — passes.
- [ ] `zig build test` — 100 % green.
- [ ] `./tools/qemu-smoke.sh` — the system boots (serial marker).
- [ ] Every new piece of logic has a test (host unit test) or a justification for why not.
- [ ] Invariants (`spec/invariants.md`) checked point by point.
- [ ] A quality metric recorded in `spec/roadmap.md`, if the milestone affects boot/RAM/size.
- [ ] At the end of every milestone an optimization pass ran (roadmap §4, rule 5):
      metrics vs. targets, benchmark before/after (`tools/bench.sh`, render throughput),
      results recorded in the table in `spec/roadmap.md`.
- [ ] **Documentation updated** — changed specs, ADRs or the roadmap are part of the same
      change; no feature without recorded documentation is done.
- [ ] No `TODO`, `FIXME` or commented-out block in the code.
- [ ] No `#noqa`/formatter workaround without justification.
- [ ] No existing test was modified/skipped without approval.
- [ ] A non-obvious bug solved during development is recorded in
      `spec/troubleshooting.md` (symptom → cause → solution → verification).
- [ ] **The system is bootable** (ADR-016).

---

## Deterministic (reproducible) build — ADR-014

**Goal:** same commit + same Zig version = same output binary hash.

### Mechanism

1. **Version pinning:** the `.zig-version` file at the root contains the exact version
   (now `0.16.0`). `build.zig` verifies the running Zig matches (warns/aborts otherwise).
2. **Toolchain pinning:** the official tarball in `/opt/zig` is recommended, not a
   distro package (pacman may lag and carry a different version).
3. **No timestamps:** the build does not embed the current time into the binary (no
   `__DATE__`/`__TIME__`, no generated timestamps). Versioning goes through the git hash
   (if needed).
4. **No generated data varying across runs:** fonts and assets are `@embedFile`d from
   static sources.
5. **Vendoring:** Limine, Lua, wasm3 — fixed revisions vendored in `libs/`, not pulled
   from the network at build time.

### Verification

```bash
./tools/verify-reproducible.sh   # build twice, compare hashes
```

Verification is **mandatory** (part of the DoD) — a non-obvious determinism violation
(e.g. an absolute cache path in `.debug_str`, see `spec/troubleshooting.md` D1) would
otherwise silently return. Checked on the production optimize (`ReleaseSafe`).

---

## Bootable commit — ADR-016

Rule: **every commit must leave the system runnable in QEMU.**

- Before every commit `./tools/qemu-smoke.sh` runs — at least on the main build.
- A broken boot is fixed immediately, never "in a few commits".
- Exceptions (documentation, purely host code outside the boot path) are marked explicitly.

> **Git hooks:** `./tools/install-hooks.sh` installs a pre-push hook that runs
> `./tools/capture-boot.sh --check` and `./tools/sync-docs.sh --check` before pushing —
> the boot log in the documentation (`boot-log.md`) must not go stale vs. the code, and
> the English website pages must not go stale vs. their Czech sources. Installing the
> hooks is recommended after a clone; CI verifies it too.
>
> **Known risk (recorded 2026-08-08):** the boot log as a CI gate is a **deliberate
> feature** (Boot proof of work), not a bug. It is only inconvenient when bypassing the
> hook (e.g. stash) or changing the environment/acceleration — the hook is not to be
> bypassed; the boot log is regenerated via `./tools/capture-boot.sh`. If the hook fails
> without bypass, that is a bug and is reported.

---

## Tools

| Tool | Purpose |
|---|---|
| `zig` | build, test, fmt (version in `.zig-version`) |
| `qemu-system-x86_64` | target emulation (BIOS + UEFI); KVM acceleration when available |
| `xorriso` / `mtools` | building the bootable ISO / FAT image for Limine |
| `tools/qemu-accel.sh` | echoes `-enable-kvm` when `/dev/kvm` is accessible (else TCG) |
| `tools/qemu-smoke.sh` | automated boot test (serial marker + timeout; auto KVM) |
| `tools/qemu-test.sh` | in-QEMU runtime tests (isa-debug-exit; auto KVM) |
| `tools/bench.sh` | measuring the metrics from `roadmap.md` |
| `tools/verify-reproducible.sh` | deterministic build check (ADR-014) |
| `tools/capture-boot.sh` | capture/check the boot log (Boot proof of work) |
| `tools/sync-docs.sh` | check the English site stays synced with the Czech spec |
| `tools/make-test-disk.sh` | build the deterministic GPT+ext2 test disk image |

## Prerequisites

- **Zig** — exact version from `.zig-version` (currently 0.16.0) — use the official
  tarball, not a distro package.
- **QEMU** (`qemu-system-x86_64`) — target emulation.
- **Limine** — vendored in `libs/limine/`, no system packages.
- **xorriso / mtools** — building the bootable ISO / disk image.
- **Lua 5.4.8** — vendored in `libs/lua-5.4/`.

### Dependency status

| Tool | Status | Note |
|---|---|---|
| `qemu-system-x86_64` | ✅ installed | |
| `clang`, `lld`, `gcc` | ✅ installed | |
| `zig` | ✅ installed (0.16.0) | install: official tarball / distro, see `.zig-version` |
| `xorriso` / `mtools` | ✅ installed | ISO build verified in M0 |
| `limine` | ✅ vendored | `libs/limine/` (12.5.2) |
| `lua 5.4.8` | ✅ vendored | `libs/lua-5.4/` |

## Quick start

```bash
zig build run          # boot in QEMU (auto KVM when /dev/kvm is available)
zig build run -Dkvm=false  # force TCG emulation
zig build test         # host unit tests
./tools/qemu-smoke.sh  # automated boot test (serial marker + timeout; auto KVM)
./tools/qemu-test.sh   # in-QEMU runtime tests (isa-debug-exit; auto KVM)
./tools/verify-reproducible.sh  # deterministic build check (ADR-014)
```

Storage runtime tests run inside QEMU with a deterministic test disk:

```bash
zig build iso -Druntime-tests=true         # kernel with in-QEMU runtime tests
./tools/make-test-disk.sh /tmp/test-disk.img  # deterministic GPT + ext2 image
QEMU_TEST_DISK=/tmp/test-disk.img ./tools/qemu-test.sh
```

Build modes: default is `ReleaseSafe` (the verified production mode);
`-Doptimize=ReleaseFast` trades safety checks for a smaller image;
`-Doptimize=Debug` for debugging. Lua C sources always compile with `-Os`.

See [`CONTRIBUTING.md`](https://github.com/Xelvra/aster-os/blob/main/CONTRIBUTING.md)
for the contribution workflow.

---

Last synced from [`spec/verification.md`](https://github.com/Xelvra/aster-os/blob/main/spec/verification.md) and [`spec/code-style.md`](https://github.com/Xelvra/aster-os/blob/main/spec/code-style.md) on **2026-08-09**.
