# ADR-011 — wasm3 později, šev Runtime → Program

**Status:** Accepted
**Datum:** 2026-08-06

> **Status update (2026-08-17):** wasm3 je **implementováno** — `libs/wasm3/`
> vendored (`2fcfd98`), `Runtime.spawn(.Wasm)` spouští Fázi A testovací programy
> `hello`/`fault` (`c486dee`). Wasm glue žije v `src/kernel/wasm/` za `api/runtime.zig`
> (composition-root výjimka, viz ADR-006). Rozhodnutí „malý embedded interpreter
> (wasm3, ne wasmi/vlastní)" beze změny.

## Rozhodnutí
Pro M7 se použije wasm3 (C, MIT, malý embedded interpreter), spouštěný přes `Runtime.spawn()`.
Nepoužívá se wasmi (Rust) ani vlastní interpreter.

## Odůvodnění
wasm3 je malý; wasmi by táhl druhý toolchain; vlastní interpreter je YAGNI. Do té doby
existuje jen `RuntimeKind.Lua` — Wasm je deklarovaný, ne implementovaný.

## Důsledky
- `libs/wasm3/` přibyl v M7 (`2fcfd98`); `src/kernel/wasm/` nese cimport + hostitele
  a `src/kernel/apps/` testovací programy.
- Kernel mimo `api/runtime` nezná žádný Wasm-specifický kód — vazba je vždy
  `Runtime → Program`; jediný konkrétní runtime ví `api/runtime.zig` (composition root).

## Související
- ADR-006
- `spec/runtime.md`, `spec/roadmap.md` (M7)
