---
layout: home
title: Home
nav_order: 1
---

# Aster OS

> **Aster is an experimental desktop operating system written in Zig.**
>
> Aster currently targets **x86_64** (QEMU `q35`) — the only implemented architecture for
> now. A future port (e.g. ARM, RISC-V) is not excluded by design, but it is not a goal
> today and would need its own scope change (see [`spec/non-goals.md`](spec/non-goals.md)).
> The first implementation deliberately favors **simplicity over isolation**: the desktop,
> scripting engine, and runtime share a single address space to minimize complexity and
> maximize iteration speed. The public interfaces are designed as **stable abstractions**,
> so individual subsystems can later be moved into isolated processes **without changing
> application APIs**.

## How to read this documentation

**All documentation is in the navigation on the left** — every page there is an English
translation of a Czech source. This home page is the only exception: it is the
introduction, not a translation.

Aster's documentation is split into two layers on purpose, so there is exactly **one
source of truth** for every fact:

| Layer | Language | Role |
|---|---|---|
| [`spec/`](spec/README.md) | **Czech** | **Canonical source of truth.** The complete internal specification — written for the author, always current, edited freely. |
| `docs/` (this site) | **English** | **Translation layer.** A public, English reflection of the spec, published to GitHub Pages. |

Rules that keep this honest:

- **`spec/` is canonical.** Every page here is a faithful translation of a Czech spec
  file — same sections, same facts, same structure — not a marketing summary. When the
  two disagree, the Czech spec wins.
- **Translations are machine-made**, reviewed by the author when synced (`synced:`
  footer on each page). For any nuance, check the linked Czech source.
- **Links go one way only:** the website (`docs/`) links to the repository
  (`spec/`, `README.md`, ...) — never the reverse. The single source of truth lives in
  the repo.
- **Sync is enforced by git, not by hand-edited dates.** Each translated page carries
  `source:` + `synced:` front matter; `tools/sync-docs.sh --check` (CI + pre-push hook)
  fails when a page's source changed more than 14 days ago without the translation being
  updated. A page cannot fake being current by editing a date.

## Where to start

- **README** — the project intro (status, quick start, metrics); see the README page.
- **Architecture** — the design overview.
- **Milestones** — the M0–M10 roadmap.
- **Status** — what works right now.
- **Development** — build, test, and verification.

All of these are faithful English translations of the corresponding Czech specs.
