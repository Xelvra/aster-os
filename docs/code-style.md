---
layout: default
title: code-style
nav_order: 2
source: spec/code-style.md
synced: 2026-08-14
---

# Code Style — Code Philosophy and Rules

**Status:** Current design
**Purpose:** Rules for code structure and module design. They do not replace
Zig's naming conventions, but complement them with project-level discipline.

> Goal: code that can be understood six months later without context. Explicitness and small
> modules matter more than cleverness.

---

## 0. Language (code vs. documentation)

* **Code, comments, annotations, docstrings, identifiers, and commit messages: in English.**
  Code is a publicly shared artifact, and English is its default language.
* **Public documentation (`README.md`): in English** (the repository is public from M0).
* **Internal specifications (`spec/*.md`): in Czech** (the author's second brain). Exceptions
  are established conventions such as file, directory, and service names, technical terms
  (framebuffer, syscall, Renderer, Runtime, ADR statuses, etc.).
* Comments in code that explain "why" must be in English. Czech text does not belong in code.

### Document naming (`spec/*.md`, root files)

* **Lowercase**, single-word names where possible (`memory.md`, `input.md`, `timer.md`).
* **Compound names use kebab-case** (`kernel-interface.md`, `non-goals.md`, `code-style.md`,
  `desktop-ui.md`).
* **Descriptive**, without unnecessary words ("overview", "guide", "document" only when they
  make sense), and without marketing terms (no "whitepaper", "blueprint").
* **No versions or dates in filenames** — versions belong inside the document / in git history.
* Established abbreviations and conventions (`README.md`, `CHANGELOG.md`, `LICENSE`,
  `adr/NNN-name.md`, `handoffs/NNN-name.md`) remain unchanged.

### Project name (Aster OS)

The official project name is **Aster OS** and it follows this convention:

- **Official names and headings — always "Aster OS":** the repository name, chapter
  headings, document titles, intro paragraphs, and marketing/presentation material.
- **Body text and flow — "Aster" is acceptable:** once the full name has been used in a
  chapter or paragraph and the context is fully clear, continuous prose may keep using
  just "Aster" (repeating "OS" would read as clunky).
- **Code, API, and CLI — single word, no space:** `aster` (e.g. `aster-kernel`,
  `aster_ipc`, `aster.iso`, `zig-out/bin/aster`). The name is never written with a space
  or as "Aster OS" in code.

---

## 1. Design Principles

* **Prefer explicitness over implicit behavior.** No magic: no metamodels, background code
  generation, implicit conversions, or hidden side effects.
* **Small modules, single responsibility.** A file does one clearly describable thing. If
  describing a module requires "and", split it.
* **No singletons.** State is passed explicitly (struct instances), not shared globally.
* **No global mutable state unless it is hardware-related.** Exceptions:
  - device registries, framebuffer memory, atomic event queues — these are
    hardware/interrupt-context concerns, not program-level global variables;
  - **bootstrap:** the `kernel_stack` in `main.zig` (a fixed stack is needed
    before the allocator exists);
  - **composition-root singletons in the KI modules (`api/*`):** one state per
    module (e.g. `api/storage.zig` handle table, `api/graphics.zig`), a
    deliberate registry exception — never a per-feature global.
* **KISS + YAGNI.** Use the simplest solution that works. Do not add abstractions "for
  future use" — see `spec/non-goals.md`.
* **DRY with common sense.** Repeated logic should be extracted; two things that will evolve
  independently should not be artificially coupled.

---

## 2. Contracts and Visibility

* **Every public function has a contract.** A docstring (or an expressive name + documentation)
  states: inputs, outputs, errors, and what may be called. See `spec/kernel-interface.md`
  for KI.
* **Only what is meant to be public is public.** Internal helper functions are `pub` only when
  they are called by another module; otherwise they remain private. KI modules in `api/` are
  the only public surface.
* **No silent failures.** A function that can fail returns `KiStatus` / an error value.
  No empty `catch` without justification.

---

## 3. Memory

* **Allocation/free must be traceable.** The allocator is passed explicitly; ownership
  (who allocated, who frees) is visible from the function signature. No hidden allocations
  in pure functions.
* **No allocation on critical paths** (IRQ, rendering, event-loop rendering) — Performance
  invariant, `spec/invariants.md`.
* **Prefer stack and static buffers** in the kernel and renderer.
* **Immutable where it makes sense** — `const`, immutable data by default.

---

## 4. Structure and Naming

* `snake_case` for functions and variables, `PascalCase` for types, `UPPER_SNAKE_CASE` for
  constants (Zig conventions).
* No shadowing of built-in names (`list`, `id`, ...).
* Modules are ordered by dependency: `api/*` at the top (public), internal layers below them.
* Comments explain "why", not "what". What the code does should be readable from the code itself.

---

## 5. Threads, IRQ, Shared State

* IRQ handler: atomic operations on pre-allocated structures. No locks, no allocations,
  no recursion (Safety invariant).
* Shared state between IRQ and the event loop must use a documented mechanism only (ring buffer).

---

## 6. Code Review Checklist

Before approving any change:

* [ ] Code and comments are in English (documentation in Czech — see §0).
* [ ] The file/function name corresponds to a single responsibility.
* [ ] No singleton / new global mutable state (except hardware-related state).
* [ ] Public functions have contracts.
* [ ] Allocation/free is traceable from the function signature.
* [ ] No allocation in IRQ / rendering / event-loop rendering.
* [ ] No silent failures.
* [ ] No magic, no implicit conversions.
* [ ] `zig fmt --check` and `zig build test` pass (`spec/verification.md`).

---

Last synced from [`code-style.md`](https://github.com/Xelvra/aster-os/blob/main/spec/code-style.md) on **2026-08-14**.
