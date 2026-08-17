# THIRD-PARTY-NOTICES

This document is the **single place** where third-party licenses and acknowledgments
are recorded. Whenever anything foreign is added to Aster OS (library, tool, asset,
or an idea that inspires code), it is recorded here — including author, license, and
path. Rule: **never** add any third-party code or asset without an entry in this file.

All licenses listed below are **open source** and compatible with this project's MIT
license (`LICENSE`).

> **Traceability:** this document is maintained manually and must be re-checked
> against the source tree whenever a dependency, vendored file, or credited
> reimplementation changes — not just when something is added. Last manually
> cross-checked against the source tree at commit `4007885` (2026-08-17): every path,
> file reference, and provenance claim below was verified to exist and read as
> described. If you find a stale entry, fix it in the same change that caused the
> drift, per Rule 5 in §4.

## Table of Contents

1. [Limine](#1-limine)
2. [Lua](#2-lua)
3. [Own code based on open standards](#3-own-code-based-on-open-standards)
4. [Rules for future dependencies](#4-rules-for-future-dependencies)
5. [Thematic inspiration](#5-thematic-inspiration)
6. [VGA 8x16 font](#6-vga-8x16-font)
7. [Wasm3](#7-wasm3)
8. [Zig](#8-zig)

---

## 1. Limine

| Field | Value |
|---|---|
| **What** | Limine bootloader (BIOS + UEFI stages, host tool `limine`), vendored in `libs/limine/` |
| **Author** | Mintsuki and contributors |
| **License** | BSD-2-Clause (see `libs/limine/LICENSE`) |
| **Copyright** | Copyright (C) 2019-2026 Mintsuki and contributors |
| **Usage** | Boot protocol handoff — base revision negotiation, long-mode entry, HHDM (higher-half direct map) offset, GOP framebuffer, memory map, boot modules (initrd tar); bootable ISO creation via the host `limine` tool. Aster's own serial (COM1 UART) initialization is independent of Limine and is not part of this handoff. |

**Acknowledgments:** to the Limine authors for a stable, modern bootloader with a
simple protocol that Aster has used since the first bootable moment.

---

## 2. Lua

| Field | Value |
|---|---|
| **What** | Lua 5.4.8 (scripting language), vendored source in `libs/lua-5.4/` |
| **Author** | Lua.org, PUC-Rio (Roberto Ierusalimschy, Luiz Henrique de Figueiredo, Waldemar Celes) |
| **License** | MIT (see `libs/lua-5.4/src/lua.h`, header at the end of the file) |
| **Copyright** | Copyright (C) 1994-2025 Lua.org, PUC-Rio |
| **Usage** | Embedded Lua runtime in the kernel — REPL, shell, KI bindings |

**Acknowledgments:** to the Lua authors for a clean, minimal scripting language that
became the foundation of the Aster OS user environment.

---

## 3. Own code based on open standards

Aster OS does not vendor or copy the following from anywhere — they are the
project's **own implementations**, written from scratch, of publicly documented
interfaces and on-disk formats. They are listed here for the same reason as §5
(thematic inspiration): crediting the source of the design even where the resulting
code is entirely original (see Rule 4 in §4).

### 3.1 Freestanding C interfaces for the vendored Lua runtime

| File | Standard |
|---|---|
| `src/kernel/lua/setjmp.s` | Own freestanding `setjmp`/`longjmp` for x86_64 (SysV ABI) |
| `src/kernel/libc.zig` + `libs/lua-5.4/include/` | Shared kernel libc (string/ctype/stdio/math/time, including `vsnprintf`), written in Zig — no separate C source file |

### 3.2 On-disk format parsers based on published specifications

| File | Standard |
|---|---|
| `src/kernel/fs/gpt.zig` | GUID Partition Table layout, as documented in the UEFI Specification |
| `src/kernel/fs/ext2.zig` | ext2 on-disk format (superblock, block group descriptors, inodes, directory entries), read-write subset per ADR-023 |

---

## 4. Rules for future dependencies

1. **Every** third-party library/asset is added to `libs/` with its original license
   and recorded here.
2. Licenses must be **open source** (MIT/BSD/Apache/ISC/public domain) — never
   proprietary.
3. Foreign code is not rewritten "in our own way" without retaining the copyright
   header and a mention here.
4. An idea or inspiration from a foreign project is recorded here as an
   acknowledgment (an "inspired by" row in the Thematic inspiration section, or an
   entry in §3 for a from-scratch implementation of a public standard), even if the
   resulting code is our own.
5. Before committing any dependency, vendored-file, or credited-reimplementation
   change: this document is updated **in the same change**, not as a follow-up.

---

## 5. Thematic inspiration

| Field | Value |
|---|---|
| **What** | Concepts and look of the user environment — declarative color theme, keybinds as data, shell with panel/widgets, "config is code" |
| **Primary inspiration** | [CachyOS / cachyos-hypr-noctalia](https://github.com/CachyOS/cachyos-hypr-noctalia) — settings and dotfiles for the CachyOS Hyprland desktop (color palette, window decorations, workspace capsules, Hyprland-standard keybindings) |
| **License** | The upstream repository carries **no license file** (all rights reserved by default) — therefore Aster does **not** copy or vendor any of its files or assets |
| **Usage** | Aster reimplements the visual concept in its own code: colors adapted into `ui/theme.lua`, keybinds as data in `ui/input.lua`, window decorations in `ui/wm.lua` (see `spec/desktop-ui.md`) |

**Acknowledgments:** to the CachyOS community and the authors of
[cachyos-hypr-noctalia](https://github.com/CachyOS/cachyos-hypr-noctalia) for the
polished desktop look and the "config is code" spirit. Aster OS does **not** use any
file from that repository — it builds its own implementation in Zig and Lua, inspired
by the visual concept (colors as such are not copyrightable) and the Hyprland keybind
conventions, which Aster reimplements as data in its own shell.

---

### 5a. Architectural inspiration — AwesomeWM

| Field | Value |
|---|---|
| **What** | The **architectural pattern** "window manager as Lua code" — the window manager is a Lua program, the display server/kernel supplies only primitives (windows, drawing, input). Aster's own shell (`src/kernel/lua/ui/`) follows this pattern: the kernel provides the renderer/input/window primitives via KI bindings, and Lua owns the window-manager logic (tiling layout, workspaces, bar, windows). |
| **Source** | [AwesomeWM](https://awesomewm.org/) (X11 window manager written in Lua, MIT license, actively developed since 2007) |
| **License** | MIT (AwesomeWM is MIT-licensed) |
| **Usage** | **No code or asset is taken from AwesomeWM.** Aster reimplements the window-manager logic in its own Lua from scratch. What Aster *does* borrow is the proven pattern and the rationale that a Lua-based WM is maintainable long-term. Future Aster WM features that mirror a well-known AwesomeWM concept (e.g. signals between components, declarative window rules) are documented as such in `spec/lua-wm.md` §14 with an explicit "taken from AwesomeWM, reimplemented" note — see D11. |

**Acknowledgments:** to the AwesomeWM authors and community for proving, since 2007,
that a window manager written in Lua is a viable, maintainable architecture — the
same pattern Aster OS uses with the kernel in the place of X11. Aster does **not** use
any code or asset from AwesomeWM; the implementation is original Aster code, inspired
by the pattern.

---

## 6. VGA 8x16 font

| Field | Value |
|---|---|
| **What** | Bitmap font 8x16 (ASCII 0x20–0x7E), embedded in `src/kernel/render/font_data.zig` |
| **Author** | Generated from `default8x16.psfu.gz`, the standard VGA console font distributed with the Linux `kbd` package |
| **License** | Public domain, per the common distribution status of this specific console font file |
| **Usage** | Text rendering in the shell and REPL |

**Note on provenance:** `default8x16.psfu.gz` is widely redistributed as a
public-domain / unencumbered bitmap font and carries no separate license file within
the `kbd` package itself. If this font is ever redistributed outside this project (as
opposed to used internally, as here), re-verify its status against the exact `kbd`
package version it was sourced from — bitmap console fonts as a category have mixed
provenance across distributions, and "public domain" here describes this specific
glyph set, not console fonts in general.

---

## 7. Wasm3

| Field | Value |
|---|---|
| **What** | wasm3 (WebAssembly interpreter, C), vendored in `libs/wasm3/` |
| **Author** | wasm3 contributors |
| **License** | MIT (see `libs/wasm3/LICENSE`) |
| **Usage** | WebAssembly runtime for `Runtime.spawn(.Wasm)` — hosts Aster wasm programs (Phase A test programs `hello`/`fault`) behind the generic Runtime API (ADR-006, ADR-011); compiled with PIC into the kernel |

**Acknowledgments:** to the wasm3 authors for a small, embeddable WebAssembly
interpreter that fit the kernel's constraints.

---

---
## 8. Zig

| Field | Value |
|---|---|
| **What** | Zig programming language + standard library (toolchain, `std`, build system) |
| **Author** | Andrew Kelley and contributors (Zig Software Foundation) |
| **License** | MIT |
| **Copyright** | Copyright (c) Zig contributors |
| **Usage** | The Aster OS kernel is written in Zig, with a small amount of freestanding x86_64 assembly where Zig's inline asm cannot express the required construct (`src/kernel/cpu/isr.s`, `src/kernel/lua/setjmp.s` — both original, not third-party, see §3.1); build, tests, deterministic build, and compilation of the vendored Lua and wasm3 C sources are all driven by `build.zig`. |

**Acknowledgments:** to the Zig authors for a language that Aster OS is written in —
safe, deterministic, and excellent for operating system development.

---

*Generated and maintained manually. All licenses are open source and compatible with
the MIT license of the Aster OS project (`LICENSE`).*
