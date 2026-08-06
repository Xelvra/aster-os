# ADR-019 — Bootloader gate: kernel nezávisí na typech bootloaderu

**Status:** Accepted
**Datum:** 2026-08-06

## Rozhodnutí
Kernel **nikdy nepracuje přímo s typy bootloaderu** (Limine structy). Handoff se hned
na začátku (M0) přeloží do **kernel-owned `BootInfo`**: offset vyšší poloviny (HHDM),
geometrie framebufferu, fyzická paměťová mapa. Zbytek kernelu vidí jen `BootInfo`.

## Odůvodnění
- Jedno překladiště znamená, že konkrétní bootloader (dnes Limine, ADR-012) je
  **vyměnitelný bez zásahu do zbytku kernelu** — stejný princip jako KI (ADR-004),
  jen o jednu vrstvu níž.
- Vlastněná data místo ukazatelů do bootloader paměti → deterministická životnost,
  žádné závislosti na tom, jak dlouho Limine handoff struktury žijí.
- Výhody Limine zůstávají (ADR-012): bootloader dělá těžkou práci (GOP, memory map,
  serial), my jen přečteme a přeložíme.

## Důsledky
- `src/kernel/boot/` je **jediné místo**, které importuje Limine hlavičky.
- `BootInfo` je vlastní Zig struct; mapování 1:1, žádná duplicitní logika.
- Framebuffer a memory map se z `BootInfo` předávají dál (M1 PFA, M3 graphics).
- Platí od M0; neimplementuje se dřív, než se začne psát boot (fáze M0).

## Související
- ADR-012 (Limine), ADR-014 (determinismus — vlastněná data),
  `spec/kernel-interface.md`, `spec/roadmap.md` (M0)
