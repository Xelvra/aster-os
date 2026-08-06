# ADR-012 — Limine bootloader

**Status:** Accepted
**Datum:** 2026-08-06

## Rozhodnutí
Bootloader = Limine (64-bit, memory map, GOP framebuffer, initrd; oficiální Zig příklad).
Vlastní bootloader se nepíše.

## Odůvodnění
Vlastní bootloader je zbytečná práce bez přidané hodnoty pro cíle projektu. Limine řeší
long mode, UEFI/BIOS, GOP a memory map. Boot čas mimo naši kontrolu (firmware/DRAM init) —
měříme jen od handoff (viz `spec/roadmap.md`).

## Důsledky
- `libs/limine/` (vendored binárky + hlavičky, fixní revize).
- Handoff přes Limine protocol struktury.

## Související
- ADR-014 (deterministický build — vendor místo pull)
- `spec/verification.md`, `spec/roadmap.md` (M0)
