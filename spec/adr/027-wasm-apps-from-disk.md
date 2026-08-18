# ADR-027 — Wasm aplikace z disku, WM/aplikace decoupling, klávesnice

**Status:** Accepted
**Datum:** 2026-08-18
**Navazuje na:** ADR-026 (import surface a surface model, Fáze B)

## Rozhodnutí

Tři rozšíření kalkulačky/Fáze B, dohromady jeden rozhodovací celek:

1. **Wasm aplikace se spouští z disku `/apps/*.wasm`, ne z initrd.** Launcher
   je **skenuje dynamicky** při každém otevření (`file.dir("/apps")`) — žádná
   hardcoded jména. `api/runtime.spawn` čte bajty programu přednostně z disku
   (`/apps/<jméno>`), initrd zůstává **jen** fallback pro `hello.wasm`/
   `fault.wasm` (wasm3 smoke testy Fáze A, nikdy launcher entries). Toto je
   M8/ADR-025 plán (dynamický scan + spouštění z disku) **pulled forward** do
   M7 Fáze B — ne nová dohoda, jen dřívější provedení již zapsaného záměru.
2. **WM nezná žádnou konkrétní aplikaci jménem.** `wm.lua`/`main.lua`/
   `launcher.lua` neobsahují `if title == "calculator"` nikde — okno wasm
   aplikace je generický typ (`wasm_handles[title]`), floating, fixní
   velikost podle fixní surface (ADR-026), centrované. Libovolná
   `/apps/*.wasm` aplikace dostane identické zacházení bez zásahu do WM kódu.
3. **Klávesnice pro wasm programy** (ADR-026 ji explicitně nechávala jako
   „výhled"): nový import `input_key()` — jednoslotová read-and-clear
   klapka (`Program.pending_key`), naplňovaná generickým WM přeposláním
   (`wasm_handles[focused]` → `runtime.key_input`), ne aplikačně specifickým
   kódem.

## Odůvodnění

- **Filosofie sandboxu vyžaduje symetrii mezi WM a aplikací** (`spec/manifest.md`
  „jednoduchost před izolací"): pokud WM zná konkrétní aplikaci jménem, sandbox
  je jen formální — kód pro *jednu* aplikaci žije v desktop chrome, ne v
  aplikaci samotné. Kalkulačka napsaná v Lua by při hardcoded launcher entry dopadla
  identicky; decoupling proto musí být na úrovni WM ↔ program, ne na úrovni
  jazyka/runtime.
- **Roadmap už toto rozhodnutí obsahoval** (`spec/roadmap.md` M7 poznámka
  2026-08-16: „Launcher `/apps/` dynamicky neskenuje... dynamický scan a
  spouštění z disku je samostatný úkol (M8), pro první programy stačí
  hardcoded entry"). Živé testování kalkulačky (2026-08-18) ukázalo, že
  hardcoded entry je viditelně v rozporu s vlastní filosofií projektu dřív,
  než M8 vůbec začne — pull-forward místo čekání na milník.
- **Disk jako zdroj pravdy pro `/apps/`, initrd jen pro infrastrukturní
  testy.** `hello.wasm`/`fault.wasm` ověřují wasm3 řetězec (link/load/trap
  containment) nezávisle na disku (Fáze A test bez disku musí projít) —
  zůstávají initrd-only a nikdy se neobjeví v launcheru.
- **Binárka aplikace se necommituje do `tools/test-disk-root/`** (source-tracked
  fixture, ADR-023): `calculator.wasm` je build artefakt
  (`zig-out/apps/calculator.wasm`, nový `addInstallFile` krok v `build.zig`),
  `tools/make-test-disk.sh` ho stage-uje do dočasné kopie stromu před
  `mke2fs`. Fixture strom zůstává čistě zdrojový.
- **Klávesnice jako generický kanál, ne calculator-specific.** Aplikace
  dostává znak, který WM už vyřešil (layout/shift) — stejná úroveň abstrakce
  jako `ev.char` pro Lua aplikace (editor/repl/files). Enter na hlavní
  klávesnici (`ev.code == "enter"`) a numpad Enter (`layout.zig`
  `numpad_enter` mapuje na `'\n'` přes `ev.char`, ne `ev.code`) jsou dva různé
  cesty ve WM vrstvě už predtím — kalkulačka musí rozumět oběma výsledným
  znakům (CR **i** LF), jinak numpad reaguje jinak než hlavní klávesnice, což
  žádná dokumentace nikdy nezamýšlela jako rozdíl.

## Důsledky

### `api/runtime.zig` — druhá api→api výjimka

`api/runtime` nyní importuje **dva** další api moduly: `api/graphics` (blit
surface, ADR-026) a `api/storage` (čtení `/apps/<jméno>` z připojeného disku).
Obě výjimky jsou zdokumentované na stejném místě (import komentář) jako jeden
koherentní důvod — `api/runtime` je composition root pro spawn+render wasm
programu, potřebuje sáhnout do obou sousedních modulů. Žádný jiný modul smí
tento vzor kopírovat bez nového ADR.

### Vlastnictví bajtů programu

`wasm.Program` má nové pole `owned_source: []u8` (prázdné pro initrd-backed
programy, které ukazují do tar archivu žijícího po celou dobu běhu kernelu).
`wasm.spawnOwned(source, name)` přebírá vlastnictví heap-alokovaného bufferu
(disk read) a uvolní ho v `free()` na **každé** chybové cestě i při běžném
zániku programu — `wasm.spawn` (initrd) zůstává beze změny.

### Import surface — nový řádek (append, ADR-026 kontrakt)

| funkce | wasm3 signature | popis |
|---|---|---|
| `input_key` | `i()` | další přeposlaný znak (0 = žádný od posledního volání), read-and-clear |

`RuntimeOp.key_input = 5` (append, `KeyInputArgs { handle: u64, char: u8 }`).

### Launcher

`apps` tabulka (`launcher.lua`) obsahuje už jen WM-intrinsic okna (repl,
sysmon, files, editor) — desktop chrome, ne aplikace v `/apps/`. Wasm aplikace
přidává `scan_disk_apps()`, volaná znovu při **každém** otevření launcheru
(žádný cache): smazání `/apps/calculator.wasm` se projeví hned při dalším
Super+Space. Ověřeno živě (QMP): smazání → aplikace zmizí z `run:` seznamu.

### Kalkulačka — rozšíření nad ADR-026

- **Desetinná čísla**: `entry`/`acc` jsou `f64` (ne `i64`); nové tlačítko `.`
  (grid rozšířen na 5 sloupců × 4 řádky, užší tlačítka aby se vlezly do
  fixní 224×160 surface). `formatFloat` ořezává (netransformuje) na max 6
  desetinných míst, celočíselný výsledek se zobrazí bez tečky.
- **Pending operátor vlevo v displeji** (`+`/`-`/`*`/`/` mezi stiskem
  operátoru a `=`), aktuální operand vpravo — vizuální kontext „co právě
  počítám", běžná konvence kalkulaček.
- Klávesnice: číslice, operátory, `.`, `=` (Enter i numpad Enter), `C`
  (Backspace/Escape/c/C) — `keyToLabel` v `calculator.zig`.

### Non-goals (zůstává z ADR-026, upřesněno)

- Bez alpha kanálu, bez resize, bez per-program velikosti, bez theme/barvy
  z WM, bez WASI — beze změny.
- ~~Bez keyboard eventů pro programy~~ — **zrušeno tímto ADR**, viz výše.
- Instalace/aktualizace aplikací na disk (jak se `.wasm` binárka vůbec
  dostane do uživatelova `/apps/` na produkčním disku, ne jen na test-disk
  fixture) zůstává **mimo rozsah** — řeší se, až bude potřeba (M8 v plném
  rozsahu, nebo dřív na explicitní požádání).

## Související

- ADR-026 (import surface, surface model — tento ADR ho rozšiřuje)
- ADR-025 (Lua shell z disku — stejný „disk je zdroj pravdy" precedent)
- ADR-023 (ext2, `tools/test-disk-root/` jako zdrojová fixture)
- `spec/roadmap.md` M7 Fáze B (poznámka 2026-08-16 o M8 pull-forward)
- `spec/manifest.md` (sandbox filosofie)
- Změna tohoto návrhu = nový ADR odkazující na tento.
