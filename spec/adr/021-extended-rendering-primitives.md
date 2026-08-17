# ADR-021 — Rozšířená renderovací primitiva pro UI (roundRect, border, gradient)

**Status:** Accepted
**Datum:** 2026-08-08

## Rozhodnutí
Framebuffer vrstva rozšiřuje minimální sadu z ADR-009 o `roundRect()`, `rectBorder()`
a `gradientBorder()` (zaoblené rohy, ohraničení, lineární gradient po obvodu) — přidáno
v M5 pro desktop shell.

## Odůvodnění
ADR-009 odložil rounded corners s odůvodněním „až bude reálný důvod". V M5 ten důvod
nastal: desktop shell (Noctalia-style) potřebuje zaoblené kaple v taskbaru, border oken
a gradientní zvýraznění aktivního okna. Přidávají se **na konec** číslování KI operací
(ops 7–9), takže nedochází k porušení §4 pravidel KI (čísla se nemění, jen přibývají).

## Důsledky
- Nové sub-op kódy `round_rect = 7`, `rect_border = 8`, `gradient_border = 9` v
  `spec/graphics.md` §2 — zmrazené.
- Všechna tři primitiva zůstávají **bez alokace a deterministická** (invarianty
  Performance, `spec/invariants.md`); clipping na framebuffer je povinný.
- Alpha blending a stb_truetype (TTF) **zůstávají odložené** dle ADR-009 — žádný
  reálný důvod je zatím nevyžaduje.

## Související
- ADR-009 (původní minimální sada, tímto rozšířená)
- ADR-005 (renderer jako samostatná vrstva)
- `spec/graphics.md` §2 a §4
