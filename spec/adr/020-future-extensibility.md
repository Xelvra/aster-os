# ADR-020 — Rozšiřitelnost na budoucí features (zvuk, síť, prohlížeč)

**Status:** Accepted
**Datum:** 2026-08-06

## Rozhodnutí
Budoucí features — zvuk, Bluetooth, síť, prohlížeč v Luay apod. — se přidávají **jako
nové KI moduly přidané na konec enumu**, nikdy úpravou existujících. Kernel nepředpokládá
žádnou z nich dopředu; vše, co dnes navrhujeme, musí zůstat rozšiřitelné bez bourání.

## Odůvodnění
Aster má být dlouhodobě živý systém: dnes UI v Luay, zítra i prohlížeč, hudba, připojení
k internetu. KI je stabilní šev (ADR-003, ADR-004) a čísla operací jsou zmrazená
(`kernel-interface.md` §4 pravidlo 2) — jediný udržitelný způsob přidávání je **nový modul
na konec**. Žádná dnešní struktura se nesmí navrhovat tak, aby budoucí feature vyžadovala
její přepis („lepení nebo bourání").

## Důsledky
- **Nová feature = nový KI modul** (`sound.zig`, `net.zig`, `bt.zig`, ...) s vlastními
  sub-op čísly od 0; `Syscall` enum dostane nové položky na konec. Existující moduly
  a čísla se nemění.
- **Prohlížeč v Luay** je jen další Lua klient Graphics/Input/Net API — nevyžaduje žádný
  kernel-specifický kód. Sdílí stejnou cestu jako shell/UI (spawn přes `Runtime.spawn`).
- **Síť (výhledově M9+)** má bezpečnostní brzdu: parsování cizího provozu v Ring 0 +
  fault policy = halt znamená **vzdálený DoS** (`non-goals.md`). Přidání sítě proto
  vyžaduje **vlastní ADR + plán** (fault containment, případně izolace), ne jen modul.
- **Ovladače** zůstávají v kernelu (Ring 0) do fáze oddělování; ADR-018 definuje cestu
  k jejich vytažení do služeb (IRQ routing) beze změny KI.
- Žádná budoucí feature nemění existující KI signatury; změna = nový ADR (pravidlo §5).

## Související
- ADR-003 (stabilní rozhraní), ADR-004 (KI), ADR-018 (transport Ring 3), ADR-019
  (bootloader gate)
- `spec/kernel-interface.md` (§3.1, §4), `spec/non-goals.md`, `spec/runtime.md` (§5a)
