# Aster OS

> **Aster je experimentální desktopový operační systém napsaný v Zigu.**
>
> První implementace záměrně upřednostňuje jednoduchost před izolací: desktop, skriptovací
> engine i runtime sdílejí jediný adresní prostor, aby se minimalizovala složitost a
> maximalizovala rychlost iterace. Veřejná rozhraní jsou navržena jako stabilní abstrakce,
> takže jednotlivé subsystémy lze později přestěhovat do izolovaných procesů **bez změny
> aplikačních API**.

> Plné znění manifestu (včetně toho, co Aster NENÍ a přijatých kompromisů):
> [`spec/manifest.md`](spec/manifest.md).

Tento projekt vyžaduje verzi Zigu uvedenou v [`.zig-version`](.zig-version).

## Prerekvizity

- **Zig** — exaktní verze v [`.zig-version`](.zig-version) (0.15.2), ne distro balíček
  (viz [`spec/verification.md`](spec/verification.md) §3).
- **QEMU** (`qemu-system-x86_64`) — emulace cíle.
- **Limine** — vendored v `libs/limine/` (ADR-012), žádné systémové balíčky.
- **xorriso / mtools** — tvorba bootovatelného ISO / disk image.
- **Lua 5.4.8** — vendored v `libs/lua-5.4/` (ADR-007).

Kompletní tabulka nástrojů a stav závislostí: [`spec/verification.md`](spec/verification.md) §6.

## Rychlý start

```bash
zig build run          # boot v QEMU
zig build test         # host unit testy
./tools/qemu-smoke.sh  # automatický boot test (serial marker + timeout)
```

## Architektura v kostce

```
Limine (bootloader) → Zig kernel (Ring 0) → KI (api/*) → Lua userland (shell/UI)
```

Detailní vrstvy, rozhraní a diagram: [`spec/architecture-overview.md`](spec/architecture-overview.md) §3.

## Dokumentace

Kompletní architektonická specifikace žije v [`spec/`](spec/README.md).
Začni u [architektonického přehledu](spec/architecture-overview.md).

Když systém spadne nebo se zasekne: [`spec/debugging.md`](spec/debugging.md) (Debugging Survival Guide).

## Stav

Pravidlo bootovatelného commitu: **každý commit musí zanechat systém spustitelný v QEMU.**
Viz [`spec/verification.md`](spec/verification.md).

Milníky M0–M4 jsou naplánované k implementaci. Viz [`spec/roadmap.md`](spec/roadmap.md).
