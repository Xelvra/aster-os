# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Project initialization with Zig 0.16.0 pinned in `.zig-version` (ADR-013).
- Full architecture specification in `spec/`:
  - Architecture overview, manifest, non-goals, coding style, invariants.
  - Kernel Interface (KI) with frozen operation numbers (ADR-003, ADR-004).
  - Subsystem specs: graphics, input, timer, memory, runtime.
  - Milestone roadmap M0–M8 with quality metrics (ADR-015).
  - Verification pipeline and bootable-commit rule (ADR-016).
  - Debugging Survival Guide.
- Architecture Decision Records ADR-001..ADR-020:
  - Evolutionary SASOS, single address space Ring 0, stable interfaces.
  - Renderer layer, generic runtime API, Lua 5.4 vendored, event loop.
  - Minimal rendering primitives, no filesystem yet, wasm3 later, Limine.
  - Zig version pinning, deterministic build, measure every milestone.
  - Bootable commit, concurrency model M7, Ring 3 KI transport.
  - Bootloader gate, future extensibility (new KI modules).

### Milestone M0 — Boot

- `build.zig`: `zig build` produces a bootable ISO, `zig build run` boots it in QEMU,
  `zig build iso` assembles the Limine ISO, `zig build test` runs host tests.
- Kernel boots from Limine (long mode, serial, GOP framebuffer), prints `ASTER BOOT OK`.
- Boot handoff translated to kernel-owned `BootInfo` (ADR-019).
- Vendored toolchain: Limine 12.5.2 (binaries + protocol header + host tool),
  Lua 5.4.8 source.
- `tools/qemu-smoke.sh` (serial marker + timeout, fast FIFO exit) and
  `tools/bench.sh` (measurement of boot time and image size).
- Deterministic build verified: same commit + same Zig = identical kernel hash
  (ADR-014). Kernel image 12.0 KB (target < 64 KB).

### Project setup

- MIT license (LICENSE).
- English README for public repo (early deviation from the M4+ language plan, documented
  in `spec/README.md`).
- `spec/troubleshooting.md`: known pitfalls and lessons (Zig 0.16 API, Limine protocol,
  determinism, tooling); mandatory DoD entry in `spec/verification.md`.
- `tools/verify-reproducible.sh`: deterministic build check (ADR-014), mandatory in DoD.

### Milestone M1 — Memory

- Limine memory map parsing into `BootInfo` (usable/reserved regions, RAM filter for MMIO).
- Bitmap Page Frame Allocator (`src/kernel/mem/pfa.zig`): 4 KiB pages, 1 bit per page,
  deterministic first-free allocation, zeroing on request, OOM as error (never panic).
- First-fit heap allocator (`src/kernel/mem/heap.zig`): boundary tags, coalescing,
  dynamic growth from PFA, implements `std.mem.Allocator`.
- Host unit tests for PFA and heap: alloc/free, reuse, fragmentation, OOM, coalescing,
  realloc (16 tests).
- Boot prints RAM layout (usable bytes, free pages) and heap alloc self-test.
- Framebuffer cache attribute verified from PTE + PAT MSR (`cache_attr.zig`):
  Limine maps the framebuffer as **WC** (no M3 frame latency risk).
- Kernel image 17.4 KB (target < 80 KB).
