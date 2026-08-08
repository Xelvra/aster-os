# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Full history up to 0.1.0-alpha.1 is archived in
[`docs/CHANGELOG-archive.md`](docs/CHANGELOG-archive.md).

## [Unreleased]

### Added

- **First-frame latency profiling**: measured the Kernel Entry → First Frame split
  (mem ~9 ms, ps2+apic ~2 ms, graphics ~4 ms, Lua createState ~27 ms, Lua load ~35 ms,
  first render ~23 ms). Finding: QEMU runs without KVM (pure TCG interpretation), so the
  Lua interpreter (createState + load of the 25 KB shell) dominates the boot time — an
  emulation artifact, not a kernel problem. Verified that allocations are not a
  bottleneck (1071 allocs / 157 KB during shell load). See the metric note ³ in
  `spec/roadmap.md`.
- **Live theme change runtime test**: changing `theme.*` fields from Lua and re-rendering
  stays healthy (M5 live transformation, `spec/runtime.md` §5a).
- **Session menu** (M5 close): the bar "Lock" placeholder is now a working menu —
  Lock (full-screen overlay, any key unlocks), Logout (`runtime.reload()` — fresh
  desktop), Reboot (`power.reboot()` — i8042 reset). New KI module `api/power.zig`
  (`Power = 7`), `RuntimeOp.reload = 3`, Lua bindings `runtime.reload()` and
  `power.reboot()`.
- **KVM acceleration**: `zig build run` auto-detects `/dev/kvm` and adds `-enable-kvm`
  (override with `-Dkvm=false` to force TCG, `-Dkvm=true` to force KVM);
  `tools/qemu-smoke.sh`, `tools/qemu-test.sh` and `tools/bench.sh` auto-add
  `-enable-kvm` via `tools/qemu-accel.sh` when `/dev/kvm` is available (TCG fallback
  otherwise). QEMU TCG is the quick-capture path; KVM is closer to real hardware.
- **Accelerator marker**: the boot log reports the accelerator (`[ OK ] accelerator kvm` /
  `tcg` / `hv`) via CPUID hypervisor leaf 0x40000000, vendor in EBX/ECX/EDX.
- **RAM idle marker**: the boot log's memory line shows `X MiB usable · Y MiB used` after
  the shell loads (PFA-managed memory: kernel image + heap + bitmap + stacks; the
  framebuffer is MMIO, not RAM) — closes the ADR-015 measurement gap.
- **M5 measurements under KVM** (recorded in `spec/roadmap.md` notes 4/5): Kernel Entry →
  First Frame ≈ 24 ms (vs 90 ms TCG), render throughput ≈ 32 renders/10 ticks (vs 3–4
  TCG), RAM idle ≈ 2 MiB. Confirms the < 40 ms target is reachable — TCG was the boot
  bottleneck.
- **Boot proof of work**: the serial boot sequence is a styled `[ OK ]` log — the
  `/-\STER OS` header, colored status lines (green OK / yellow warn / red fail), a memory
  summary and a "boot sequence complete" capstone separated by blank lines
  (`src/kernel/bootlog.zig`); boot markers (`ASTER KERNEL ENTRY` / `ASTER BOOT OK` /
  `ASTER FIRST FRAME`) preserved for the tools. `tools/capture-boot.sh` boots a real image,
  regenerates `docs/boot-log.md` with metadata (date, host, accelerator, commit) and
  `--check` verifies it never drifts (CI + pre-push hook, `tools/install-hooks.sh`).
  README shows the full log as plain text.
- **Roadmap M9/M10**: new milestones in `spec/roadmap.md` and README — M9 Ecosystem
  (network, audio, browser, WASI) and M10 Adoption (real hardware, installable image,
  docs, contributors); the "M9+" shorthand is now a proper M9 milestone everywhere.
- **ADR-022 — network as a KI module**: planned for M9 (`net.*` — virtio-net,
  ARP/IPv4/ICMP/UDP), with the Ring 0 remote-DoS safety brake resolved (parser that
  never faults on foreign input, off by default, fuzz tests); `non-goals.md` updated.
- **License transparency**: `LICENSE-THIRD-PARTY.md` now names
  [cachyos-hypr-noctalia](https://github.com/CachyOS/cachyos-hypr-noctalia) as the
  desktop inspiration (upstream has no license — we reimplement, not copy); sections
  alphabetized and trimmed to what is actually required.
- **initfs (M6)**: the shell modules (`ui/*.lua`) are packed into a tar and loaded as a
  Limine initrd module, read at runtime instead of `@embedFile`'d — Limine module
  request, `src/kernel/fs/tar.zig` parser, and the heap now grows to fit large
  allocations (a single contiguous block).

### Changed

### Fixed

- **Boot under KVM / real hardware (C28)**: Zig ReleaseSafe codegen for
  `asm volatile ("ldmxcsr %[v]")` with a `"m"` operand passed address-of-address,
  so `ldmxcsr` loaded a pointer instead of the value 0x1F80 → reserved MXCSR bits →
  #GP → triple fault before serial init. TCG does not validate reserved MXCSR bits,
  masking the bug. `write_mxcsr` now passes the address in a register and
  dereferences it explicitly (scratch-register pattern, `spec/troubleshooting.md` C28).

- **Live transformation**: the bar height was captured once at shell load (`bar_height`),
  so changing `theme.bar.height` at runtime desynced mouse hit-testing (launcher position,
  workspace capsules, drag clamp) from rendering. It is now read live from the theme
  everywhere (`input.lua`, `launcher.lua`).
- **Empty bar and missing window titles**: Lua `/` always yields a float, and the strict
  integer bindings reject floats, so every bar widget (launcher button, clock, workspace
  capsules, volume/session) and the window titles silently failed to draw. Switched the
  affected divisions to integer `//` (`wm.lua`).
- **Reload from within Lua was a use-after-free**: `runtime.reload()` from the session
  menu (Logout) closed the `lua_State` that was mid-call. Reload is now deferred — a
  trigger only sets a flag and the event loop performs it outside any Lua call frame
  (`api/runtime.zig` `requestReload`/`performReload`, runtime test "reload from Lua is
  deferred").

## [0.1.0-alpha.1] - 2026-08-08

First tagged version: an experimental desktop OS booting to a window manager in QEMU.

### Added

- **Boot (M0)**: deterministic, reproducible build (ADR-014); boots via Limine, prints
  `ASTER BOOT OK`; `zig build`/`iso`/`run`/`test` targets.
- **Memory (M1)**: bitmap Page Frame Allocator + first-fit heap allocator, both with
  host unit tests; WC framebuffer cache verified.
- **CPU (M2)**: GDT/IDT (256 ISR stubs), fault policy + freestanding backtrace, local
  APIC timer (1 kHz), IOAPIC routing, PS/2 keyboard with hardware-neutral `KeyCode`
  input subsystem; in-QEMU runtime tests via `isa-debug-exit`.
- **Graphics (M3)**: Limine GOP framebuffer, renderer (`drawRect`/`blit`/`fillScreen`/
  `drawGlyph`/`drawText`) with clipping, embedded VGA 8×16 font, Graphics API in KI
  dispatch, event loop `poll → update → render`.
- **Lua (M4)**: Lua 5.4.8 vendored into the kernel (freestanding libc shim), generic
  runtime API (`spawn`/`reload`), interactive REPL, `gfx.*`/`input`/`time` bindings,
  hot reload (F5). Kernel 336 KiB (ReleaseFast 259 KiB).
- **Desktop shell (M5)**: tiling window manager in Lua (`src/kernel/lua/ui/` modules)
  with a Noctalia-style bar, workspace capsules, working launcher with search, float +
  drag, fullscreen, togglesplit, Super key and Hyprland-standard keybindings; PS/2
  mouse with kernel cursor overlay; error containment (a script error hot-reloads the
  shell instead of crashing the kernel); sysmon KI module exposing live RAM; new
  graphics primitives `round_rect`/`rect_border`/`gradient_border` (frozen KI ops 7–9).
  Kernel 366 KiB, Kernel Entry → First Frame ≈ 90 ms.
- 53 host tests + in-QEMU runtime tests (timer, mouse, cursor, framebuffer, Lua
  bindings, error containment, render throughput).

### Fixed

- Heap allocator coalescing bug causing #6 invalid opcode after ~150 Lua allocations
  (C17).
- Debug build (`zig build -Doptimize=Debug`) rejected `(%[reg])` memory operands —
  Zig 0.16 mode inconsistency, worked around via a scratch register (C27, handoff H2).
