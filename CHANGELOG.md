# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version number matches the project milestone (0.0.0 = M0 Boot, 0.7.0 = M7
Runtime). Newer versions are listed first.

> This file is **hand-curated** (what the system can do). The raw commit
> history is regenerated separately by `tools/generate-changelog.sh` — never
> point it at this file; it writes `CHANGELOG-commits.md` instead. See Dev
> tools below.

---

## [0.7.0-alpha.2] — Milestone M7 — Runtime (in progress)

This version tracks the milestone after M6 Storage was completed.

### Added

* **File browser colour hierarchy + palette:** listing entries follow a fixed
  colour hierarchy (`files.lua entry_color`, most specific first) — selected =
  accent, inside `/.trash` = trash blue (`theme.trash`, new), executable `.wasm`
  = green (`theme.exec`), read-only `.bak`/`.repl_history` = red, hidden dot
  files = dim, everything else = white. The trash has its own colour (blue)
  instead of sharing the hidden-file dim, so a "deleted" file reads as such;
  the palette (including `exec`/`trash`) is documented in `spec/desktop-ui.md`
  §4.1 and the rights (edit/delete/rename per category) in `spec/lua-wm.md`.

* **Wasm (M7) — wasm3 interpreter vendored and linked into the kernel:** the
  WebAssembly runtime ships as a vendored wasm3 v0.5.0 (`libs/wasm3/`, upstream
  sources untouched) with its own freestanding headers, built as a
  self-contained sandbox module that never sees the Lua vendor's libc. Its
  `malloc`/`free`/`realloc`/`abort` resolve against the shared kernel libc,
  which moved out of `lua/` into `src/kernel/libc.zig` and gained software
  `floor`/`ceil`/`trunc`/`rint`/`copysign`/`sqrt` (bit-trick IEEE 754 and a
  Newton-Raphson sqrt) plus `strlen`. The math functions are implemented by
  hand because `@floor`-style builtins on baseline x86_64 lower to software
  routines that call the same-named C symbol — i.e. the exported function
  itself — causing infinite tail recursion (troubleshooting C51). Host tests
  cover them, including `rint` ties-to-even and signed zero.

* **Wasm (M7) — Phase A runtime module and test programs:** `src/kernel/wasm/`
  hosts wasm3 (`cimport.zig`, `wasm.zig` with `Runtime.spawn(.Wasm)` and trap
  containment) and the kernel links wasm3 as a sandbox module (PIC, so Debug
  links like the kernel PIE). The first wasm programs are compiled from Zig to
  `wasm32-freestanding` and packed into the initrd: `hello` (writes via a
  `debug_write` import) and `fault` (deliberate trap, proving a crashing wasm
  program is dropped while the desktop keeps running). Executable `.wasm`
  files render green in the file browser (`theme.exec`). Next: Phase B
  (surface model + calculator).

* **Wasm (M7) — Phase B surface model and the calculator app:** wasm programs
  render through a fixed 224×160 surface composited by the WM via the new
  `runtime.surface_render` KI op, and receive keystrokes through
  `runtime.key_input` — the WM no longer needs to know which runtime backs a
  window (ADR-026). The calculator (`src/kernel/apps/calculator.zig`, built to
  `wasm32-freestanding`) is the first real wasm application; it is staged onto
  the test disk as `/apps/calculator.wasm` and discovered by the launcher
  scanning `/apps/` at runtime, so applications ship independently of the
  kernel image (ADR-027). Next: benchmark wasm vs Lua (Phase C).

* **C stdio layer over the kernel storage:** `fopen`/`fread`/
  `fclose`/`feof`/`ferror`/`getc`/`freopen` map onto the KI storage handles so
  stock Lua file functions (`dofile`, `loadfile`) read files from the disk;
  the `testDofile` runtime test is enabled and passes (a file written with the
  `file.*` API is loaded and run by plain `dofile`). **Handoff H6 is
  closed** (2026-08-18): the storage regression was a stale test-disk artifact
  (reusing the image across runs after `file.remove` deleted `/README`), not the
  stdio code. `diag_verify_reads` (default off) in the virtio
  driver repeats every DMA read and compares the copies (`VIO-DIFF`) and
  sentinel-checks the buffer (`VIO-STALE`) to pinpoint the fault on a failing
  machine.

* **SMP groundwork — Application Processor bring-up (M2/M7 debt):** the MADT
  parser now collects the Local APIC IDs of the enabled Application Processors
  (`acpi.zig`), the Local APIC driver gains an IPI layer (`sendInitIpi` with
  the level-triggered INIT assert + deassert, `sendSipi`, `enableLocal`,
  `readLocalApicId`) plus `io.writeMsr`, and a low-memory AP trampoline
  (`smp_tramp.s`) + orchestrator (`smp.zig`) copies the code block to
  `0x8000`, identity-maps it, wakes each AP with INIT-SIPI-SIPI and waits for
  it to report ready. The AP entry loads the shared IDT, enables its Local
  APIC and idles; the scheduler stays BSP-only. Under QEMU `-smp 2` the boot
  log reports `smp: 1 ap` and the in-QEMU runtime test "SMP AP bring-up"
  passes. (First attempt crashed the AP with a `#PF(RSVD)` on its first page
  walk — a `call`/`pop` getip trick read CR3 from garbage because the AP has
  no stack yet; fixed together with the CR4 mirror and the missing long-mode
  jump. Lessons C48/C49, handoff H5.)

* **WM configuration directory on the disk (`/wm/`):** the disk config that
  used to sit loose at the filesystem root now lives in a dedicated `/wm/`
  directory —   `/wm/theme.lua` (colors and geometry, hot-reloaded on save),
  `/wm/api.lua` (Lua API reference) and `/wm/.theme.bak` (last valid theme
  backup); the user guide is the root `/README`. The root stays clean (only
  `apps/`, `.trash/`, `wm/`, `README`, `.repl_history`). Moving the full Lua shell
  from the initrd into `/wm/` is planned as a later milestone (Úroveň 2,
  `spec/roadmap.md` M8, `spec/lua-wm.md` §3.1).

* **Preemptive round-robin scheduler for native kernel tasks (2026-08-15-self-audit §3.5, Task 7):**
  new `sched/task.zig` runs multiple kernel tasks on one core, preempted by the
  APIC timer IRQ (vector 0x20). TCB table and all task stacks are static (no
  allocation), the switch lives in the `cpu/isr.s` asm bridge, and the critical
  section is lock-free thanks to the interrupt gate masking IRQs inside the ISR.
  Runtime test proves real preemption: two tasks spin on atomic counters and both
  advance. Blocking per-task `sleepMs` (`spec/timer.md` §5) is implemented and
  verified by the `testBlockingTaskSleep` runtime test.

* **I/O APIC discovery from ACPI (2026-08-15-self-audit §3.7):** new `cpu/acpi.zig` parses
  RSDP (handed by Limine) → RSDT/XSDT → MADT and reads the I/O APIC address
  from the MADT entry instead of hardcoding `0xFEC00000` for QEMU. The legacy
  address stays as a fallback default; the boot log reports the I/O APIC
  source on the `cpu` line — `· ioapic: madt` when discovery succeeds,
  `· ioapic: fallback, <reason>` otherwise (brief Q5). Every read table is
  checksum-validated and any parse failure degrades to `null` → fallback (no
  panic on malformed firmware data).

* **ext2 file.create (M7.1.11):** the write path can now create new files —
  `file.create` allocates and initializes an inode and links a directory entry
  (ADR-023, non-crash-safe best effort). Exposed through the thin Aster File API, the
  storage KI (`storage.create`) and the Lua `file.create` binding; covered by
  host and in-QEMU runtime tests.

* **ext2 file.rename + files browser F2 rename:** a file or directory can be
  renamed — `file.rename` relinks the existing inode under the new name (no
  data copy, the old directory entry is dropped) and rejects an existing
  target. Exposed through the storage KI (`storage.rename`) and the Lua
  `file.rename` binding. The file manager's **F2** turns the title-bar header
  into a `rename:` prompt (text cursor follows, Enter commits, Esc cancels) and
  refreshes the listing with the selection on the renamed entry; read-only
  files are refused like the editor refuses them. **Shift+F4** starts a new
  file from the file manager (Midnight Commander convention): the editor opens
  an untitled buffer, Ctrl+S then prompts save-as. The file browser also
  refreshes itself when the editor saves a new file into the shown directory
  (save-as), so a new entry appears immediately instead of on the next
  navigation. Covered by host and in-QEMU runtime tests.

* **Editor workflow:** Super+T (and the launcher's `editor` entry) opens a
  fresh untitled buffer (a dirty buffer is kept so edits survive); Ctrl+S on a
  new buffer shows a `save as:` prompt in the window title bar (with a text
  cursor) and creates the file via `file.create`; the dirty marker clears when
  every change is reverted; Esc Esc closes the editor only when clean.
  Super+Z opens the settings file `/wm/theme.lua`.

* **Unified window headers (§7b):** the title bar carries only the context
  (path, dirty marker) on the left and a right-aligned dim `help F1` hint on
  the right — no inline key hints, so the header stays clean and every window
  points to the same help popup in the same place; window content starts with
  the data; the REPL shows the real Lua banner. F5 hot reload stays.

* **Trash directory (`/.trash`):** the image ships an empty `/.trash`
  directory as the future trash location (empty-trash is planned, not wired).

* **F-key duality with Hyprland shortcuts:** F1/F2/F3/F4/F5/F11 reach the same
  actions as their Super+.../Ctrl+S counterparts a second, familiar way —
  F1 help, F2 editor save-as, F3 files view (like Space), F4 files edit (like
  Enter), F5 hot reload, F11 fullscreen (like Super+F/D). F6–F10 and F12 are
  reserved (Hyprland reserved-slot pattern) and must not be bound without
  re-evaluation.

* **Contextual help (F1 / Super+F1):** F1 inside a window opens that app's own
  complete cheat sheet — the file manager lists its listing and view-mode keys
  as separate sections (including Page Up/Page Down), the editor covers its
  save-as prompt, the REPL its history/cursor editing. Super+F1 anywhere (or
  F1 outside a window, or the launcher `help` entry) opens the global WM help
  (`global help:`), which lists only window-manager functions valid for all
  windows; every app help ends with a `Super+F1  global help` row so the user
  can always find the WM sheet (e.g. Super+Q). Popup titles are accent-colored
  in all modes (`run:`, `scratchpad:`, `global help:`, app names), typed input
  stays white.

* **Esc Esc as a deliberate deviation from Hyprland:** double-Esc closes the
  editor (clean buffer only) / exits the file view — a documented guard
  against accidental closes (Hyprland has no double-Esc convention; windows
  close via Super+Q).

* **Super+S as a real scratchpad toggle:** the first Super+S opens an app
  picker (applications only, labelled `scratchpad:`); afterwards Super+S only
  shows/hides that dedicated window over anything — a fullscreen window or an
  empty workspace. Not an alias of Super+Space or Super+Alt+Space.

* **Basename backup for every `.lua` file (ADR-025):** on Ctrl+S every Lua
  file keeps a hidden read-only backup of its previous version next to the
  working copy — `test.lua → .test.bak`, `api.lua → .api.bak`,
  `theme.lua → .theme.bak` — so the last save can be restored by renaming the
  backup back; non-Lua files and freshly created files get no backup.

* **Lua shell regression suite:** the real shell modules run on the host
  against stubbed kernel bindings (`tests/lua/`) — 34 tests covering the UTF-8
  helpers, editor typing/cursor, basename backups, the broken-theme save trap,
  protected dirs via the `wm_error` channel, workspace bounds, shared
  bar/launcher geometry, `esc_pending` and history persistence — wired as
  `zig build shell-test` and run in CI. Host tests gained an SPSC queue suite,
  a `libc` malloc/realloc bookkeeping suite and the wasm libc math tests
  (160 total).

* **ext2 double/triple indirect:** files larger than the single-indirect span
  (~4 MB at 4 KiB blocks) can now be read and written — `blockForIndex` and the
  block allocator walk single/double/triple indirect pointer chains, and
  sparse holes read as zeros.

* **Title-bar mouse interaction (minimalist):** a **double-click on a window's
  title bar toggles fullscreen** (one gesture for every window — the standard
  WM convention), and the close "x" stays the only drawn button. The double
  click is timed with the new real-time `time.ms()` binding (PIT-calibrated,
  independent of the APIC tick rate), so the 0.3 s threshold works in QEMU and
  on real hardware; the bar clock also reads real wall time from `time.ms()`
  (the APIC tick rate is not a reliable clock — it varied between ~478 Hz and
  ~3100 Hz in QEMU TCG runs). The files
  window's title bar is no longer a navigation target (a double-click there
  would otherwise do `cd ..` twice): going up lives in a **`..` entry** (shown
  as `/..`, the DOS/MC convention) as the first listing row plus the Escape
  key,   and directories render with a **leading slash** (`/dir`).

* **Real-time bar clock:** a **CMOS RTC driver** (`src/kernel/rtc.zig`) reads
  the time of day at boot (ports 0x70/0x71, BCD and binary as selected by
  status register B bit 2, 12/24 h, double read across the update boundary)
  and seeds the wall clock; the bar clock now shows **real wall time**
  (`time.of_day_ms()` = RTC seed + PIT-calibrated `time.ms()`), not uptime.
  The RTC is treated as **local time** (the BIOS/Windows convention) — QEMU is
  launched with `-rtc base=localtime` so the guest clock matches the host.
  The wall clock is **re-synced with the RTC every frame** in the event loop,
  so the bar clock stays correct even if the TSC-based `time.ms()` is
  miscalibrated or frozen (the RTC is a hardware clock that always runs). The
  bar clock re-renders when the second changes (`update()` invalidates
  once per second), so it ticks even with no input. The PIT/TSC calibration
  uses a proper channel-2 latch, the median of five ~50 ms samples and a
  2.5 GHz fallback, so `ms()` reliably advances. The RTC BCD conversion is
  host-tested and a QEMU runtime test asserts a plausible time of day and that
  the clock advances. A missing/broken RTC falls back to time since boot.

* **Editor mouse conventions (mainstream GUI editors):** the mouse wheel
  scrolls the editor viewport in the **standard direction** (wheel down =
  scroll down toward the end — Windows/Linux, not macOS natural; the text
  caret does not follow — VS Code / gedit convention), and a click in the text
  places the caret at the clicked character (code-point aware, clamped to the
  visible text / line end). The same conventions apply to the read-only files
  **view mode** (Space preview): wheel scrolls, click moves the hollow cursor
  — the foundation for a future clipboard selection (`Ctrl+C`/`Ctrl+V`). The
  keyboard still keeps the caret visible. PS/2 mice that support the wheel
  (Intellimouse 4-byte packets, detected via the device ID) now deliver it
  through a new `input.mouse_wheel()` KI binding; a plain mouse stays on the
  3-byte format.

### Fixed

* **Clicking the launcher's `help` entry closed it instead of showing the
  cheat sheet:** the mouse path always set `launcher_open = false` after
  running an item, so the `help` action (which switches the launcher to the
  help mode) vanished before rendering; the Enter key already respected the
  mode. Both input paths now agree, so a click on `help` shows the global WM
  keybinding cheat sheet without closing the launcher.
* **ext2 group descriptor hardening:** `groupDescriptor` now computes the GDT
  block and in-block offset from the group index (multi-block descriptor tables
  work), and bounds the group against the block-group count derived from the
  superblock. `Ext2.init` rejects a superblock with `blocks_per_group == 0` or
  `inodes_per_group == 0` as `CorruptSuperblock`, and `readInode` guards the
  inode-to-group division (2026-08-15-self-audit §3.6).
* **PFA allocation locality:** the frame allocator keeps a `next_free_hint`
  so allocations scan forward from the last free index (with wrap-around)
  instead of restarting at zero, and a `free_pages` cache makes
  `totalFreePages()` O(1) instead of a full bitmap scan (2026-08-15-self-audit §3.1).
* **Global mutable state eliminated (2026-08-15-self-audit §3.2):** the six display globals
  in `main.zig` (`fb_storage`, `back_fb`, `renderer`, `mouse_cursor`,
  `needs_render`, `first_frame_reported`) are merged into one `DisplayState`
  owned by `kernelMain` and threaded through the frame loop by pointer. The
  six keyboard-modifier globals in `lua/bindings.zig` move to
  `input/service.zig` beside `mouse_state`; the Lua bindings now reach them
  through the KI (`api/input.zig`).
* **Fullscreen exit on a floating window:** a window (e.g. the scratchpad)
  entered fullscreen via Super+F/D but stayed fullscreen-sized on exit —
  `toggle_fullscreen()` now stores the geometry before entering and restores
  it on exit (floating windows only; tiled ones are repositioned by
  `layout_pass`). `exit_fullscreen()` is shared by the toggle, workspace
  switches and window close, so the geometry stays coherent everywhere.
* **Navigation consistency across workspaces:** moving a window to another
  workspace (Super+Shift+1/2/3) or switching workspaces while a window is
  fullscreen now clears fullscreen/scratchpad state deterministically in the
  input path, not as a render side effect.
* **Single `Help F1` hint in the bar:** the right-aligned `help F1` was drawn
  into every window's title bar, so it duplicated across side-by-side windows.
  It now lives once on the bar's right side (`Help F1`, `theme.text`) and the
  placeholder `Vol 100%` is gone — window headers keep only the context (path,
  dirty marker). F1 still opens the focused window's help inside a window and
  the global help outside, and **clicking the bar's `Help F1` hint does the
  same** (see `spec/lua-wm.md` §7b).
* **Close button in every window header:** a small **`x`** in the top-right of
  each window's title bar closes the window with the mouse (the same action as
  Super+Q); it is skipped when it would overlap a long header path. The
  launcher popup (help and run modes) has the same close `x` in its top-right
  corner, so the help sheet can be dismissed with the mouse instead of forcing
  an Esc (see `spec/lua-wm.md` §7b).
* **Trash (`/.trash`):** the file manager's **Delete** now moves a file or
  directory into `/.trash` (ext2 `rename`, no data copy — the undo zone);
  inside the trash Delete removes the selected item permanently and
  **Ctrl+Delete** empties the whole trash. The trash directory and ext2's
  `lost+found` are protected (cannot be deleted/moved/renamed), and trash
  entries are drawn in blue (`theme.trash`).
* **Toggle hidden files:** **Ctrl+H** in the file manager shows/hides dotfiles
  (hidden by default-visible; the listing filters them in `load_listing`).
* **Blocking semaphore (ADR-017):** new `sched/sync.zig` provides a counting
  `Semaphore` — `wait()` blocks the current native kernel task until another
  task `signal()`s, with the waiter list guarded by the RFLAGS interrupt mask
  (single core, no lock). Verified by a new runtime test that spawns a waiter,
  blocks it, signals it and confirms it resumes.
* **QEMU mouse on Wayland:** the interactive `zig build run` display switched
  from GTK to **SDL**. GDK has no native pointer grab on Wayland (it emulates
  the grab by warping the cursor back), so `grab-on-hover` let the cursor
  escape the window and the guest cursor stopped short of the framebuffer
  edges — the mouse could not reach the corners/`Help F1` and failed entirely
  on a second monitor, even in fullscreen; forcing `GDK_BACKEND=x11` (XWayland)
  only helped fullscreen and added input latency. SDL uses the native Wayland
  relative-pointer lock, so the mouse reaches every edge of the 800x600
  framebuffer in a window, fullscreen and on every monitor (Ctrl+Alt+G grabs/
  releases; see `spec/troubleshooting.md` C43).

* **Editor/REPL/files UTF-8 handling:** two off-by-one/func faults made
  editing look broken — `next_cp` stepped two code points per ASCII character
  (the block cursor sat on the just-typed text, `cp_slice` over-sliced lines
  and horizontal scroll fired late), and `drawText` drew each byte of a
  multi-byte character as a separate glyph (noise). The cursor, slices and
  wrapping now agree with the drawn text and non-ASCII renders as the font's
  `?` fallback (see `spec/troubleshooting.md` C44).

* **A broken theme can no longer trap the editor:** saving `/wm/theme.lua`
  kept the buffer dirty when the config was invalid, so Super+T, files-edit
  and Esc close were blocked forever (the editor could never escape an
  unsavable theme). The working copy is now written and the buffer clears
  even when validation reports the config as broken.

* **The files listing refreshes on save:** a new file or `.bak` backup appears
  immediately (Ctrl+S in the editor calls `files_refresh`), instead of only
  after re-navigating the directory.

* **Hidden (dot) files and the trash share one dim color:** dot files were
  `theme.text_dim` and the trash `theme.trash`, two blues so close that a
  hidden file (`test` -> `.test`) was indistinguishable from `.trash`. Both now
  use `text_dim`, read-only red keeps priority, and everything inside
  `/.trash` is dim regardless of read-only (red returns once a file is moved
  out); the dedicated `theme.trash` field is gone.

* **ext2 sparse files and multi-block directories:** a hole (0 block pointer)
  read block 0 — the superblock — as file data instead of zeros, and
  `readDir` only listed the first block of a directory (an empty directory
  read block 0 as entries). Holes now read as zeros and directories walk every
  block (see the double/triple indirect entry above).

* **Kernel hardening (2026-08-15-self-audit, low/medium):** the bootloader
  framebuffer handoff is validated (bpp >= 32, sane dimensions/pitch),
  `drawGlyph` and `blit` use i64 arithmetic, `checkString` guards the
  `lua_tolstring` null, `next_handle` wraps at a ceiling, the boot handoff
  validates the initrd module and maps unknown memory types to reserved, the
  `libc` `realloc` shrink no longer frees the wrong block, the SPSC event
  queue uses acquire/release ordering, and the virtio-blk driver rejects
  sectors beyond the device capacity.

* **A missing `/wm/.api.bak` in the file browser shows immediately** and the
  api backup is named `.api.bak` (not `api.bak`), matching the basename rule.

* **Multi-block directories (M7.1 debt):** `addDirEntry`/`removeDirEntry`/
  `create` now walk every directory block and grow a full directory with a new
  block instead of returning `OutOfSpace` at the single-block boundary;
  `lookupDir` walks blocks directly so `find`/`open` resolve entries in any
  directory (the old fixed 32-entry readDir cap made lookups fail past 32
  entries). A QEMU runtime test creates 80 files spanning two blocks and
  round-trips create/lookup/remove.

* **M2 SMP debt — full MADT parse:** the MADT now yields the BSP Local APIC
  ID, the ISA IRQ → GSI overrides and NMI presence (not just the I/O APIC
  address). `enableIsaIrq` applies the overrides, so the I/O APIC redirection
  table uses the real GSI; the boot log reports
  `lapic: <id> · overrides: <n> · nmi: <yes/no>`.

* **Blocking sync primitives (ADR-017):** the semaphore is joined by an
  ownership **mutex** (unlock hands the lock to the oldest waiter), an
  **event group** (wait on any/all flags, set/clear) and a blocking **message
  queue** (byte FIFO with message boundaries, put wakes a blocked get). Each
  waits through the interrupt-guarded waiter list and is exercised by a QEMU
  runtime test; `max_tasks` grows to 10 so the suite can hold all task tests.
  Tasks can also be spawned with an `anyerror!void` body and an **error
  handler** (`spawnTaskChecked`) that runs when the body fails.

* **Per-program isolation (M7):** a spawned Lua program runs in its OWN
  `lua_State` (`lua.spawnProgram`) — libraries and the kernel bindings are
  opened into a fresh state, the program's source runs once armed with the
  instruction budget, and its `update()` ticks each frame through
  `tickPrograms()`. An infinite loop or error is contained to that program
  (the program is dropped) and cannot touch the desktop shell, which keeps
  its single state. A QEMU runtime test proves an infinite-loop program fails
  at spawn without hurting the shell, an erroring program is dropped, and a
  healthy program's update side effect is visible across states.

### Removed

* **`theme.trash` theme field:** hidden (dot) files and the trash now share
  `theme.text_dim`, so the dedicated trash color is gone from the theme
  defaults, validation and the on-disk `/wm/theme.lua`.

* **Session menu and the Lua `power` binding:** the Lock/Logout/Reboot session
  menu and the `power` KI binding were removed (the WM is intentionally
  always-live — `spec/runtime.md` §5a; the `power` KI module stays for the
  kernel reboot path). The M5 changelog entry above is historical.

---

## [0.6.0] — Milestone M6 — Storage

### Added

* **virtio-blk block device driver:** Modern (capability-based) PCI transport,
  VIRTIO_F_VERSION_1 negotiation, split virtqueue and sector reads. Works on
  both the transitional and modern-only QEMU device; the boot log gains
  `[ OK ] storage virtio-blk` when a disk is attached.
* **initfs — shell from a tar initrd:** The UI modules (`ui/*.lua`) are packed
  into a tar, loaded by Limine as an initrd module and read at runtime instead
  of being `@embedFile`'d.
* **Persistent filesystem (ADR-023):** ext2 read-only as the first persistent
  backend — used only as an on-disk representation, no POSIX semantics in the
  API, stable `open/read/close` interface, door left open for FAT32, EROFS, 9P
  and ext4.
* **GPT partition discovery:** Partitions become block-device views (a sector
  of a partition maps to a sector of the disk), independent of any filesystem.
* **ext2 read-only mount + thin Aster OS file API:** Superblock/feature validation
  (unknown bits and `dir_index` rejected), inode lookup, directory traversal,
  file reads through direct + single-indirect blocks; `open`/`read`/`close`
  over an opaque backend reference — the caller never sees ext2 metadata.
* **Storage test infrastructure:** Deterministic test disk
  (`tools/make-test-disk.sh`, GPT + ext2 from `mke2fs -t ext2 -O ^dir_index`),
  CI smoke test with a disk, QEMU runtime tests covering mount/lookup/open/
  read/EOF/invalid path, and a `zig build run -Ddisk=disk.img` option.
* **Lua `dbg` library:** The Lua debug library is opened as `dbg`
  (`dbg.traceback()`) because the `debug` name is taken by the KI module.
* **Boot log as proof of work:** A styled colored boot log (`/-\STER OS`, status
  lines, boot sequence) plus a capture tool that verifies the recorded boot
  never drifts from the code (CI + pre-push hook).
* **KVM acceleration:** `zig build run` auto-detects `/dev/kvm` — KVM is closer
  to real hardware than TCG, TCG stays the fast path for automated tests.
* **Changelog dev tool:** `tools/generate-changelog.sh` regenerates the full
  commit history with a single command (see Dev tools below).
* **Release workflow:** `.github/workflows/release.yml` — on a `v*` tag it runs
  the full verification and only then publishes `aster.iso` as a release asset.

### Fixed

* **Static code check:** Deduplicated I/O helpers, removed dead code, errors
  propagated instead of empty `catch {}`, virtio descriptor-table overflow
  guarded.
* **Debugging guide:** Rewritten with a verified GDB workflow (ISO boot +
  higher-half breakpoints), what works and what does not for embedded Lua.
* **Kernel stack overflow:** A 16.9 KiB directory-entry buffer overflowed the
  16 KiB ISR stack during directory lookup; stack raised to 64 KiB and the
  buffer reduced.
* **Page fault in low memory (handoff H3):** The PFA allocated frames below
  1 MiB that the bootloader's higher-half direct map does not map (memory map
  reports them usable, but the page table has no entry) — heap blocks placed
  there faulted on first touch. PFA now never allocates below 1 MiB.

---

## [0.5.0-alpha.1] — Milestone M5 — UI (desktop shell)

### Added

* **Desktop environment & window manager:** Shell split into `ui/` modules
  (theme, wm, repl, launcher, input, main); tiling (60/40 split, focus ring via
  gradient border) and floating windows; Hyprland-standard keybindings (Super
  key); Noctalia-style bar (launcher, clock, workspace capsules,
  volume/session placeholders); launcher with search; workspace switching,
  fullscreen, togglesplit and UI hot reload (F5).
* **Live transformation ("config is code"):** `gfx.invalidate()` repaints the
  environment without a key press; the `theme` table is data — changing a color
  takes effect live.
* **PS/2 mouse:** 3-byte packets, smooth kernel cursor (repaints only the
  pointer), independent mouse queue, robust device detection.
* **Error containment:** A Lua script error is caught by `pcall`, the shell
  hot-reloads — the desktop recovers without crashing the kernel.
* **Sysmon KI module:** Exposes real RAM from the page frame allocator and shows
  live used/total/percent.
* **Session menu:** Lock (fullscreen overlay), Logout (shell reload), Reboot
  (i8042 reset) via the new `power` KI module.

### Fixed

* **Input freeze:** Fixed concurrent mouse movement and typing — separate
  queues, shared i8042 controller handling (input-empty, read-modify-write
  config, stale ACK).
* **Mouse desync:** Packet resync on start bit 3, overflowed deltas rejected,
  valid data bytes 0xFA/0xAA no longer filtered.
* **Reload use-after-free:** `runtime.reload()` from the menu closed a
  mid-call `lua_State` — reload is now deferred out of the Lua call frame.

---

## [0.4.0-alpha.1] — Milestone M4 — Lua runtime

### Added

* **Lua 5.4.8 in the kernel:** Embedded interpreter (27 `.c` files) with a
  freestanding libc shim (custom openlibs: `base`, `coroutine`, `table`,
  `string`, `utf8`, `math`) — scripts run directly in the kernel, no host OS
  dependency.
* **Interactive REPL:** A Lua console starts after boot — type code, Enter runs
  it, `print()` writes to the screen; line editing and command history.
* **Lua bindings:** `gfx.*`, `input.next_event`, `time.ticks`, `sysmon.*` with
  strict type validation (floats rejected); the shell receives a ready `char`.
* **Hot reload (F5):** UI script changes take effect without a system restart.
* **GC budget per frame:** a `collectgarbage("step", ...)` budget in every
  `update()` keeps GC pauses off the hot render path.
* **Runtime tests for the bindings in QEMU:** the bindings are exercised in the
  real kernel context (a real `lua_State`), not host mocks.
* **Keyboard layout:** `input/layout.zig` infrastructure (US 105+) — maps
  `KeyCode`+shift/ctrl to a character, numpad, extended keys, Alt/AltGr layer.

### Fixed

* **Shift release:** 0xAA is the shift break scancode, not a self-test —
  `shift_pressed` no longer sticks after the first press.
* **Heap allocator:** Coalescing fix (previous + absorbed block), remapFn
  overlap, growth in contiguous blocks.

---

## [0.3.0-alpha.1] — Milestone M3 — Graphics

### Added

* **Framebuffer:** Limine GOP wrapped in a `Framebuffer` (base, width/height,
  pitch, bpp, color shifts).
* **Rendering engine:** `drawRect`, `blit`, `fillScreen`, `drawGlyph`,
  `drawText` with clipping — no heap allocation on the draw path.
* **Embedded VGA font (8×16):** Bitmap font (public domain) with `?` fallback.
* **Graphics API in KI:** `api/graphics.zig` with `GraphicsOp` 0–5 wired into
  `sys.dispatch`; host tests for renderer clipping/blit.
* **Event loop:** `poll → update → render` with render-on-dirty.
* **Text on screen:** Keyboard → ASCII with shift; console with wrap, scroll,
  backspace and cursor; typing visible in QEMU.

### Fixed

* **ISR register corruption:** `isr_common` saves/restores `%rax` — the timer
  IRQ interrupted a render and clobbered a live register.

---

## [0.2.0-alpha.1] — Milestone M2 — CPU

### Added

* **GDT/IDT:** 256 uniform ISR stubs, fault policy, `lidt` via a descriptor
  buffer.
* **Local APIC timer (1 kHz):** Periodic tick, LAPIC EOI, SVR init (APIC enable
  + spurious vector 0xFF ignored without EOI).
* **IOAPIC:** Maps 0xFEC00000 and programs IRQ1 → vector 0x21 for ISA IRQ
  delivery in APIC mode.
* **Input subsystem:** Hardware-neutral `KeyCode`/`KeyEvent` — the driver is only
  a producer, applications never see scancodes; USB HID can map to the same
  `KeyCode` without touching KI.
* **KI dispatch layer:** `api/sys.zig` — `Syscall`/`KiStatus`, `Debug.write`,
  self-test at boot.
* **Fault policy + backtrace:** `ASTER FAULT` dump (vec, err, rip, cr2, rbp)
  with a freestanding frame-pointer backtrace.
* **Runtime tests in QEMU:** In-kernel tests exit QEMU via `isa-debug-exit`
  (pass = exit 99, fail = exit 97).

### Fixed

* **PIC 8259 remap:** To vectors 0x20–0x2F (legacy fallback; active ISA IRQs run
  over IOAPIC).
* **Kernel size:** Removed `link_gc_sections = false`, which bloated the kernel
  7× (196 KB → 28.8 KB).

---

## [0.1.0-alpha.1] — Milestone M1 — Memory

### Added

* **Bitmap Page Frame Allocator:** 4 KiB pages, 1 bit per page, deterministic
  first-free allocation, zeroing on request, OOM as an error (never a panic);
  host unit tests (16).
* **First-fit heap allocator:** Boundary tags, coalescing, dynamic growth from
  the PFA — implements `std.mem.Allocator`.
* **Boot memory dump:** RAM layout (usable bytes, free pages) + heap allocator
  self-test.
* **Framebuffer cache attribute:** Verified from PTE + PAT MSR that Limine maps
  the framebuffer as **WC** (no frame-latency risk).

---

## [0.0.0-alpha.1] — Milestone M0 — Boot

### Added

* **Basic OS architecture:** Complete architectural specification of the kernel
  and system in Zig (spec/).
* **Kernel boots via Limine:** Working x86_64 long-mode start through the Limine
  bootloader in QEMU, serial marker `ASTER BOOT OK`.
* **Deterministic build:** Same commit + same Zig = identical binary hash
  (ADR-014); verified by `tools/verify-reproducible.sh`.
* **Serial driver & diagnostics:** Serial output for logging + troubleshooting
  infrastructure.
* **Basic tooling:** `zig build` (boot/iso/test), `tools/qemu-smoke.sh`,
  `tools/bench.sh`; MIT license; English README for the public repo.

---

## Dev tools

**`CHANGELOG.md` is hand-curated — never overwrite it with a generator.**

The raw commit history is regenerated separately:

- `tools/generate-changelog.sh` writes `CHANGELOG-commits.md` (raw, oldest
  first, verbatim).
- `tools/generate-changelog.sh --log` prints it to stdout without writing.
- `tools/generate-changelog.sh --help` shows the options.

### Why two files

- **`CHANGELOG.md`** — the curated, aggregated view (what the system can do,
  one version per milestone). Read this.
- **`CHANGELOG-commits.md`** — the raw, verbatim commit log; regenerated on
  demand, never edited by hand.

### Regenerate the raw commit history

1. **One-time alias setup (in a terminal):**
   ```bash
   git config alias.changelog '!bash tools/generate-changelog.sh'
   ```

2. **Regenerate:**
   ```bash
   git changelog            # writes CHANGELOG-commits.md
   git changelog --log      # prints to stdout (no write)
   git changelog --help     # help
   ```

### Why this approach

* **Two layers, no accidents:** readers get the curated `CHANGELOG.md`; the raw
  history is one command away and can never clobber it.
* **Always up to date:** anyone regenerates the raw history exactly when needed.
* **No merge conflicts:** developers do not overwrite each other's file in
  merge requests.
