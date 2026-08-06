# ADR-007 — Lua 5.4 vendored, staticky, ne LuaJIT

**Status:** Accepted
**Datum:** 2026-08-06

## Rozhodnutí
Lua 5.4.x (aktuálně 5.4.8) je vendored jako C zdroj a kompiluje se staticky do image.
LuaJIT se nepoužívá.

## Odůvodnění
LuaJIT přináší W^X, assembler, architektonickou závislost a rozdíly v GC — zbytečná
složitost na Ring 0. Lua 5.4 je stabilní, malá, čisté C. Výkonově se benchmarkuje později,
až (a pokud) bude úzké hrdlo.

## Důsledky
- `libs/lua-5.4/` (vendored zdroj).
- `main.lua` embedded v binárce (ADR-010).
- Lua běží uvnitř managed runtime; viz přesné formulace v `spec/manifest.md`.

## Související
- ADR-006, ADR-010
- `spec/runtime.md`, `spec/roadmap.md` (M4)
