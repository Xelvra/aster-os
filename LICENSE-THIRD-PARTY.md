# LICENSE-THIRD-PARTY

This document is the **single place** where third-party licenses and acknowledgments
are recorded. Whenever anything foreign is added to Aster OS (library, tool, asset,
or an idea that inspires code), it is recorded here — including author, license, and
path. Rule: **never** add any third-party code or asset without an entry in this file.

All licenses listed below are **100% open source** and compatible with this project's
MIT license (`LICENSE`).

## Table of Contents

1. [Lua](#1-lua)
2. [Zig](#2-zig)
3. [Limine](#3-limine)
4. [VGA 8x16 font](#4-vga-8x16-font)
5. [Thematic inspiration](#5-thematic-inspiration)
6. [Own code based on open standards](#6-own-code-based-on-open-standards)
7. [Rules for future dependencies](#7-rules-for-future-dependencies)

---

## 1. Lua

| | |
|---|---|
| **What** | Lua 5.4.8 (scripting language), vendored source in `libs/lua-5.4/` |
| **Author** | Lua.org, PUC-Rio (Waldemar Celes, Roberto Ierusalimschy, Luiz Henrique de Figueiredo) |
| **License** | MIT (see `libs/lua-5.4/src/lua.h`, header at the end of the file) |
| **Copyright** | Copyright (C) 1994-2025 Lua.org, PUC-Rio |
| **Usage** | Embedded Lua runtime in the kernel — REPL, shell, KI bindings |

**Acknowledgments:** to the Lua authors for a clean, minimal scripting language that
became the foundation of the Aster OS user environment.

---

## 2. Zig

| | |
|---|---|
| **What** | Zig programming language + standard library (toolchain, `std`, build system) |
| **Author** | Andrew Kelley and contributors (Zig Software Foundation) |
| **License** | MIT |
| **Copyright** | Copyright (c) Zig contributors |
| **Usage** | The entire Aster OS is written in Zig; build, tests, deterministic build, compilation of Lua C sources |

**Acknowledgments:** to the Zig authors for a language that Aster OS is written in —
safe, deterministic, and excellent for operating system development.

---

## 3. Limine

| | |
|---|---|
| **What** | Limine bootloader (BIOS + UEFI stages, host tool `limine`), vendored in `libs/limine/` |
| **Author** | Mintsuki and contributors |
| **License** | BSD-2-Clause (see `libs/limine/LICENSE`) |
| **Copyright** | Copyright (C) 2019-2026 Mintsuki and contributors |
| **Usage** | Boot protocol — handoff (long mode, memory map, GOP framebuffer, serial), bootable ISO creation |

**Acknowledgments:** to the Limine authors for a stable, modern bootloader with a
simple protocol that Aster has used since the first bootable moment.

---

## 4. VGA 8x16 font

| | |
|---|---|
| **What** | Bitmap font 8x16 (ASCII 0x20–0x7E), embedded in `src/kernel/render/font_data.zig` |
| **Author** | Public domain — generated from `default8x16.psfu.gz` (VGA console font) |
| **License** | Public domain |
| **Usage** | Text rendering in the shell and REPL |

---

## 5. Thematic inspiration

| | |
|---|---|
| **What** | Concepts and look of the user environment — declarative color theme, keybinds as data, shell with panel/widgets, "config is code" |
| **Inspiration source** | Modern open-source desktop environments based on scriptable window managers and shells (Lua/TOML configuration) |
| **License** | Open source (MIT / BSD family) |
| **Usage** | Foundation of the Aster OS shell philosophy — UI is Lua code, changeable at runtime; theme as data |

**Acknowledgments:** to the community and authors of open-source desktop environments
that showed window managers and shells should be scriptable and configurable at
runtime. Aster OS builds its own implementation in Zig and Lua on these concepts.

---

## 6. Own code based on open standards

The following files are **Aster OS's own implementation**, but were created with the
conscious use of generally known techniques and standards (not copies of foreign code):

| File | Origin / standard |
|---|---|
| `src/kernel/lua/setjmp.s` | Own freestanding `setjmp`/`longjmp` for x86_64 (SysV ABI) |
| `src/kernel/lua/vsnprintf.c` | Own freestanding formatting for Lua (no libc) |
| `src/kernel/lua/libc.zig` + `libs/lua-5.4/include/` | Freestanding libc shim (string/ctype/stdio/math/time) for Lua |
| `src/kernel/drivers/ps2.zig` | PS/2 keyboard + mouse — standard protocol (scancode set 1) |
| `src/kernel/cpu/*` | Standard x86_64 CPU initialization (IDT, APIC, IOAPIC, GDT) |
| `src/kernel/input/layout.zig` | Standard US QWERTY keyboard layout |

---

## 7. Rules for future dependencies

1. **Every** third-party library/asset is added to `libs/` with its original license
   and recorded here.
2. Licenses must be **open source** (MIT/BSD/Apache/ISC/Public domain) — never
   proprietary.
3. Foreign code is not rewritten "in our own way" without retaining the copyright
   header and a mention here.
4. An idea or inspiration from a foreign project is recorded here as an
   acknowledgment (an "inspired by" row in section 6), even if the resulting code
   is our own.
5. Before committing any dependency change: this document is updated.

---

*Generated and maintained manually. All licenses are open source and compatible with
the MIT license of the Aster OS project (`LICENSE`).*
