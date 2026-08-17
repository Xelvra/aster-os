# Contributing to Aster OS

Thanks for your interest. Aster OS is an experimental, alpha hobby operating
system written in Zig. This document is short on purpose — the authoritative
details live in the internal specifications (`spec/*.md`), referenced below.

## Project state

Read first:

- [`README.md`](README.md) — what the project is and where it stands.
- [`spec/architecture.md`](spec/architecture.md) — design overview and
  terminology (Czech).
- [`spec/roadmap.md`](spec/roadmap.md) — milestones M0–M10 and quality
  metrics (Czech).
- [`spec/non-goals.md`](spec/non-goals.md) — what the system deliberately does
  not do (Czech).

The repository is public, but the system is far from usable — expect rough
edges everywhere.

## Setting up

See [`spec/verification.md`](spec/verification.md):

- Zig pinned in `.zig-version` (official tarball, not a distro package).
- QEMU (`qemu-system-x86_64`), xorriso, mtools.
- Limine, Lua 5.4.8 and wasm3 are vendored in `libs/` — no system packages.

After cloning, install the git hooks:

```bash
./tools/install-hooks.sh
```

## Development workflow

### Verify before you finish

Run the pipeline in order; on the first failure, fix and restart from step 1:

```bash
zig fmt --check .
zig build
zig build test
zig build shell-test
./tools/qemu-smoke.sh
./tools/qemu-test.sh
./tools/verify-reproducible.sh
./tools/capture-boot.sh --check
./tools/sync-docs.sh --check
```

A task is done only when all of the above pass and the report includes the
real command output. Full Definition of Done:
[`spec/verification.md`](spec/verification.md).

### Bootable commit (ADR-016)

**Every commit must leave the system runnable in QEMU.** A broken boot is
fixed immediately, never "in a few commits". The pre-push hook verifies the
boot log (`boot-log.md`) still matches the code via
`./tools/capture-boot.sh --check`.

### Architecture decisions (ADR)

- Every architectural decision is a numbered ADR: `spec/adr/NNN-name.md`
  (one file per decision).
- A decision is never edited after the fact — a change of mind is a **new**
  ADR that references the old one. Numbers are never reused or deleted.
- Interface (KI) changes are an ADR, never a silent edit.

### Commits

- Commit messages are **English**, with a subject and a body describing the
  actual change.
- Each commit must leave the system bootable (see above).
- Keep commits focused; do not mix unrelated changes.
- The aggregated `CHANGELOG.md` is **hand-curated**. Regenerate the raw commit
  history via `tools/generate-changelog.sh` (writes `CHANGELOG-commits.md`) —
  never overwrite the aggregated file with it.

### Style

- Code, comments, identifiers, and commit messages: **English**.
- Internal specifications (`spec/*.md`): **Czech** by design (the author's
  working documentation); public documentation and code: **English**.
- Follow the module structure, contracts, and memory rules in
  [`spec/code-style.md`](spec/code-style.md) and the invariants in
  [`spec/invariants.md`](spec/invariants.md).
- **Allowed author-written languages: Zig, Lua and Assembly only.** Any other
  language (C, Rust, ...) needs explicit approval — C in `libs/` is vendored,
  not the author's.

## Language

English for anything visible to others (code, commits, issues). Czech is used
only inside `spec/*.md`, the author's internal documentation. Writing an issue
or a PR in English is appreciated; the project is small and the maintainer can
help with phrasing.

> **Language stats:** the GitHub language bar reflects only the author's
> application code (Zig + Lua + kernel C/ASM). Build/test scripts
> (`tools/`, `hooks/`), vendored dependencies (`libs/`) and documentation are
> excluded via `.gitattributes` — please don't add code there that would
> belong to those categories.

## Getting help

- Stuck on a crash or hang? [`spec/debugging.md`](spec/debugging.md) and
  [`spec/troubleshooting.md`](spec/troubleshooting.md) document known pitfalls.
- Open an issue for questions, bugs, or ideas.
