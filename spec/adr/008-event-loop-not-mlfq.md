# ADR-008 — Scheduler: událostní smyčka, ne MLFQ

**Status:** Accepted
**Datum:** 2026-08-06

## Rozhodnutí
První verze má jedinou událostní smyčku `while(true) { poll(); update(); render(); }`.
Žádný preemptivní plánovač, žádné MLFQ.

## Odůvodnění
Pro UI stačí smyčka; MLFQ je předčasná optimalizace. Preemptivní round-robin se přidá až
s reálnými wasm/nativními tasky (M7).

## Důsledky
- Jádro je reaktivní (IRQ → atomická fronta → smyčka), nikoli preemptivní.
- Timer slouží pro ticky a měření, ne pro preempci.

## Související
- ADR-002
- ADR-017 (concurrency model pro M7 — rozšiřuje toto rozhodnutí o preempci)
- `spec/input.md`, `spec/roadmap.md` (M7)
