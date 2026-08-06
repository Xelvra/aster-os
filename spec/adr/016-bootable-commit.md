# ADR-016 — Bootovatelný commit

**Status:** Accepted
**Datum:** 2026-08-06

## Rozhodnutí
Každý commit musí zanechat systém spustitelný v QEMU.

## Odůvodnění
U OS projektů se snadno "rozbije" boot a po týdnu začíná archeologický výzkum vlastního
repozitáře. Pravidlo brání akumulaci rozbitého stavu.

## Důsledky
- Před každým commitem se spustí `tools/qemu-smoke.sh`.
- Rozbitý boot se opravuje okamžitě, nikdy "za pár commitů".
- Výjimky (dokumentace, čistě host kód mimo boot cestu) se označí explicitně.

## Související
- ADR-015
- `spec/verification.md` §4
