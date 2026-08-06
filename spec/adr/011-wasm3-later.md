# ADR-011 — wasm3 později, šev Runtime → Program

**Status:** Accepted
**Datum:** 2026-08-06

## Rozhodnutí
Pro M7 se použije wasm3 (C, MIT, malý embedded interpreter), spouštěný přes `Runtime.spawn()`.
Nepoužívá se wasmi (Rust) ani vlastní interpreter.

## Odůvodnění
wasm3 je malý; wasmi by táhl druhý toolchain; vlastní interpreter je YAGNI. Do té doby
existuje jen `RuntimeKind.Lua` — Wasm je deklarovaný, ne implementovaný.

## Důsledky
- `libs/wasm3/` přibude až v M7.
- Kernel nepřijme žádný Wasm-specifický kód — vše je za `Runtime.spawn`.

## Související
- ADR-006
- `spec/runtime.md`, `spec/roadmap.md` (M7)
