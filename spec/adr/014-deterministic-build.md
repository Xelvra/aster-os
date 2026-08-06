# ADR-014 — Deterministický build

**Status:** Accepted
**Datum:** 2026-08-06

## Rozhodnutí
Cíl: stejný commit + stejná verze Zigu = stejný výstupní hash binárky.

## Odůvodnění
Reprodukovatelnost usnadní debug, CI i budoucí publikaci. Dosažitelná jen při pinningu
toolchainu (ADR-013), vendoru závislostí (ADR-012, ADR-007, ADR-011) a bez timestampů
v binárce.

## Důsledky
- Bez `__DATE__`/`__TIME__`, bez generovaných timestampů.
- Assety embedded ze statických zdrojů.
- Ověřovací skript: build dvakrát, porovnání hashe (výhledově).

## Související
- ADR-013
- `spec/verification.md` §3
