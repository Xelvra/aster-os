# ADR-003 — Stabilní rozhraní od prvního dne

**Status:** Accepted
**Datum:** 2026-08-06

## Rozhodnutí
Každá funkce přístupná z Lua/UI jde přes pojmenované rozhraní
(`api/graphics.zig`, `api/input.zig`, `api/runtime.zig`, `api/sys.zig`), nikdy přímo do
interních struktur. API od prvního dne neví, že je všechno v Ring 0.

## Odůvodnění
Zajišťuje, že evoluce do mikrojádra nevyžaduje přepis aplikací. Je to nejlevnější pojistka
budoucnosti: dnes přímé volání funkce, zítra IPC zpráva — volající kód se nemění.

## Důsledky
- Žádný přímý přístup z Lua k framebufferu, alokátorům ani kernel strukturám.
- Porušení rozhraní = nový ADR + major bump KI verze.

## Související
- ADR-004 (KI), ADR-005 (renderer)
- `spec/kernel-interface.md`, `spec/invariants.md` (Architecture)
