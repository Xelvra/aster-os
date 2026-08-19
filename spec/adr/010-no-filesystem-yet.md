# ADR-010 — Žádný souborový systém, dokud nebude potřeba

**Status:** Superseded by ADR-023
**Datum:** 2026-08-06

> **Status update (2026-08-17):** ADR-010 je **dokončen a superseded ADR-023**.
> Od M6 existuje persistentní backend (ext2, read-only, od M7.1 read-write) a shell se
> čte z **initrd taru** (Limine module) — ne z `@embedFile` do binárky. Zůstává v platnosti:
> nikdy vlastní on-disk formát (viz ADR-023).

## Rozhodnutí
main.lua, fonty a assety jsou zakompilované do binárky. Žádný souborový systém se
neimplementuje před milníkem M6 (editor/ukládání/konfigurace).

## Odůvodnění
FS je komplikace bez přidané hodnoty, dokud není co ukládat. Embedded assety zjednodušují
boot i build a jsou v souladu s deterministickým buildem (ADR-014).

## Důsledky (platnost M0–M6, nyní superseded)

- Shell v `src/kernel/lua/ui/` (theme, wm, repl, launcher, input, main) byl `@embedFile`
  — moduly se v `lua.zig` concatenují do jednoho chunku. **Od M6** se shell čte
  z initfs (Limine initrd taru), viz `spec/roadmap.md` M6.
- M6 přidá initfs (Limine initrd), pak **perzistenci ve standardním formátu** — nikdy
  vlastní (ext2 dle ADR-023; FAT32 je příklad, ne cíl).
- Žádná perzistence před M6 (viz `spec/non-goals.md`).

## Související
- ADR-007, ADR-014
- `spec/roadmap.md` (M6)
