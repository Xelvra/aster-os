# ADR-001 — Evoluční architektura (SASOS → mikrojádro později)

**Status:** Accepted
**Datum:** 2026-08-06

## Rozhodnutí
Začít jako single-address-space systém v Ring 0. Oddělení do izolovaných procesů je cíl,
ne výchozí stav — přijde až po ověření, že architektura dává smysl.

## Odůvodnění
Plné mikrojádro vyžaduje před prvním oknem VFS, PCI server, Process Manager, ELF loader,
Window Server, driver framework a capability manager — měsíce infrastruktury bez viditelného
výsledku. Mikrojádro navíc obětuje výkon (ring přechody, TLB flushe) za izolaci, která není
v hobby fázi nejvyšší prioritou. Stabilní rozhraní (ADR-003) umožní migraci bez přepisování.

## Důsledky
- `src/kernel/` obsahuje i uživatelské služby; `src/shell/` je součást image.
- Izolace je až výhledový cíl (M8+), nikoli požadavek na první iteraci.

## Související
- ADR-002 (single address space), ADR-003 (stabilní rozhraní)
- `spec/manifest.md`, `spec/roadmap.md`
