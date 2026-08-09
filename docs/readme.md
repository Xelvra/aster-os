---
layout: default
title: README
nav_order: 2
source: README.md
synced: 2026-08-09
---

# Aster OS

[![status](https://img.shields.io/badge/status-alpha-orange.svg)](https://github.com/Xelvra/aster-os/blob/main/spec/roadmap.md)
[![version](https://img.shields.io/badge/version-0.7.0--alpha.1-orange.svg)](https://github.com/Xelvra/aster-os/blob/main/.version)
[![milestone](https://img.shields.io/badge/milestone-M7%20Runtime-informational.svg)](https://github.com/Xelvra/aster-os/blob/main/spec/roadmap.md)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d.svg)](https://github.com/Xelvra/aster-os/blob/main/.zig-version)
[![architecture](https://img.shields.io/badge/arch-x86__64-blue.svg)](https://github.com/Xelvra/aster-os/blob/main/spec/architecture.md)
[![bootloader](https://img.shields.io/badge/bootloader-Limine-808080.svg)](https://github.com/Xelvra/aster-os/tree/main/libs/limine)
[![Lua](https://img.shields.io/badge/Lua-5.4.8-2C2D72.svg)](https://github.com/Xelvra/aster-os/tree/main/libs/lua-5.4)
[![license](https://img.shields.io/badge/license-MIT-green.svg)](https://github.com/Xelvra/aster-os/blob/main/LICENSE)

> **Aster is an experimental desktop operating system written in Zig.**
>
> Aster currently targets **x86_64** (QEMU `q35`) — the only implemented architecture for
> now. A future port (e.g. ARM, RISC-V) is not excluded by design, but it is not a goal
> today and would need its own scope change (see [`spec/non-goals.md`](https://github.com/Xelvra/aster-os/blob/main/spec/non-goals.md)).
> The first implementation deliberately favors **simplicity over isolation**: the desktop,
> scripting engine, and runtime share a single address space to minimize complexity and
> maximize iteration speed. The public interfaces are designed as **stable abstractions**,
> so individual subsystems can later be moved into isolated processes **without changing
> application APIs**.

> Full manifesto (including what Aster is NOT and accepted trade-offs):
> [`spec/manifest.md`](https://github.com/Xelvra/aster-os/blob/main/spec/manifest.md).

## Status

- **M7 (Runtime) — in progress:** wasm apps, multitasking, app isolation.
  Multi-layout keyboard is done (ADR-024, US/CZ switchable at runtime).
- **M0–M6 complete:** boot → memory → CPU → graphics → Lua runtime → desktop shell in
  Lua → disk storage (virtio-blk, GPT, read-only ext2).
- **Bootable-commit rule:** every commit must leave the system runnable in QEMU
  ([`spec/verification.md`](https://github.com/Xelvra/aster-os/blob/main/spec/verification.md)).
- **Feature history:** per-milestone details (Added/Fixed) in
  [`CHANGELOG.md`](https://github.com/Xelvra/aster-os/blob/main/CHANGELOG.md); metrics in [`spec/roadmap.md`](https://github.com/Xelvra/aster-os/blob/main/spec/roadmap.md).
- This is an alpha prototype, not a usable OS yet.

### Milestone metrics

| M | Milestone | Kernel | First Frame |
|---|-----------|-------:|------------:|
| M0 | Boot      | 12 KB  | ≈ 0.3 s |
| M1 | Memory    | 17 KB  | ≈ 0.4 s |
| M2 | CPU       | 29 KB  | ≈ 0.5 s |
| M3 | Graphics  | 34 KB  | ≈ 0.6 s |
| M4 | Lua       | 336 KiB | ≈ 60 ms |
| M5 | UI        | 371 KiB | ≈ 24 ms |
| M6 | Storage   | 362 KiB | ≈ 26 ms |

Boot times from `tools/bench.sh` — M0–M3 wall-clock incl. the bootloader,
M4+ kernel-only on KVM.

## Quick start

```bash
zig build run          # boot in QEMU (auto KVM when /dev/kvm is available)
zig build run -Dkvm=false  # force TCG emulation
zig build test         # host unit tests
```

Verification tools (see [`spec/verification.md`](https://github.com/Xelvra/aster-os/blob/main/spec/verification.md)):

```bash
./tools/qemu-smoke.sh  # automated boot test (serial marker + timeout; auto KVM)
./tools/qemu-test.sh   # in-QEMU runtime tests (isa-debug-exit; auto KVM)
./tools/verify-reproducible.sh  # deterministic build check (ADR-014)
```

Build modes (default is `ReleaseSafe`, the verified production mode):
`zig build -Doptimize=ReleaseFast` trades safety checks for ~20 % smaller
image and faster execution; `-Doptimize=Debug` for debugging. The Lua C
sources are always compiled with `-Os` regardless of the mode.

## Prerequisites

- **Zig** — exact version in [`.zig-version`](https://github.com/Xelvra/aster-os/blob/main/.zig-version) (0.16.0), not a distro package.
- **QEMU** (`qemu-system-x86_64`) — target emulation.
- **Build tools:** xorriso / mtools; Limine and Lua 5.4.8 are vendored in `libs/`.

Full tool table and dependency status: [`spec/verification.md`](https://github.com/Xelvra/aster-os/blob/main/spec/verification.md) §6.

## Architecture at a glance

```
BIOS/UEFI → Limine → Zig kernel (Ring 0) → KI (api/*) → Lua shell / Wasm apps
```

The kernel, KI, runtimes, and the full diagram live in
[`spec/architecture.md`](https://github.com/Xelvra/aster-os/blob/main/spec/architecture.md) §3.

## Boot proof of work

Booting is the work, the log is the proof. The always-current boot log (with
date, host, accelerator and commit metadata) lives in
[`boot-log.md`](https://github.com/Xelvra/aster-os/blob/main/boot-log.md), regenerated by `tools/capture-boot.sh`; a
pre-push hook and CI verify it never drifts from the code
(`./tools/capture-boot.sh --check`).

## Documentation

- **Internal specification:** the complete architecture spec lives in
  [`spec/`](https://github.com/Xelvra/aster-os/blob/main/spec/README.md). Start with the [architecture overview](https://github.com/Xelvra/aster-os/blob/main/spec/architecture.md).
- The English website (published from `docs/`) is a machine translation of these
  Czech sources; see the two-layer strategy in [`spec/README.md`](https://github.com/Xelvra/aster-os/blob/main/spec/README.md).

The internal specs are written in Czech by design — this is the author's working
documentation, not marketing; see the language policy in
[`spec/README.md`](https://github.com/Xelvra/aster-os/blob/main/spec/README.md). For any nuance, the Czech spec is canonical.

If the system crashes or hangs: [`spec/debugging.md`](https://github.com/Xelvra/aster-os/blob/main/spec/debugging.md)
(Debugging Survival Guide) and [`spec/troubleshooting.md`](https://github.com/Xelvra/aster-os/blob/main/spec/troubleshooting.md)
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
| M6 ✅ | Storage: initfs, virtio-blk, GPT, filesystem, cooperative reads |
| M7 🔄 | Runtime: wasm apps, multitasking, app isolation |
| M8 ⏳ | Stabilization: invariant audit, metrics, Ring 3 decision |
| M9 ⏳ | Ecosystem: network, audio, browser, WASI |
| M10 ⏳ | Adoption: real hardware, installable image, docs, contributors |

Details in [`spec/roadmap.md`](https://github.com/Xelvra/aster-os/blob/main/spec/roadmap.md).

## License

MIT — see [LICENSE](https://github.com/Xelvra/aster-os/blob/main/LICENSE).

---

Last synced from [`README.md`](https://github.com/Xelvra/aster-os/blob/main/README.md) on **2026-08-09**.
