---
layout: default
title: Status
nav_order: 2
source: README.md, CHANGELOG.md
synced: 2026-08-09
---

# Status

- **M7 (Runtime) — in progress:** wasm apps, multitasking, app isolation.
  Multi-layout keyboard is done (ADR-024, US/CZ switchable at runtime).
- **M0–M6 complete:** boot → memory → CPU → graphics → Lua runtime → desktop shell in
  Lua → disk storage (virtio-blk, GPT, read-only ext2).
- **Bootable-commit rule:** every commit must leave the system runnable in QEMU
  ([`spec/verification.md`](spec/verification.md)).
- **Feature history:** per-milestone details (Added/Fixed) in
  [`CHANGELOG.md`](CHANGELOG.md); metrics in [`spec/roadmap.md`](spec/roadmap.md).
- This is an alpha prototype, not a usable OS yet.

## Milestone metrics

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

The complete per-milestone feature history is in
[`CHANGELOG.md`](https://github.com/Xelvra/aster-os/blob/main/CHANGELOG.md)
(one version per milestone, e.g. `0.6.0` = M6 Storage). Full detail for each
milestone: [`spec/roadmap.md`](https://github.com/Xelvra/aster-os/blob/main/spec/roadmap.md).

---

Last synced from [`README.md`](https://github.com/Xelvra/aster-os/blob/main/README.md) and [`CHANGELOG.md`](https://github.com/Xelvra/aster-os/blob/main/CHANGELOG.md) on **2026-08-09**.
