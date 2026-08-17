# ADR-006 — Generické Runtime API

**Status:** Accepted
**Datum:** 2026-08-06

> **Status update (2026-08-17):** `RuntimeKind.Wasm` je od M7 **reálný kind** —
> `Runtime.spawn(.Wasm)` spouští Fázi A testovací programy `hello`/`fault`
> (`c486dee`). Jen `RuntimeKind.Native` zůstává deklarovaný (vrací
> `NotSupported`). Vazba `Runtime → Program` drží; konkrétní runtime jméno zná jen
> `api/runtime.zig` (composition-root výjimka — zbytek kernelu ne).

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
