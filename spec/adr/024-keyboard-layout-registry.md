# ADR-024 — Multi-layout klávesnice: KL registry + přepínání za běhu

**Status:** Accepted
**Datum:** 2026-08-09

## Rozhodnutí

Vstupní subsystém přestává mít hardcoded US 105+ layout. Zavádějí se **KL registry**:
layout je **registrovaná mapovací tabulka** (`KeyCode` × modifikátory → `char`/akce),
ne jedna pevná switch funkce. Aktivní layout je přepínatelný **za běhu** přes nový
KI sub-op `input.set_layout` (rozšíření KI, viz `spec/kernel-interface.md`).

## Odůvodnění

- `input/layout.zig` je jediné místo, které zná rozložení kláves; přidání národního
  layoutu nemá být editace obří switch funkce, ale **registrace tabulky**.
- Multi-layout se řeší **teď** (Fáze 2, spec/roadmap.md), než přibude cokoliv dalšího
  (Wasm aplikace, další runtimes) — později by se to rearchitekturovalo.
- Aktivní layout je **konfigurační stav subsystému vstupu** (jeden aktuální jazyk),
  měněný výhradně přes KI — ne skrytý globální stav.

## Rozsah

- **Registry:** statické (comptime) tabulky layoutů, každá `[key_count]KeyMapping`,
  kde `KeyMapping = { plain, shift, altgr }` (0 = žádný znak). Numpad a control klávesy
  vracejí stejné znaky jako dosud.
- **Layouty v M7:** **US** (default, beze změny chování) a **CZ QWERTZ** — písmena podle
  českého rozložení (prohozené `y`/`z`), číslice a symboly **ASCII fallback** (diakritika
  `ě š č ř ž ý á í é` se v M7 nevykreslí — bitmap font je 8×16 ASCII; širší font je
  budoucí práce, ne podmínka zde).
- **KI:** `InputOp.set_layout(name) → KiStatus`; `input.layout_name()` pro dotaz.
- **Exit (Fáze 2):** přepnutí US ↔ CZ za běhu na stejném řetězci scancodes, bez restartu
  (runtime test).

## Důsledky

- `api/input.zig` dostane nový sub-op; čísla starých sub-opů se nemění (ADR-020).
- Lua shell může přepínat layout přes KI binding (`input.set_layout("cz")`).
- Diakritika zůstává budoucí (font), CZ layout je ASCII-subset — to je vědomé omezení,
  ne bug.

## Související

- ADR-020 (rozšiřitelnost — nové sub-opy na konec enumu)
- `spec/roadmap.md` Fáze 2 (multi-layout), `spec/input.md`
