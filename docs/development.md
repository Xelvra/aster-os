---
layout: default
title: Development
nav_order: 5
source: spec/verification.md, spec/code-style.md
synced: 2026-08-09
---

# Development

Aster requires the Zig version listed in
[`.zig-version`](https://github.com/Xelvra/aster-os/blob/main/.zig-version)
(currently 0.16.0) — use the official tarball, not a distro package.

## Prerequisites

- **Zig** — exact version from `.zig-version`.
- **QEMU** (`qemu-system-x86_64`) — target emulation.
- **Limine** — vendored in `libs/limine/`, no system packages.
- **xorriso / mtools** — building the bootable ISO / disk image.
- **Lua 5.4.8** — vendored in `libs/lua-5.4/`.

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

## Verification pipeline (fail fast)

Steps run in exact order; on the first failure, fix and restart from step 1:

1. `zig fmt --check .`
2. `zig build`
3. `zig build test` — host unit tests (PFA, heap, framebuffer clipping,
   renderer, font, console, input, binding marshalling).
4. `./tools/qemu-smoke.sh` — boot in QEMU, serial marker `ASTER BOOT OK`.
   *This is the machine-checkable proof that the system boots.*
5. `./tools/qemu-test.sh` — in-QEMU runtime tests via `isa-debug-exit`
   (pass = exit 99, fail = 97).
6. `./tools/verify-reproducible.sh` — build twice, compare hashes.

A task is "done" only when all of the above pass and the report includes the
real command output. Full Definition of Done:
[`spec/verification.md`](https://github.com/Xelvra/aster-os/blob/main/spec/verification.md).

## Rules

- **Bootable commit (ADR-016):** every commit must leave the system runnable
  in QEMU. A broken boot is fixed immediately.
- **Git hooks:** `./tools/install-hooks.sh` installs a pre-push hook that runs
  `./tools/capture-boot.sh --check` and `./tools/sync-docs.sh --check` — the
  boot log ([`boot-log.md`](https://github.com/Xelvra/aster-os/blob/main/boot-log.md))
  and the English website pages must never drift from the code/spec.
- **Deterministic build (ADR-014):** no timestamps, no generated data,
  vendored dependencies.

## Language policy

- Code, comments, identifiers, and commit messages: **English**.
- Internal specifications (`spec/*.md`): **Czech** by design — the author's
  working documentation. See the language policy in
  [`spec/README.md`](https://github.com/Xelvra/aster-os/blob/main/spec/README.md).
- Public documentation (`README.md`, this site): **English**.

See [`CONTRIBUTING.md`](https://github.com/Xelvra/aster-os/blob/main/CONTRIBUTING.md)
for the contribution workflow.

---

Last synced from [`spec/verification.md`](https://github.com/Xelvra/aster-os/blob/main/spec/verification.md) and [`spec/code-style.md`](https://github.com/Xelvra/aster-os/blob/main/spec/code-style.md) on 2026-08-09.
