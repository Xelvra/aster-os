# Security Policy

Aster OS is an **experimental, alpha hobby operating system**, not production
software. It runs in QEMU, has no isolation (single address space, Ring 0), and
is not intended for untrusted inputs or real hardware yet. Please read the
following so we are both on the same page.

## Reporting a vulnerability

Security-relevant bugs are welcome like any other bug report:

- **Preferred:** open a GitHub [Security Advisory](https://github.com/Xelvra/aster-os/security/advisories)
  (private by default). If you prefer a public issue, open one with `[security]`
  in the title.
- Include: the commit/version you tested, QEMU flags used (if any), the
  trigger, and the observed behavior.
- Please **do not** publish exploit details before a fix lands (responsible
  disclosure). If you already published them, say so in the report.

## What to expect

This is a solo hobby project; there is no security team and no SLA.

- **Response:** best effort, typically within days — not hours.
- **Fixes:** in a regular commit (there is no release cadence; the current
  version is `0.7.0-alpha.2`, tracked in `.version`).

## Out of scope

The following are acknowledged and generally **not** treated as vulnerabilities:

- Bugs exploitable only via physical access or malicious native code running in
  the kernel's address space — the system has no security boundary by design
  (see `spec/non-goals.md` and `spec/architecture.md`).
- Missing mitigations for classes of bugs that are accepted non-goals (e.g. no
  MMU isolation, no ASLR, no SMEP/SMAP enforcement).
- Issues in third-party components exactly as shipped upstream (Limine, Lua, wasm3).
- Performance or stability problems without a security impact.

If in doubt, file the report anyway — worse to be told "out of scope" than to
stay silent.
