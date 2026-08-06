# ADR-009 — Minimální renderovací primitiva

**Status:** Accepted
**Datum:** 2026-08-06

## Rozhodnutí
Framebuffer vrstva zná pouze `fillRect()`, `blit()`, `glyph()`. Alpha blending, rounded
corners, stb_truetype — až bude reálný důvod.

## Odůvodnění
KISS + YAGNI. Většina UI jde postavit na základních primitivech. Přidávat složitost
dopředu znamená přesně ten druh "plánování příliš dopředu", kterému se bráníme.

## Důsledky
- `src/kernel/fb/` je malý a deterministický (žádné alokace na kritické cestě).
- Seznam povolených operací v `spec/graphics.md` §2.

## Související
- ADR-005
- `spec/graphics.md`, `spec/invariants.md` (Performance)
