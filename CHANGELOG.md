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

### Architecture note — WASI as a future compatibility layer

- Clarified Wasm has two roles: native Aster bindings (M7) and a future **WASI layer**
  (M9+) for third-party Wasm applications. WASI lives in the runtime (over wasm3), not
  the kernel — it maps WASI syscalls to KI calls, keeping the "no POSIX in kernel"
  non-goal intact (`runtime.md` §7.1, `non-goals.md`, ADR-020).

### Milestone M2 — CPU (WIP, not committed)

- GDT/IDT setup (`src/kernel/cpu/idt.zig`, `isr.s`): 256 uniform ISR stubs (9 B each via
  `.byte 0x6a`), exception/fault policy, `lidt` via `[10]u8` descriptor buffer.
- PIC 8259 remap to vectors 0x20–0x2F (legacy fallback; active ISA IRQs run over IOAPIC).
- Local APIC timer (`src/kernel/cpu/apic.zig`): 1 kHz periodic tick, LAPIC EOI, MMIO
  mapping via PFA-backed `page_map`. SVR initialized explicitly (APIC enable + spurious
  vector 0xFF); spurious interrupt handled as silent no-op without EOI (IDT vector 0xFF).
- IOAPIC: maps 0xFEC00000 and programs redirection entry for IRQ1 (keyboard) to vector
  0x21 — required for ISA IRQ delivery while the APIC is enabled.
- **Input subsystem** (`src/kernel/input.zig`): hardware-neutral `KeyCode` enum +
  `KeyEvent` (code + pressed). Driver/PS/2 is only a producer; KI and applications never
  see scancodes. USB HID can later map usage → same `KeyCode` without touching KI.
- PS/2 keyboard (`src/kernel/drivers/ps2.zig`): i8042 config (IRQ1 enable + translation),
  enable scanning, scancode set-1 → `KeyCode` map, push `KeyEvent` into `input_queue`.
- Event loop prints tick counter and key events; verified in QEMU via `sendkey`
  (`key a down/up`, `key enter down/up`).
- **Fault policy + freestanding backtrace** (`src/kernel/cpu/idt.zig`): `ASTER FAULT`
  dump (vec, err, rip, cr2, rbp) + frame-pointer backtrace; no `std.fmt` in fault
  context (recursive fault, see troubleshooting C12).
- **Dispatch layer** (`src/kernel/api/sys.zig`): KI enumeration (`Syscall`), `KiStatus`,
  `Debug.write` via pointer args; self-test at boot.
- **Runtime tests in QEMU** (`src/kernel/runtime_test.zig`, `tools/qemu-test.sh`,
  `zig build runtime-test -Druntime-tests=true`): in-kernel tests exit QEMU via
  `isa-debug-exit` (pass = write 0x31 → exit 99, fail = 0x30 → exit 97); first test:
  APIC timer ticks through the event queue.
- Removed `link_gc_sections = false`: it bloated the kernel ~7× (196 KB → 28.8 KB) by
  disabling DCE over `std`; ISR stubs survive because `idt.zig` references them via
  `@extern` (troubleshooting C6).
- `spec/troubleshooting.md`: new section 6 with IDT/APIC/IOAPIC/PS/2 lessons (C1–C13);
  `spec/input.md` updated with driver/subsystem/KI layering.
- Kernel image 28.8 KB (target < 96 KB).
