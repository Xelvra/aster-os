# ADR-004 — Kernel Interface (KI), ne ABI

**Status:** Accepted
**Datum:** 2026-08-06

## Rozhodnutí
Termín "ABI" se nepoužívá. Existuje **Kernel Interface (KI)** — interní rozhraní mezi
jádrem a zbytkem systému. ABI z něj vznikne až s Ring 3 a instrukcí `syscall`, téměř beze změn.

## Odůvodnění
Dokud neběží Ring 3, nejsou oddělené adresní prostory a nepoužívá se instrukce `syscall`,
je tvrzení "stabilní ABI" nepravdivé a zavádějící. KI je přesné označení a později se může
stát základem ABI.

## Důsledky
- Dokument se jmenuje `spec/kernel-interface.md`, nikoli `abi.md`.
- Čísla operací v KI se přesto zmrazují už teď (přidávají se jen na konec).

## Související
- ADR-003
- `spec/kernel-interface.md` §6 (migrační cesta KI → ABI)
