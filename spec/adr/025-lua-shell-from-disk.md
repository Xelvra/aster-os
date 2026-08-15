# ADR-025 — Lua shell z disku do `/wm/` s initrd fallbackem (Úroveň 2)

**Status:** Accepted (rozhodnutí o budoucí fázi)
**Datum:** 2026-08-15

## Rozhodnutí
Celý Lua shell (WM moduly `wm.lua`, `repl.lua`, `editor.lua`, `files.lua`,
`launcher.lua`, `input.lua`, `main.lua`, `theme.lua`) se v další fázi přesune
z **initrd taru na disk do adresáře `/wm/`**. Kernel jej načítá za běhu z disku;
**rozbitý nebo chybějící uživatelský soubor se nikdy nepoužije — místo něj se
aplikuje vestavěný fallback z initrd.**

Tím se uzavírá cíl dokumentovaný v `spec/lua-wm.md` §3.1 (Úroveň 2): uživatel
může editovat a přidávat **libovolné** WM moduly jako soubory `.lua` s
automatickým hot reloadem — ne jen `theme.lua` jako dnes (Úroveň 1).

## Odůvodnění
- **Konzistence s „kód je systém a systém je kód"** (`spec/runtime.md` §5a.1):
  `/wm/theme.lua` je už dnes plný Lua kód, ne datový formát. Úroveň 2 je jen
  rozšíření téhož principu na celý shell — není to cizorodý model.
- **Uživatelská přestavitelnost bez omezení** (viz `spec/lua-wm.md` §1): cíl
  projektu je okenní WM plně přestavitelný v Luay. Úroveň 1 (config na disku,
  moduly v initrd) přestavitelnost omezuje na theme; Úroveň 2 ji dokončuje.
- **Fallback chrání determinismus a bootovatelnost.** Rozhodnutí záměrně řeší
  riziko, které by přesun na disk sám přinesl (ADR-014 deterministický build,
  ADR-016 bootovatelný commit): chování systému nesmí záviset na obsahu disku,
  který může být rozbitý. Vestavěný initrd shell je proto **autoritativní
  základ**: disk ho jen přepisuje per-modul a každý rozbitý/chybějící modul se
  vrací na initrd default (stejný vzor jako `/wm/.theme.bak` dnes).

## Důsledky

### Načítání (bootstrap)
- `lua.zig` (`runMain`/`loadShellSource`) dostane **dvoufázový start**:
  1. Základní WM se vždy zavede z initrd (deterministický, zaručeně platný).
  2. Po spuštění shellu se z `/wm/` načtou **uživatelské přepisy** jednotlivých
     modulů; `load` + `pcall` na klonu (jako `apply_theme_content` dnes).
- Žádný uživatelský modul se nekombinuje s initrd modulem: **buď platný
  uživatelský soubor, nebo initrd default** — nikdy hybrid.

### Fallback (konkrétní pravidlo)
- Každý soubor z `/wm/` se validuje přes `load` + `pcall` v izolovaném klonu
  stavu. Při syntax/runtime chybě, chybějícím souboru nebo čtení mimo obraz se
  použije **vestavěný modul z initrd** a chyba se nahlásí do REPL přes
  `wm_error` (stejný kanál jako config chyby dnes).
- `wm_error("wm", ...)` a `on_shell_error` (z Bloku A) se stanou součástí
  základního initrd shellu, takže chyba uživatelského modulu je vždy viditelná
  i po hot reloadu (podobně jako `.theme.bak` fallback u theme).
- Fallback **nevypíná** uživatelskou úpravu: rozbitý soubor se na disku
  ponechá editovatelný (jako rozbitý `/wm/theme.lua` dnes), systém běží na
  initrd verzi, dokud uživatel neuloží platnou.

### Hot reload
- Uložení jakéhokoli `/wm/*.lua` spustí automatický hot reload dotčeného
  modulu (dnes to jde jen pro `/wm/theme.lua`). Mechanismus se rozšíří z
  `apply_theme_content` na obecný `apply_wm_module`.
- F5 a reload po chybě zůstávají celo-shelové (jako dnes); per-modul reload je
  přídavek, ne náhrada.

### Verifikace
- Uživatelské moduly z disku se testují runtime testem v QEMU s diskem
  (jako dnes `theme.lua` testy): rozbitý modul → initrd fallback, platný modul →
  přepis, chybějící modul → initrd default.
- Boot log zůstává deterministický (fallback zaručuje, že zobrazený WM je vždy
  platný); `capture-boot.sh --check` zůstává v platnosti.

### Rozsah
- Úroveň 2 je **zásadní změna bootstrapu** (`lua.zig` načítání + hot reload
  cesta + runtime testy) — dělá se jako **samostatný milník** s vlastní
  verifikací (`spec/roadmap.md` M8), ne jako tichý přidavek k jiné práci.
- Kroky: (1) obecný `apply_wm_module` fallback mechanismus, (2) per-modul
  načítání z `/wm/`, (3) hot reload na uložení, (4) runtime testy + dokumentace.

## Související
- ADR-014 (deterministický build), ADR-016 (bootovatelný commit)
- `spec/lua-wm.md` §3.1 (Úroveň 1 → 2), §5.1
- `spec/runtime.md` §5a (config jako plný Lua kód, fallback)
- `spec/roadmap.md` M8 (samostatný milník Úroveň 2)
- Změna tohoto návrhu = nový ADR odkazující na tento.
