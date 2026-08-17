# ADR-002 — Single Address Space, Ring 0

**Status:** Accepted
**Datum:** 2026-08-06

## Rozhodnutí
Vše běží v jednom adresním prostoru s plným oprávněním. Žádné přepínání CR3, žádné TLB
flushe, žádné ring přechody.

## Odůvodnění
Přímá implementace cíle "nejrychlejší + nejmenší". Izolace se řeší na úrovni jazyka:
Lua skripty a Wasm moduly běží uvnitř managed runtime (ADR-007, ADR-011), což snižuje
riziko libovolné paměťové korupce oproti nativnímu Zig kódu. Plnou moc má jen námi psaný
Zig kód.

## Důsledky
- Bezpečnostní model = "důvěřuj managed runtime" (Lua VM, Wasm). Detail viz
  `spec/invariants.md` (Architecture) a `spec/non-goals.md`.
- Žádný VMM / per-proces adresní prostory zatím (výhled oddělení do Ring 3, ADR-018).

## Související
- ADR-001, ADR-007, ADR-011
- `spec/invariants.md`, `spec/non-goals.md`
