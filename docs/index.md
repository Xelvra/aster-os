---
layout: home
title: Home
nav_order: 1
---

# Aster OS — Web

**Aster** is an experimental desktop operating system written in Zig. This site is the
introduction to the project's complete English documentation.

## Documentation language

The documentation has two different audiences, and therefore two different layers.

The **public documentation** (`README.md`) is **English**. The repository has been public
since M0, and the README is the main entry point for visitors.

The internal specification (`spec/*.md`) deliberately remains in **the developer's
language**. It is the author's **"second brain"**, not a marketing surface.

This separation is intentional.

* Before milestone M0, writing English documentation would have meant doing community
  marketing. That would slow iteration, distract from the
  code, and shift attention toward an audience.
* Writing in the developer's fastest language keeps the internal specification fast,
  consistent, and precise. The goal of `spec/` is to help the author think and build,
  not to present the project to outsiders.
* The English version of the specification is **not produced as one bulk translation**.
  It is created gradually as the English layer in `docs/` evolves. `spec/*.md` remains
  the source of truth, while the English equivalent is produced continuously during
  development.
* The original plan called for a bulk translation in M8. That plan was replaced on
  **2026-08-08**. English translation is therefore an ongoing process, not a milestone
  requirement.

> **Deviation from the original plan (recorded at M0):** the original plan called for
> English documentation from M4 onward, including the README. Because the repository has
> been public since M0, the README was translated immediately. The internal specification
> remains in the developer's language as described above.

This language split applies to **documentation only**.

**Code, comments, and commit messages are always English**
(`spec/code-style.md` §0).

## The two-layer strategy

The public web (`docs/`, GitHub Pages) is a **curated layer** over the internal
specification.

The principle is simple:

> **The developer's language = the brain. Translations = the face.**

One direction of flow. No duplication.

| Layer                     | Language                 | Role                                                                                                                                       |
| ------------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| [`spec/`](spec/README.md) | **Developer's language** | **Canonical source of truth.** The complete internal specification, written for the author. It is always current and can be edited freely. |
| `docs/` (this site)       | **English**              | **Curated public layer.** An English reflection of the specification, published to GitHub Pages.                                           |

### Rules that keep this honest

* **`spec/` is canonical.** Every page on this site is a faithful translation of a
  corresponding spec file: same sections, same facts, same structure. It is not a
  marketing summary. When the two disagree, **the spec wins**.

* **Translations are machine-made.** The author reviews them when they are synced.
  Each page records this with a `synced:` footer. If a nuance matters, follow the linked
  source in `spec/`.

* **One-way flow:** `spec → docs`. Never the reverse. A translation page is never
  projected back into the specification. Links follow the same direction: the website
  links to the repository; the repository does not depend on the website.

* **Sync is enforced by git, not by hand-edited dates.** Every translated page contains
  `source:` and `synced:` front matter. `tools/sync-docs.sh --check`, used by CI and the
  pre-push hook, fails when the source has changed by more than 14 days without its
  translation being updated. Editing a date cannot make a stale page look current.

* **Drift is design, not a bug.** The web may lag behind the specification. The public
  face is intentionally more stable; the brain is allowed to move fast.

* New things are written into `spec/` first. Translations move to the web when there is
  time to sync them.

* `CHANGELOG.md` and `README.md` remain English because they are part of the project's
  public interface.

## How to navigate this site

**All documentation is available through the navigation on the left.**

Every page there is an English translation of a corresponding source in `spec/`.

This home page is the only exception. It is an introduction to the documentation, not a
translation of a single spec file.

For a natural starting point, follow the order of the left navigation:

* **README** — project introduction, current status, milestone metrics, quick start, and
  prerequisites.

Each translated page contains a footer showing which source it was synced from and when.

When a nuance matters, the linked source in `spec/` is the authoritative answer.

---

Last audited on **2026-08-09**.
