# ADR-015 — Měření po každém milníku

**Status:** Accepted
**Datum:** 2026-08-06

## Rozhodnutí
Po každém milníku se měří kvalitní metriky: doba od kernel entry do prvního snímku, frame
latency (p99), velikost binárky, RAM usage, compile time. Hodnoty se zapisují do
`spec/roadmap.md`.

## Odůvodnění
Drží cíl "nejrychlejší + nejmenší" naživu; bez měření driftne. Žádná feature není hotová,
dokud nejsou zapsané metriky.

## Důsledky
- `tools/bench.sh`.
- Tabulka v `spec/roadmap.md` §2 — hodnoty jako rozsahy/cíle, ne falešně přesná čísla.

## Související
- ADR-016
- `spec/roadmap.md`, `spec/verification.md`
