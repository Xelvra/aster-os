# ADR-006 — Generické Runtime API

**Status:** Accepted
**Datum:** 2026-08-06

## Rozhodnutí
`Runtime.spawn(module)` s `RuntimeKind { Lua, Wasm, Native }` místo specializovaného
`spawn_wasm()`. Žádné rozlézání runtime do kernelu. Vazba je vždy `Runtime → Program`,
nikdy `Kernel → Wasm` nebo `Kernel → Lua`.

## Odůvodnění
Zobecnění, které nic nestojí a ušetří pozdější přepisování. Kernel ani desktop nesmí vědět,
co konkrétní runtime je; dnes existuje jen Lua, zítra přibude Wasm bez změny rozhraní.

## Důsledky
- `spawn_wasm()` nikdy neexistuje jako veřejná funkce.
- První rok je `RuntimeKind.Lua` jediný reálný kind; ostatní jsou deklarované a připravené.

## Související
- ADR-007 (Lua), ADR-011 (wasm3)
- `spec/runtime.md`
