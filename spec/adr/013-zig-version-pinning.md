# ADR-013 — Pinning Zigu mimo název projektu

**Status:** Accepted
**Datum:** 2026-08-06

## Rozhodnutí
Verze Zigu se nedrží v názvu projektu, ale v souboru **`.zig-version`** (aktuálně `0.16.0`).
`build.zig` ověří přesnou verzi. README odkazuje na `.zig-version`.

## Odůvodnění
Jednodušší údržba při upgradech; verze je součást reprodukovatelnosti (ADR-014), ne identity
projektu. Distro balíček (pacman) může mít zpoždění — doporučuje se oficiální tarball.

## Důsledky
- `.zig-version` v kořeni.
- Kontrola verze v `build.zig`.
- Instalace: oficiální tarball / distro balíček, viz `.zig-version`.

## Související
- ADR-014
- `spec/verification.md`
