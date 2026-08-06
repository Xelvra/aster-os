# ADR-010 — Žádný souborový systém, dokud nebude potřeba

**Status:** Accepted
**Datum:** 2026-08-06

## Rozhodnutí
main.lua, fonty a assety jsou zakompilované do binárky. Žádný souborový systém se
neimplementuje před milníkem M6 (editor/ukládání/konfigurace).

## Odůvodnění
FS je komplikace bez přidané hodnoty, dokud není co ukládat. Embedded assety zjednodušují
boot i build a jsou v souladu s deterministickým buildem (ADR-014).

## Důsledky
- `src/shell/main.lua` je `@embedFile` / `@embedBytes`.
- M6 přidá initfs (Limine initrd), pak **perzistenci ve standardním formátu** — nikdy
  vlastní (FAT32, ext2/ext4, ... dle potřeby v M6; FAT32 je příklad, ne cíl).
- Žádná perzistence před M6 (viz `spec/non-goals.md`).

## Související
- ADR-007, ADR-014
- `spec/roadmap.md` (M6)
