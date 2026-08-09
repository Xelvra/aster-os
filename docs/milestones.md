---
layout: default
title: Milestones
nav_order: 3
source: spec/roadmap.md
synced: 2026-08-09
---

# Roadmap — Milestones and Quality

**Status:** V1 (draft). **Decisions:** ADR-015, ADR-016.

---

## 1. Two tracking levels

The project is governed by **two independent sequences**:

### 1.1 Milestones (functionality)

```
M0 Boot → M1 Memory → M2 CPU → M3 Graphics → M4 Lua
        → M5 UI → M6 Storage → M7 Runtime → M8 Stabilization
        → M9 Ecosystem → M10 Adoption
```

### 1.2 Quality metrics (must be tracked at EVERY milestone)

```
Kernel Entry → First Frame   (primary boot metric, reproducible)
Firmware → First Frame       (tracked, depends on emulation/firmware)
render throughput            (Lua renders per tick window, runtime test — M4)
frame latency (p99)
binary size
RAM usage
compile time
```

Rule: **no new feature is considered done until its value is measured and written
into the table below.** If a new feature grew the binary by >40 % or doubled frame
latency without justification, optimization must take priority over more functionality.

---

## 2. Quality metrics table

> Target values. Real values are filled in after each milestone is completed.
>
> Numbers in the table are **ranges and targets, not estimates with false precision.**
> Nobody knows the exact kernel size until it runs — values come from measurement, not
> prediction.

| Milestone | Kernel image | RAM (idle) | Kernel Entry → First Frame | Frame latency (p99) | Compile time |
|--------|-------------:|-----------:|---------------------------:|--------------------:|-------------:|
| **Target** | < 256 KB | < 32 MB | < 50 ms | < 16 ms | TBD |
| **M0 (measured)** | **12.0 KB** | — | **≈ 0.3 s**¹ | — | TBD |
| M0 (target) | < 64 KB | — | < 10 ms | — | TBD |
| **M1 (measured)** | **17.4 KB** | — | **≈ 0.4 s**¹ | — | TBD |
| M1 (target) | < 80 KB | ≤ 4 MB | < 15 ms | — | TBD |
| **M2 (measured)** | **28.8 KB** | — | **≈ 0.5 s**¹ | — | TBD |
| M2 (target) | < 96 KB | ≤ 4 MB | < 20 ms | — | TBD |
| **M3 (measured)** | **33.8 KB** | — | **≈ 0.6 s**¹ | — | TBD |
| M3 (target) | < 128 KB | ≤ 6 MB | < 25 ms | < 16 ms | TBD |
| **M4 (measured)** | **336 KiB** (RF 259) | — | **≈ 60 ms**² | TBD | TBD |
| M4 (target) | < 512 KB (with Lua) | ≤ 12 MB | < 40 ms | < 16 ms | TBD |
| **M5 (measured)** | **371 KiB** | **2 MiB**⁴ | **≈ 90 ms**² (TCG) / **≈ 24 ms**⁵ (KVM) | TBD | TBD |
| M5 (target) | < 512 KB | ≤ 16 MB | < 40 ms | < 16 ms | TBD |
| **M6 (measured)** | **362 KiB** | **2 MiB**⁴ | **≈ 26 ms**⁶ (KVM) | TBD | TBD |
| M6 (target) | < 768 KB | ≤ 24 MB | < 50 ms | < 16 ms | TBD |
| M7 | < 1 MB | ≤ 32 MB | < 50 ms | < 16 ms | TBD |
| M8 | TBD | TBD | TBD | TBD | TBD |
| M9 | TBD | TBD | TBD | TBD | TBD |
| M10 | TBD | TBD | TBD | TBD | TBD |

**Definitions:**
- **Kernel Entry → First Frame:** time from the Limine handoff (entry into our code) to
  the first rendered frame. **This is the primary, reproducibly measurable metric** —
  firmware and RAM initialization are outside our control.
- **Firmware → First Frame:** the whole time from QEMU power-on (BIOS/UEFI) to the first
  frame. Measurable, but depends on emulation/firmware — tracked, not targeted.
- **Frame latency (p99):** the 99th percentile of the distribution of time between
  `render()` and `present()`. Latency matters more than FPS.
- **RAM (idle):** resident memory of the system with no applications running.
  > ⁴ M5: **≈ 2 MiB** (PFA-managed: kernel image + heap + bitmap + stacks; the
  > framebuffer is MMIO, not RAM). The kernel reports it in the boot log (line
  > `[ OK ] memory`); ADR-015 satisfied.

> ¹ M0–M3 measured `tools/bench.sh` **wall-clock** from QEMU start to the serial marker —
> including firmware/BIOS/Limine init that is outside kernel control (≈ 3 s bootloader
> delay). Values are **estimates after subtracting ≈ 3 s** — original measurements were
> 3.3 / 3.4 / 3.5 / 3.6 s wall-clock; the phases are done and cannot be re-measured
> cleanly, so this is an approximation.
> ² From M4 `tools/bench.sh` measures separately **Firmware → First Frame** (includes
> ~3.3 s BIOS + Limine) and **Kernel Entry → First Frame** (clean time of our code, marker
> `ASTER KERNEL ENTRY` at the entry after the Limine handoff → marker `ASTER FIRST FRAME`).
> Kernel image is the size of the stripped ELF (`zig-out/bin/aster`). **RF** = `ReleaseFast`
> build (`zig build -Doptimize=ReleaseFast`) — without safety checks, smaller and faster;
> production and verification run on `ReleaseSafe` (safety checks caught real bugs C2/C17).
> The Lua C code is compiled with `-Os` (saves ~40 KB vs. default without `-O`).
> ³ M5 breakdown of Kernel Entry → First Frame (measured 2026-08-08): mem ≈ 9 ms,
> ps2+apic ≈ 2 ms, graphics ≈ 4 ms, **Lua createState ≈ 27 ms**, **Lua load (parse of the
> 25 KB shell) ≈ 35 ms**, first render (WM) ≈ 23 ms. QEMU runs **without KVM** (pure TCG
> interpretation), so Lua interpretation is dominant — **the target < 40 ms is
> unreachable in QEMU TCG because of the emulated Lua interpretation, not because of our
> code**. On real hardware the boot would fit the target (the Lua parser and
> `lua_newstate` run natively → microseconds; allocations are not a bottleneck, ~1071
> allocs / 157 KB). **Once the OS is fully done, this metric is measured on real
> hardware.**
> **KVM path (2026-08-08):** for interactive work and testing WM/mouse, KVM is used
> (`zig build run` auto-adds `-enable-kvm` when `/dev/kvm` is accessible; `-Dkvm=false`
> forces TCG, `-Dkvm=true` forces KVM; tools auto-add it via `tools/qemu-accel.sh`).
> KVM is closer to real hardware (TCG masks bugs, e.g. C28). TCG remains the fast catch
> for automated tests.
> ⁵ **M5 KVM measurement (2026-08-08, `tools/bench.sh` + runtime test):** Kernel Entry →
> First Frame **≈ 20–24 ms** (the target < 40 ms is reachable under KVM — confirmed that
> TCG was the bottleneck), render throughput **≈ 32 renders/10 ticks** (vs 3–4 in TCG →
> TCG ~8–10× slower), RAM idle ≈ 2 MiB (note ⁴), kernel image 371 KiB.
> **Render throughput** (M4): `testRenderThroughput` in the runtime tests measures full
> Lua renders per 10 APIC ticks. Baseline after the renderer optimization: **8–9
> renders/10 ticks** (before: 5). **The value depends on the render load:** 8–9 applies
> to the M4 shell (REPL console), the M5 full-shell render (whole WM) measures **≈ 3–4
> renders/10 ticks** (TCG variable, re-measured 2026-08-08). The drop 8–9 → 3–4 is the
> load (the WM draws the whole desktop), not a render-pipeline regression. **Under KVM
> (note ⁵) the M5 full-shell measures ≈ 32 renders/10 ticks.** When the render pipeline
> changes, the number must not get worse **at the same load** without justification.
> ⁶ **M6 measurement (2026-08-09, `tools/bench.sh`, KVM):** Kernel Entry → First Frame
> **≈ 26 ms** (target < 50 ms ✓), kernel image **362 KiB** (370 840 B, target < 768 KB ✓),
> RAM idle ≈ 2 MiB (note ⁴, target ≤ 24 MB ✓). **M6 optimization pass (rule 5):**
> metrics hold the targets without changes (image 371 → 362 KiB from dead-code removal),
> no optimization was needed; frame latency p99 still has no measuring mechanism (TBD).
> Firmware → First Frame ≈ 3.3 s (BIOS + Limine, outside our code).

---

## 3. Milestones — detail

### M0 — Boot

**Goal:** deterministic, reproducible build; QEMU boots; serial marker.

- [x] Toolchain: Zig **0.16.0** (`.zig-version`), Limine vendored, Lua 5.4.8 vendored (source).
- [x] `build.zig`: `zig build` → bootable ISO/disk image; `zig build run` → QEMU.
- [x] `zig build test` → host unit tests (empty suite prepared).
- [x] Boot handoff from Limine (long mode, serial, GOP framebuffer init).
- [x] Serial output of the `ASTER BOOT OK` marker (caught by `tools/qemu-smoke.sh`).
- [x] `tools/qemu-smoke.sh`: serial marker + timeout; `tools/bench.sh` skeleton.
- [x] **Deterministic build:** same commit + same Zig = same binary hash.
- [x] Filling the first row of the metrics table.

**Definition of Done (DoD):** QEMU boots with the marker on stdout, host tests green,
`zig fmt --check` clean, metrics recorded, commit bootable.

### M1 — Memory

**Goal:** physical memory manager.

- [x] Parsing the Limine memory map (RAM boundaries, reserved regions).
- [x] **Bitmap Page Frame Allocator** (`src/kernel/mem/pfa.zig`).
- [x] **General heap allocator** on top of PFA (`src/kernel/mem/heap.zig`, first-fit free
      list, also serves as `lua_Alloc`) — spec `spec/memory.md`.
- [x] Host unit tests for both PFA and the heap allocator: alloc/free, fragmentation,
      out-of-memory, coalescing.
- [x] **Verification of the framebuffer cache attribute** (UC vs WC) from the Limine
      mapping — see `spec/memory.md` §6; if UC, record it as a risk for M3 frame latency.
- [x] RAM layout printed to serial at boot.
- [x] Metrics into the table.

**DoD:** PFA + heap work and are covered by tests; serial prints the RAM layout; bootable commit.

> **Deferred (YAGNI):** buddy allocator, VMM, per-process address spaces. Paging stays
> static from Limine (flat mapping). VMM comes only with the separation phase (Ring 3).
> Exception: **only the framebuffer region** may be switched to WC via PAT in M3 without a
> full VMM (`spec/memory.md` §6).

### M2 — CPU

**Goal:** interrupts, timer, input.

- [x] GDT (as needed), **IDT** with all entries, correct segment setup.
- [x] **Local APIC timer** as the tick source (MSR `IA32_APIC_BASE`, LVT) + correct
      remap of the legacy 8259 PIC. **I/O APIC**: to deliver ISA IRQs in APIC mode the
      redirection table must be programmed (IRQ1 → vector 0x21, BSP); **no ACPI MADT
      parsing** — the IOAPIC address (0xFEC00000) is hardcoded for QEMU. Debt to M7
      (SMP): MADT (RSDP → RSDT/XSDT → MADT) for real LAPIC IDs, ISA IRQ→GSI overrides
      and NMI detection. See `spec/non-goals.md`.
- [x] **Fault policy:** default IDT handlers for double fault / GPF / page fault — state
      dump to serial and halt (no reset, no silent continuation). Detail
      `spec/invariants.md` §1 (Safety).
- [x] **PS/2 keyboard** — IRQ1, scancode → KeyEvent (subsystem `input/service.zig`).
- [x] Start of the **dispatch layer** (`api/sys.zig`), KI enumeration.
- [x] Atomic event queue (spec `input.md`), `dropped` counter.
- [x] **Runtime tests in QEMU** (`isa-debug-exit`, exit code) — first running runtime
      tests (tick, IDT, event queue); mechanism spec `verification.md` Step 4b.
- [x] **Freestanding backtrace** in the panic/fault handler (spec `invariants.md` §1).
- [x] Metrics into the table (M2 28.8 KB, First Frame ≈ 0.5 s — see §2).

**DoD:** scancodes and ticks on serial; the dispatch layer compiles; host tests green;
first runtime tests in QEMU green (exit code 0).

### M3 — Graphics

**Goal:** visible text in the framebuffer.

- [x] GOP framebuffer init (Limine), `Framebuffer` struct.
- [x] **Renderer:** `fillRect`, `blit`, `fillScreen` with clipping (spec `graphics.md`).
- [x] **Embedded bitmap font** + `drawGlyph`, `drawText`.
- [x] Graphics API module (`api/graphics.zig`) + dispatch.
- [x] **Event loop** `poll() → update() → render()` (spec `input.md`).
- [x] Keyboard → text on screen (typing visible in QEMU).
- [x] Metrics into the table.

**DoD:** you type on screen from code; renderer tests (blit clipping) host-green.

### M4 — Lua

**Goal:** interactive Lua REPL in the kernel + hot reload.

- [x] Lua 5.4.8 compiled as a C static library in `build.zig` (no system libc
      dependency for the target).
- [x] `@cImport` of the Lua headers; `api/runtime.zig` with `RuntimeKind.Lua`.
- [x] Bindings: `gfx.*`, `input.*`, `time.*` (convention spec `runtime.md` §4).
- [x] `ui/` modules **embedded** in the binary (theme, wm, repl, launcher, input, main —
      concatenated into one chunk), started at boot.
- [x] Lua draws the first frame ("Hello from Lua"), reacts to the keyboard.
- [x] **GC tempo:** a `collectgarbage("step", N)` budget in every `update()`, measuring
      frame latency p99; optionally generational mode (spec `runtime.md` §6).
- [x] **Hot reload:** re-initializing the Lua state without restart (F5 shortcut);
      teardown of old-state userdata/callbacks (spec `runtime.md` §5).
- [x] **Runtime tests of the Lua bindings** in QEMU (`verification.md` Step 4b) — real
      binding calls in kernel context, not just host mocks.
- [x] Metrics into the table (size jumps with Lua, document it).

**DoD:** "Hello from Lua" in QEMU, keyboard works from Lua, hot reload works, binding
marshalling tests green.

> **State:** Lua 5.4.8 runs in the kernel. Libraries opened: `base`, `coroutine`, `table`,
> `string`, `utf8`, `math` (io/os/package/debug excluded — no FS, no dynamic loading,
> integer-only KI). Freestanding libc shim (`libs/lua-5.4/include/` +
> `src/kernel/lua/libc.zig`): string/ctype/snprintf/strtod/pow/acos/asin/atan2 +
> `setjmp`/`longjmp` (asm), deterministic `time`/`clock`, file stubs for
> `luaL_loadfilex`. Hot reload via F5. After start an **interactive Lua REPL** runs
> (banner + `> ` prompt, `load`/`pcall`, `print` to screen). **Keyboard layout** is
> infrastructure (`input/layout.zig`, US 105+) — the binding sends `char`, Lua does not
> map. A coalescing bug in `HeapAllocator` was fixed (wrong `prev` computation + linking
> of the swallowed block) — see `spec/troubleshooting.md` C17. `grow()` allocates 4 pages
> (16 KB) at once — the Lua loadbuffer needs allocations > 4 KB.

### M5 — UI (Shell in Lua)

**Goal:** usable desktop in Lua.

- [x] **Live transformation — foundation:** `gfx.invalidate()` — the shell (Lua) requests
      a re-render without a key; `ui/theme.lua` declarative theme (colors as data)
      changes live from the REPL.
- [x] Windows: window list, focus, z-order, drag (tiling + float, Super+Alt+Space).
- [x] Taskbar + launcher — Lua clients of the Graphics API (35px taskbar: launcher,
      clock, workspace chapel, volume/session; launcher with a search box + filtering).
- [x] REPL console (`~`) — typing Lua code into the running system (as a window in the shell).
- [x] **Live transformation:** a Lua command immediately redraws the environment (colors,
      shapes) without losing windows/terminal content; **F5** = manual refresh (spec
      `runtime.md` §5a). (A REPL command changes the theme at runtime without losing
      windows; bar height is read live from the theme — runtime test "live theme change";
      F5 = hot reload = shell restart per §5.)
- [x] Restarting the shell must not crash the kernel (error containment, `spec/runtime.md`
      §5; runtime test "error containment").
- [x] Metrics into the table (bench 2026-08-08: kernel 366 KiB, Kernel Entry → First Frame
      ≈ 90 ms; render throughput ≈ 3–4 renders / 10 ticks — full-shell render, see note ³).

> **M5 optimization pass (rule 5 in §4):** ran — renderer throughput measured (3–4 TCG /
> **32 KVM**, note ⁵), Kernel Entry → First Frame measured under KVM (≈ 24 ms,
> target < 40 ms reachable), RAM idle measured (2 MiB, note ⁴), kernel size holds the
> target < 512 KiB. Remaining: frame latency p99 (no measuring mechanism yet) and
> measurement on real hardware after M8 stabilization (note ³).

### M6 — Storage

**Goal:** loading files at runtime.

- [x] **initfs** from a Limine initrd (RAM disk) — loading `.lua` / assets at runtime.
      **Format: tar** (simple, streamable, easy to generate at build time; decision from
      the preparation phase — implemented here). Shell modules (`ui/*.lua`) load from the
      tar instead of `@embedFile` (Limine module request + `src/kernel/fs/tar.zig`).
- [x] **Block device driver** — **virtio-blk** (QEMU standard), reads. Without a block
      device there is no persistence; the driver is a separate point (only then FS).
      Modern (capability-based) transport, works on transitional (0x1af4:0x1001) and
      modern-only (0x1af4:0x1042) devices; boot log `[ OK ] storage virtio-blk`.
- [ ] **Partition table** — **GPT** (standard), reads; ext2/ext4 and FAT32 on disk need a
      partition table. Never a custom format.
- [ ] **Persistence: ext2 read-only** (ADR-023) — **never a custom format**. ext2 is just
      an on-disk representation, no POSIX semantics in the API (reservations in ADR-023);
      the feature check rejects unsupported features; the subset is paired with the exact
      `mke2fs -t ext2` invocation (ADR-014; watch out for the default `dir_index`).
      FAT32/ext4/EROFS/9P are future backends per the triggers in ADR-023, not a required
      goal.
- [x] **Cooperative reads:** slow FS operations must not block the event loop —
      cooperative suspension (spec `kernel-interface.md` §6.2, `timer.md` §3). —
      **closed by principle (2026-08-09):** in M6 the FS is read exclusively outside the
      event loop (boot probe + runtime tests), no slow read runs inside `update()`/
      `render()` — the event loop has nothing to block. Full cooperative suspension
      (deadline queue, resume) is implemented with tasks in **M7** (ADR-017 scheduler);
      see `kernel-interface.md` §6.2.
- [ ] **Auto-reload on save:** saving `theme.lua`/a config file → automatic redraw of the
      environment without a key (spec `runtime.md` §5a trigger 2).
- [ ] (Outlook: saving, editor.)
      > **Note (2026-08-08):** saving settings (`theme.lua` etc.) cannot be tried until
      > the disk can write — ext2 is read-only, the testability of auto-reload is tied to
      > future saving.

#### M6.1 — Persistence foundation (ADR-023)

- [x] **M6.1.1 Block device API:** stable interface + **virtio-blk** (sector reads); FS
      code does not depend on a concrete driver. *Exit: deterministic block reads from
      disk.* — **done:** `src/kernel/drivers/pci.zig` + `virtio.zig`, reads sector 0
      (verified magic bytes), boot log `[ OK ] storage virtio-blk` only when a disk is
      present. Locally the disk is attached via `zig build run -Ddisk=disk.img`.
- [x] **M6.1.2 GPT partition discovery:** partitions as block-device views, independent
      of the FS. *Exit: finding the target partition and reading its sectors.* —
      **done:** `drivers/block.zig` (BlockDevice + PartitionView), `gpt.discover()` (reads
      the header + entry array from disk, returns partitions as views),
      `virtio.asBlockDevice()`; boot log `[ OK ] gpt N partition(s)` with a disk. QEMU
      boot order fixed to CD (`-boot order=d`) — a GPT disk with a protective MBR would
      otherwise block boot. Host tests with a mock BlockDevice.
- [x] **M6.1.3 ext2 mount (read-only):** superblock, block groups, bitmaps (validation),
      inode table, inode lookup, directory entries, data (direct + needed indirect
      blocks); validation of feature flags + **reject**. *Exit: mounting a host-created
      ext2 image + listing files.* — **done:** `ext2.zig` rewritten to `PartitionView`
      (reading from disk), `readFile` (direct + single indirect), `find()`; feature
      subset fixed per real `mke2fs -t ext2` (`filetype` = incompat 0x2, `dir_index` =
      compat 0x20 → reject); boot log `[ OK ] fs ext2` + root-directory listing. Verified
      on an `mke2fs -t ext2 -O ^dir_index` + GPT image.
- [x] **M6.1.4 Thin Aster File API:** `open` / `read` / `close`, opaque reference. **Not:**
      inode numbers, uid/gid, mode bits, ACLs, hardlink semantics, ext2 metadata. *Exit:
      the runtime reads an ext2 file without knowing ext2 exists.* — **done:**
      `fs/file.zig` (`File.open/read/close`, `fileSize`, `eof`; opaque backend reference),
      `ext2.readAt` (reading from an offset); boot log `  file <content>` from the
      `theme.lua` on disk. Fix: kernel stack 16 KiB → 64 KiB (the 16.9 KiB dir-entry
      buffer overflowed the 16 KiB stack).
- [x] **M6.1.5 Integration:** persistent FS next to initfs (separate backends);
      deterministic test images from host tooling; QEMU runtime tests (mount, lookup,
      open, read, EOF, invalid path); documentation of the feature subset + exact
      `mke2fs` flags. *Exit: see diagram below.* — **done:** `tools/make-test-disk.sh`
      (deterministic GPT+ext2 image), QEMU runtime test "ext2 filesystem on disk", CI
      step with a disk, ADR-023 (feature subset + exact invocation). **Ordering bug:** the
      PFA allocated low-memory pages that hhdm does not map → fault; fix `low_memory_end`
      (C32, H3 closed).

**M6.1 — additional tasks (now):**

- [x] **M6.1.6 CI job with a disk:** qemu-smoke with `-drive ... -device virtio-blk-pci` +
      marker `[ OK ] storage`. Today CI never tests storage — a cap-walk bug would never
      have been caught without a disk. — **done:** `tools/qemu-smoke.sh` supports
      `SMOKE_DISK` / `SMOKE_MARKER` (ANSI-strip + fixed-string grep), CI has a "Storage
      boot smoke test" step.
- [x] **M6.1.7 Host unit tests of the GPT parser:** pure function over `[]u8` (pattern
      `tests/mem/`). — **done:** `src/kernel/fs/gpt.zig` (parseHeader + parseEntries,
      CRC32 validation, no allocations) + `tests/fs/gpt_test.zig` (10 tests).
- [x] **M6.1.8 Host unit tests of the ext2 parser:** superblock / features / inode / dir
      traversal. — **done:** `src/kernel/fs/ext2.zig` (read-only reader: superblock
      validation, feature reject per ADR-023, inode lookup, dir traversal; no
      allocations) + `tests/fs/ext2_test.zig` (14 tests). Data/indirect blocks remain
      M6.1.3.
- [x] **M6.1.9 Decide the Lua `dbg` library now:** open `luaopen_debug` as `dbg`
      (`dbg.traceback()`), avoiding the collision with the KI module `debug`. Doing it
      later would break scripts. — **done:** own `dbg` lib (only `traceback`) in `lua.zig`
      (`openDbg`/`dbgTraceback`); the stock `luaopen_debug` cannot be used — `debug.debug`
      reads stdin. Runtime test "lua dbg lib (M6.1.9)" + `spec/debugging.md` §5 updated.
- [x] **M6.1.10 README quickstart:** `zig build run` as the first block right after
      Status. — **done:** Quick start moved right after Status (before Prerequisites),
      including `-Ddisk=disk.img`.
- [x] **M6.1.11 Release/tag + prebuilt ISO workflow:** "download and run", not "build
      from git". — **done:** `.github/workflows/release.yml` — on a `v*` tag it runs the
      full verification (build, host tests, smoke, runtime tests with a disk), and only
      when green publishes `aster.iso` as a release asset (`gh` CLI, no third-party
      action). — **Release is deferred (2026-08-09):** in alpha without a consumer it
      makes no sense; the workflow stays ready and is triggered by a tag when there is
      real demand (demo, milestone, M10).
- [ ] **M6.1.12 CI on Windows/macOS:** Zig is cross-platform, build.zig should run.

```text
GPT disk image → GPT → ext2 partition → Aster FS backend → open/read/close → runtime
```

### Phase 2 — boundary of M6.1/M7

Decisions and moves between M6.1 and M7 (recorded 2026-08-08). Goal: design and moves
that must be resolved **before** starting more features, not at the end of
stabilization (M8).

- [x] **Multi-layout keyboard (design now):** `input/layout.zig` stops being a hardcoded
      US 105+; **KL registries** are introduced — a layout as a registered mapping table
      (`KeyCode` × modifiers → `char`/action), switchable at runtime. The design is done
      now, before anything else is added (Wasm apps, more runtimes). Extending the KI
      (`input.set_layout`) = a new ADR.
      *Exit: switching the layout at runtime (US ↔ CZ) on the same scancode stream,
      without restart.* — **done:** ADR-024, `layout.zig` = KL registry (US default + CZ
      QWERTZ, ASCII fallback), KI `input.set_layout` / `layout_name` (InputOp 8/9), host
      tests of switching.
- [ ] **Shared buffers + present moved forward from M7 (render quality):** tearing/flicker
      are solved **before stabilization (M8)**, not at its end. Render into a private
      offscreen surface + `present` into the framebuffer (original M7 item, moved — see
      M7 below). *Exit: double-buffered present without tearing; frame latency p99 (§2)
      recorded.*
- [x] **USB HID — DECIDED (2026-08-09): USB WILL BE.** Without USB there is no real
      hardware (PS/2 is dead), so a USB HID stack is a commitment — the question is not
      "whether" but "when". Only the **placement** remains open: (a) USB HID stack
      earlier (~M6.3/M7.x), or (b) M10 = "QEMU + legacy HW (PS/2)" and USB HID as a
      separate milestone. *Exit: a recorded decision with an impact on M10.* —
      **done:** USB is a confirmed goal; the placement is chosen when planning M7/M10.

### M7 — Runtime (Wasm)

**Goal:** isolated apps.

- [ ] wasm3 vendored; `Runtime.spawn(.Wasm, ...)`.
- [ ] First `.wasm` app (C/Rust → wasm) drawing into its own surface.
- ~~Shared buffers + present~~ — moved to Phase 2 (render quality before stabilization).
- [ ] **Preemptive RR scheduler** for multiple tasks (ADR-017) — critical sections with
      preemption disabled, no locks; `sleepMs` moves to a blocking task sleep
      (`spec/timer.md` §5).
- [ ] **Per-program `lua_State` / instance** after `spawn` — a frozen program (infinite
      loop) no longer freezes the environment; preemption + task error handler
      (spec `runtime.md` §5).
- [ ] **Blocking synchronization primitives** (ADR-017): semaphore, mutex, event group,
      message queue; **task error handler** (`anyerror!void`).
- [ ] Benchmark wasm vs Lua; metrics into the table.

### M8 — Stabilization

**Goal:** a polished base for further development.

- [ ] Invariant audit (spec `invariants.md`) point by point.
- [ ] Problematic metrics under target; optimization per measurement (rule 5 in §4 —
      the last optimization pass before stabilization).
- [ ] Decision on the next direction: (a) more features, (b) start separating into
      Ring 3. For choice (b) the **KI transport is prepared in advance** (ADR-018:
      mailbox IPC, comptime dispatch, IRQ routing) — implemented only here, not earlier.
- [ ] New features (audio, M9 network, browser in Lua) are added per **ADR-020** — as new
      KI modules appended to the enum, without modifying existing ones.

---

### M9 — Ecosystem (Network, Audio, Browser, WASI)

**Goal:** open the system to a wider app ecosystem.

- [ ] **Network (M9, ADR-022):** KI module `net.*` — virtio-net driver + ARP/IPv4/ICMP/UDP;
      parser without fault on foreign input, network off by default, fuzz tests
      (the security brake from `non-goals.md` is handled by ADR-022).
- [ ] **Audio:** new KI module `sound.*` (ADR-020).
- [ ] **Browser in Lua:** a client of the Graphics/Input/Net API — no kernel-specific code
      (ADR-020).
- [ ] **WASI layer:** mapping WASI syscalls onto the KI for foreign wasm apps
      (`runtime.md` §7.1) — starts with a subset (stdout, argv, filesystem), not full WASI.

### M10 — Adoption (real hardware, image, docs, community)

**Goal:** someone other than the author can run and contribute to the system.

- [ ] **Proof of ADR-018 (mailbox transport):** before full adoption (stable ABI) the
      promise "microkernel without rewriting apps" is demonstrated — **one KI module**
      over mailbox IPC (Ring 3 transport; implementation starts in M8, item (b)) with a
      running existing app **without changing the application API**. A proof, not a
      declaration.
- [ ] **Boot on real hardware** — **follows the USB HID decision (Phase 2):** either with
      the USB stack earlier (~M6.3/M7.x), or as "QEMU + legacy HW (PS/2)". Measuring the
      metrics on real HW closes note ³ in §2.
- [ ] **Installable image** (boot from disk, not just ISO in QEMU).
- [ ] **Docs for contributors and the English layer:** CONTRIBUTING (done), ongoing
      English layer in `docs/` (web) — continuously, **not a condition of M10**; see the
      language strategy in `spec/README.md`.
- [ ] **Adoption:** stable ABI, more features per ADR-020 based on feedback.

---

## 4. Working rules between milestones

1. **Every commit = a bootable system** (ADR-016). A broken boot is fixed immediately,
   never "in a few commits".
2. **Metrics are measured and recorded** at the end of every milestone
   (`tools/bench.sh`).
3. **No new feature without a green pipeline** (spec `verification.md`).
4. **Architecture is not further optimized on paper.** Further improvements come from
   real implementation experience (boot, text, Lua VM), not hypothetical scenarios.
5. **After every milestone (M-cast) an optimization pass runs.** Before starting the next
   milestone the metrics are checked against targets and targeted optimizations run:
   - binary size (sections `.text`/`.rodata`, dead code, compile flags of C sources),
   - hot spots (render pipeline, heap allocator, event loop) — measure, don't guess,
   - benchmark **before and after** (`tools/bench.sh`, runtime test `render throughput`),
   - no optimization without a recorded value in the §2 table.
   Results go into the metrics table and optionally `spec/troubleshooting.md`.
6. Interface (KI) changes = a new ADR in `spec/adr/`, never a silent edit.
7. **Docs are updated with every feature.** A feature without a recorded metric row *and*
   without updating the relevant spec is not done (see `spec/verification.md` DoD).

---

## 5. First-boot sequence diagram (M0 → M4)

```
QEMU → BIOS/UEFI → Limine (bootloader)
   → handoff (long mode, mem map, GOP fb, serial)
   → kernel.main (M0)
   → mem.init / pfa (M1)
   → cpu.init: IDT, timer, PS/2 (M2)
   → fb.init, renderer, font (M3)
   → runtime.init: Lua state (M4)
   → ui/main.lua runs (concatenated ui/ modules) → "Hello from Lua"
   → event loop: poll() → update() → render()
```

---

Last synced from [`spec/roadmap.md`](https://github.com/Xelvra/aster-os/blob/main/spec/roadmap.md) on **2026-08-09**.
