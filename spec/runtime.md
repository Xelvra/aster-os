# Runtime — Spouštění programů

**Status:** V1 (draft). **Navazuje na ADR:** 006, 011, 017.

---

## 1. Princip

Runtime je vrstva odpovědná za spouštění a životní cyklus programů. Je **generická od
prvního dne**: neexistuje `spawn_wasm()`, existuje jen `spawn()`. Kernel ani desktop nikdy
nesmí vědět, co konkrétní runtime je.

```
Lua / Desktop
   ↓  Runtime.spawn(module)
Runtime (api/runtime.zig)
   ↓  dispatch do konkrétního kind
Program   (Lua / Wasm / Native)
```

**Vazba je vždy `Runtime → Program`, nikdy `Kernel → Wasm` nebo `Kernel → Lua`.**
Runtime se nesmí rozlézat po kernelu.

---

## 2. API

```zig
pub const RuntimeKind = enum(u8) {
    Lua = 0,     // jediný reálný kind v M0–M6 (Wasm přibyl v M7)
    Wasm = 1,    // M7, wasm3
    Native = 2,  // výhledově: nativní Zig modul
};

pub const SpawnOptions = struct {
    kind: RuntimeKind,
    entry: []const u8,   // např. "ui/main.lua" pro Lua, "app.wasm" pro Wasm
    args: []const u8 = &.{},
};

pub const Program = struct {
    kind: RuntimeKind,
    handle: u64,          // interní ID
    // state: running / stopped / exited (M7)
};
```

> **M0–M6: `Program` byl logický placeholder, ne nezávislý lifecycle model.** Existoval
> **jeden globální `lua_State`** (shell) a `spawn(.Lua, ...)` nevytvářel nový program —
> jen spustil `main.lua` na sdíleném státu a vrátil identifikátor provedení; `kill`/
> `status` byly `NotSupported`. **Od M7** je `Program` schedulable execution context:
> `lua.spawnProgram` vytváří **per-program `lua_State`** (program se tickuje přes
> `tickPrograms()`, chyba/nekonečná smyčka je izolovaná) a `Runtime.spawn(.Wasm)`
> spouští wasm programy; preemptivní scheduler (ADR-017). `kill`/`status` zůstávají
> `NotSupported`.

Sub-op čísla pro `Runtime` v KI: `0=spawn`, `1=kill`, `2=status` (rozšiřitelné).

---

## 3. Životní cyklus

Pro shell a spawnuté programy platí:

```
boot → runtime.init()          // vytvoří lua_State shellu
     → runtime.spawn(.Lua, "main") → Program (shell)
     → spawn dalších programů → per-program lua_State / Wasm instance (M7)
     → event loop běží uvnitř shellu; programy tickuje tickPrograms()
```

- Shell je vestavěný program; od M7 existují i spawnuté programy ve vlastních státech
  (`lua.spawnProgram` / `Runtime.spawn(.Wasm)`), izolované od shellu i navzájem.
- Kill/restart shellu (hot reload) = re-inicializace Lua státu bez restartu systému.

---

## 4. Lua bindings konvence

Veškerý přístup z Lua jde přes KI, nikdy přímo do kernel struktur.

| KI modul | Lua funkce |
|---|---|
| `graphics` | `gfx.draw_rect(x, y, w, h, color)`, `gfx.round_rect(x, y, w, h, radius, color)`, `gfx.rect_border(x, y, w, h, thickness, color)`, `gfx.gradient_border(x, y, w, h, thickness, color_a, color_b)`, `gfx.draw_text(str, x, y, color)`, `gfx.fill_screen(color)`, `gfx.invalidate()`, `gfx.present()`, `gfx.width()`, `gfx.height()` |
| `input` | `input.next_event()`, `input.mouse_x()`, `input.mouse_y()`, `input.mouse_left()`, `input.mouse_right()`, `input.mouse_middle()`, `input.set_layout(name)`, `input.layout_name()` |
| `timer` | `time.ticks()` |
| `runtime` | `runtime.reload()` (restart shellu, M5; `spawn` se neexponuje do M7) |
| `sysmon` | `sysmon.ram_total_mb()`, `sysmon.ram_free_mb()` |
| `debug` | `debug.write(str)` (výpis na serial, přidává `\n`) |
| `storage` | `file.open(path)`, `file.read(h, len)`, `file.write(h, data)`, `file.close(h)`, `file.truncate(h, size)`, `file.dir(path)`, `file.remove(path)`, `file.create(path)`, `file.rename(old, new)` |

**Neexponované KI operace:** `gfx.blit`, `gfx.draw_glyph` (KI ops, `graphics.md` §2) a `timer.sleep_ms`
(zmrazený sub-op, kooperativní sleep přijde s M7) jsou deklarované, ale **Lua binding zatím nemají** —
přidají se s reálným použitím. To, co Lua skutečně volá, je v tabulce výše a vše jde přes
`sys.dispatch` → `api/*` moduly.

**Konvence marshallingu:**
- Chybové stavy → Lua vrací `nil, err_string` (idiomatické pro Lua).
- Nestavové/statické funkce jsou čisté; žádné globální proměnné mezi voláními.
- **Barvy:** jediná reprezentace je **celé číslo `0xRRGGBB`** (u32) — takto i v KI
  wire formátu (`graphics` operace berou barvu jako u32). Žádné tabulky
  `{r,g,b}`, nejméně alokací. Definice v `spec/graphics.md` §2.

**Mapování typů Lua ↔ Zig (KI):**

| Lua | KI / Zig | Poznámka |
|---|---|---|
| `integer` | `u64`/`i64` | čísla operací, souřadnice, rozměry |
| `number` (float) | **nepodporováno** v jádře | žádné FP v kernelu; kreslení je celočíselné |
| `string` | `[]const u8` | přejde jako pointer + délka (bez kopie) |
| `boolean` | `bool` | |
| `table {r,g,b}` | — | **zakázáno** — barvy jen `0xRRGGBB` (viz výše) |
| `nil` / absent | optional | nepovinný argument = `null` |

**Chybová sémantika při špatném typu:** binding **nikdy nesmí shodit kernel**.
Špatný typ / rozsah z Lua → binding vrátí `nil, err_string` (např. `"expected
integer, got string"`), nikdy `panic`. Striktní validace je povinná — marshalling je
bezpečnostní hranice (spec `kernel-interface.md` §6, `verification.md` §3).

**Hello World (UI):**

```lua
-- minimální skript bez porušení pravidel o alokacích:
-- Graphics API volá přímo Renderer; render() nesmí alokovat.
local function render()
    gfx.fill_screen(0x000000)            -- černé pozadí
    gfx.draw_text("hello aster", 10, 10, 0xFFFFFF)
end
```

Event loop volá globální `render()` každý frame (M4/M5 model — žádná registrace; Lua
definuje konvenční funkci `update()`/`render()`, viz `spec/input.md` §4).

Pravidla, která skript splňuje: žádná alokace v `render()` (jen Graphics API →
Renderer, invariant Performance), žádný přímý přístup k framebufferu.

---

## 5. Error containment a hot reload

Lua běží vestavěně v jádře (Ring 0) — chyba skriptu **nesmí shodit kernel**. Pravidla:

- **Každý vstup z kernelu do Lua** (volání Lua funkce: `update()`, event handler,
  binding call) je obalen **`lua_pcall`**. Chyba se vrátí jako `nil, err` volajícímu
  a systém pokračuje. Žádný `lua_error` longjmp přes nechráněný Zig stack.
- **Hot reload (M4/M5):** restart shellu = znovuvytvoření `lua_State` bez restartu
  systému. Při `lua_close` starého státu se **uvolní i C-strana stavu**, kterou session
  registrovala (userdata/registry). Policy: **userdata a callbacky nikdy nepřežívají
  svůj `lua_State`** — všechna kernelová data, na která Lua ukazuje, jsou vlastněná
  daným státem a uvolní se s ním (žádné dangling pointery). Zbytečné držení
  externích struktur je porušení invariantu use-after-free (`spec/invariants.md`).
- **Reload je vždy odložený (M5 close):** trigger — F5, chyba `update()`/`render()`,
  nebo `runtime.reload()` z Lua — jen **nastaví flag**; samotné `lua_close`+`createState`
  provádí **event loop mimo jakýkoliv Lua call frame** (`api/runtime.zig`
  `requestReload`/`performReload`). Nikdy se nezavírá `lua_State`, na kterém právě stojí
  C funkce (use-after-free). Ověřeno runtime testem „reload from Lua is deferred, state
  survives".
- **Model restartů:** `F5` (nebo auto-reload po chybě) = restart **UI vrstvy** (shell) —
  kernel, paměť, drivery a ticky běží dál. `Reboot` = restart **celého stroje** (i8042
  reset → BIOS → Limine → kernel → shell, `api/power.zig`). Restart **jen kernelu bez
  resetu stroje** neexistuje (single address space; re-init kernelu = reboot) — to je
  smysl F5: levnější než reboot. `Reboot` je **čistě kernel-level** operace — UI je
  always-live (`spec/lua-wm.md` §1) a restart nikdy nevystavuje (`power` binding v Lua
  neexistuje). **Dvě úrovně reloadu (M7):** per-program `lua_State` existuje, ale F5
  reloaduje jen shell; teardown ostatních běžících programů při reloadu se řeší
  samostatně (programy se tickují nezávisle, nezávisí na shellu).
- **Marshalling je bezpečnostní hranice:** bindingy striktně validují typ a rozsah
  hodnot z Lua stacku (viz §4 + fuzz testy v `spec/verification.md` §3).
- **Chyba v `update()`/`render()` spouští hot reload (M5):** `callUpdate`/`callRender`
  vrací `CallResult` (`ok`/`no_function`/`err`); při `err` event loop automaticky
  znovu načte shell (`runtime.reload()`), aby se desktop zotavil z polorozkresleného
  stavu. Chybová zpráva Lua se loguje na serial a zároveň se před reloadem ukáže
  v REPL scrollbacku přes `on_shell_error` hook (`repl.lua`) — desktop nemá terminál,
  takže uživatel chybu vidí v grafickém shellu. Ověřeno runtime testem „error
  containment".

**Známé omezení (M0–M6, částečně vyřešeno M7):** v M0–M6 běží **jediný `lua_State`**
(shell). `lua_pcall` chytil chyby, ale **ne nekonečné smyčky ani memory leak** —
`while true do end` v uživatelském skriptu zamrazil UI (kernel i IRQ běží dál).

**Stav od M7 (2026-08-14, brief Task 7b):** kernel→Lua volání (`callUpdate`/
`callRender`) má **instrukční rozpočet** (`LUA_MASKCOUNT` count hook, konstanta
`instruction_budget` v `lua/lua.zig`): překročení vyvolá Lua chybu, kterou **stejný
`lua_pcall` mechanismus jako runtime chybu** zachytí → `CallResult.err` → event loop
spustí hot reload. Nekonečná smyčka tak **nezamrzí UI natrvalo** — vyvolá error
containment/reload jako každá jiná chyba skriptu (ověřeno runtime testem „infinite
loop containment"). **Per-program izolace (M7):** spawnuté programy běží ve vlastním
`lua_State` (`lua.spawnProgram`), takže nekonečná smyčka/chyba jednoho programu
neshodí shell ani ostatní programy (ověřeno runtime testem „per-program isolation").
**Reziduální omezení:** memory leak z nekonečné alokační smyčky rozpočet nezachytí
(chyba se jen opakuje po každém reloadu, dokud se skript neopraví); shell samotný
běží na hlavním kontextu.

---

## 5a. Živá transformace UI (wow efekt, finální cíl)

**Princip:** UI je Lua kód. „Změna designu" = změna Lua kódu/stavů — žádný separátní
config formát neexistuje. Kernel běží nonstop a nikdy se nepřestavuje; Lua se mění za
běhu a celé prostředí se okamžitě překreslí.

**Spouštěče transformace:**

1. **Příkaz v REPL / Lua** (primární, od M4): napsal jsi `barva = "cervena"` →
   změna se projeví **okamžitě, bez jakékoli klávesy**. Nic se nemačká.
2. **Uložení konfiguračního souboru** (od M6, initfs/perzistence): `save theme.lua` →
   shell soubor znovu načte a prostředí se **automaticky překreslí** (watch/detekce
   uložení). Kernel se nepřestavuje.
3. **F5** (od M4, volitelné): manuální „překresli vše" pro případ artefaktů od
   špatného vykreslení. Není nutné pro normální tok — jen pojistka.

**Sémantika (co se NEděje):**

- Okna se **nezavírají**, obsah terminalu **zůstává** — mění se jen vzhled (barvy,
  tvary, rozměry). Jde o reload **theme modulu + re-render oken**, ne o restart
  celého `lua_State` (k tomu slouží §5 hot reload).
- Kernel o transformaci neví — je to čistě Lua orchestrace (module reload +
  `redraw()` callback). Kernel zůstává stejná binárka, běží nonstop.

**Rozsah v milnících:**

- M4–M5: spouštěče 1 a 3 (embedded soubory; „save" není, jen REPL).
- M6+: spouštěč 2 (initfs / perzistence v souborech + auto-reload).

### 5a.1 Config je plný Lua kód (ne datový formát)

`/wm/theme.lua` (a obecně každý config soubor aplikovaný přes `apply_disk_theme`) **není
omezený datový formát — je to plnohodnotný Lua kód spuštěný na sdíleném `lua_State`
shellu** (`load` + `pcall`). To je záměr projektu „kód je systém a systém je kód"
(`spec/lua-wm.md` §1, D5): uživatel může přes config měnit nejen `theme` tabulku, ale
i funkce WM (`win_render`, `bar_render`, ...), přidávat vlastní okna/zkratky a volat
libovolné bindings. To není bezpečnostní díra, ale **vědomá vlastnost**: totéž už
umožňuje REPL (`repl.lua` `run()`); `/wm/theme.lua` je jen jeho perzistentní varianta.
Bezpečnostní model zůstává jednouživatelský SASOS bez izolace domén
(`spec/non-goals.md`, `SECURITY.md`) — plný kód v configu to nemění.

> **Úroveň 2 (ADR-025):** cíl je rozšířit „kód je systém" z configu na **celý WM
> shell** — moduly se načítají z `/wm/` (ne jen theme). **Fallback pravidlo:**
> rozbitý/chybějící uživatelský modul se nikdy nepoužije; aplikuje se vestavěný
> initrd default. `.bak` soubory (`.theme.bak` / `.api.bak`) jsou **jen ruční
> záloha posledního Ctrl+S** a nikdy se nenačítají jako konfigurace (ADR-025).
> Determinismus (ADR-014) a bootovatelnost (ADR-016) tak zůstávají v platnosti.

### 5a.2 Fallback a chybové hlášení configu

Chybný config **nesmí shodit shell ani nechat polorozkreslený vzhled**:

- `apply_theme_content(content)` aplikuje config **atomicky**: `load` chytí syntax
  chyby, `pcall` na **klonu** `theme` tabulky chytí runtime chyby; při jakékoli chybě
  se stará `theme` tabulka vrátí (rollback) a vrátí se chybová zpráva.
- `apply_disk_theme()` aplikuje `/wm/theme.lua`; když neprojde (rozbitý nebo chybí),
  **nepoužije se žádná záloha** — live `theme` zůstane na vestavěném initrd defaultu
  (rollback v `apply_theme_content`) a chyba se vrátí volajícímu. `/wm/.theme.bak`
  se **nikdy nenačítá jako config** — je to jen ruční záloha posledního Ctrl+S
  (ADR-025).
- Chyba se **vždy vypíše do REPL scrollbacku** (`main.lua` po bootu/F5, `editor_save`
  po Ctrl+S) — uživatel vidí, že config je rozbitý, i když soubor neotevře.
- Editor (`editor_save`) **validuje před zápisem**: rozbitý config se do `/wm/theme.lua`
  zapíše (working copy zůstává editovatelná), ale **`/wm/.theme.bak` se nemění** — drží
  zálohu posledního platného Ctrl+S. Platný config se zapíše do `/wm/theme.lua` a
  **předchozí working copy** se uloží do `/wm/.theme.bak` (záloha **nezrcadlí** nový
  obsah — vrací se k ní předchozí uložení). Validace jako `theme.lua` se týká **jen**
  souboru `/wm/theme.lua`; ostatní soubory se zapisují jako plain text. **Nový soubor**
  (save-as u prázdného bufferu) se vytvoří přes `file.create` (ext2 create, M7.1.11).
- **`/wm/.theme.bak` je read-only pro editor**: `editor_load` ho (i `.repl_history`)
  odmítne načíst — jdou jen prohlížet Spacem ve files browseru, editor je nikdy
  nepřepíše (žádný Ctrl+S guard není potřeba). Zálohu plní jen `editor_write`
  po validním save `/wm/theme.lua`. Skryté soubory (vedoucí
  tečka) a **vše uvnitř `/.trash`** se ve files browseru kreslí **dim šedomodře**
  (`theme.text_dim`, jeden sdílený „skryté/vedlejší" odstín — v koši dokonce i
  read-only položky, aby adresář četl jako „v koši"; červená se vrací po vyjmutí)
  — **read-only soubory** (`/wm/.theme.bak`,
  `.repl_history`) mimo koš červeně (`theme.red`, má přednost před dim). **Delete guard neexistuje** — smazání
  `/wm/theme.lua` i `/wm/.theme.bak` je bezpečné: `apply_disk_theme()` najde `nil` a použijí
   se vestavěné defaulty z initrd, takže prostředí se nikdy nerozbije.
- **Záloha každého `.lua` souboru (basename pravidlo, ADR-025):** `editor_write`
  uloží při Ctrl+S **každému** souboru s příponou `.lua` (kromě `/wm/theme.lua`,
  který má vlastní validační větev) skrytou zálohu **předchozí** verze vedle
  working copy: `theme.lua → .theme.bak`, `api.lua → .api.bak`,
  `test.lua → .test.bak` (záloha nikdy nezrcadlí právě uložený obsah). Lua soubory
  jsou nejcennější uživatelská práce (config, skripty), proto mají ochranu;
  ostatní typy souborů se zapisují jako plain rewrite. Čerstvě vytvořený soubor
  (save-as) nemá předchozí verzi → záloha nevzniká.
- **Proč je read-only hardcoded:** systém zatím nemá vlastnictví ani práva souborů —
  read-only je pravidlo v `files.lua`/`editor.lua` (shoda na `.bak` příponu resp.
  `/.repl_history`), ne atribut souboru. Důvod se liší per typ: `.bak` je **ruční
  záchrana** (obnovení = přejmenovat zpět na working copy; kdyby editor mohl zálohu
  Ctrl+S přepsat, přestala by být zálohou), `/.repl_history` je **runtime stav
  vlastněný shellem** (REPL ho po každém Enter přepíše z paměti — ruční editace by
  byla tiše ztracena a klamala uživatele).
- Diskový `/wm/.theme.bak` musí existovat v image; `make-test-disk.sh` ho vkládá
  z `tools/test-disk-root/wm/.theme.bak` (editor ho přepisuje jen předchozí working
  copy po validním save `/wm/theme.lua`).

---

## 6. GC tempo (frame latency p99)

Lua 5.4 běží inkrementální GC; práce GC probíhá nezávisle na framebufferu a může
způsobit pauzy mimo render — ohrožuje KPI `frame latency (p99) < 16 ms`
(`spec/roadmap.md`).

- **Rozpočet na frame:** v každém `update()` se volá `collectgarbage("step", N)`
  s **pevně stanoveným rozpočtem** (počet bajtů zpracovaných za frame), nastaveným
  z měření (ADR-015). GC nikdy neběží v `render()`.
- Od 5.4 existuje **generační režim** (`collectgarbage("generational")`) s obecně
  kratšími pauzami. Použije se, pokud měření v M4 ukáže, že inkrementální `step`
  nedrží p99.
- Cíl: žádný jednotlivý GC krok nezahltí frame nad rozpočet latency.

---

## 7. Wasm (M7) — stav a pravidla

- Runtime = wasm3 (vendored, C, MIT).
- Program v Wasm běží v **sandboxu** — vlastní lineární paměť (izolace je pro Wasm
  přirozená), pasti (OOB, dělení nulou) se zachytí bez shození hostitele; padlý program
  se zahodí, desktop běží dál. **Hotovo (Fáze A):** trap containment v `wasm.zig`,
  ověřeno `fault` programem.
- Komunikace s UI: domácí wasm programy volají Aster bindings přes wasm importy
  (marshalling přes lineární paměť). **Hotovo (Fáze B, ADR-026 + ADR-027):** stabilní
  import surface (`debug_write`, `draw_rect`, `draw_text`, `surface_width`/`height`,
  `input_mouse_x`/`y`/`left`, `input_key`) a persistentní program (`start`/`update`/
  `render`, fixní 224×160 surface kompozitovaná přes `api/runtime.surface_render`).
  Kalkulačka (`src/kernel/apps/calculator.zig`) je první GUI wasm aplikace, spouští se
  z disku `/apps/*.wasm`, launcher je skenuje dynamicky (WM nezná aplikaci jménem).
- **Kernel mimo `api/runtime` nepřijme žádný Wasm-specifický kód.** Vše je za
  `Runtime.spawn`; konkrétní runtime jméno zná jen `api/runtime` (composition-root
  výjimka, ADR-006).
- Benchmark wasm vs Lua je Fáze C (kvalitní metriky v `roadmap.md`); nasazení
  proběhlo v M7 bez benchmarku, benchmark zůstává dluh před uzavřením M7.

### 7.1 Dvě úrovně Wasm

Wasm má v Aster OS **dvě odlišné role**, které se nesmí zaměňovat:

1. **Domácí Wasm (M7):** aplikace **psané pro Aster** — volají KI přes Aster bindings
   (`gfx.*`, `input.*`, ...), jako Lua, ale s izolovanou lineární pamětí a bez sdíleného
   stavu jádra. To je jediná Wasm role v M7.
2. **WASI vrstva (výhledově, M9):** kompatibilita s **cizím** Wasm ekosystémem.
   Programy kompilované `wasm32-wasi` (CLI nástroje, text-UI hry, jednoduché aplikace)
   by mohly běžet, pokud Aster implementuje mapování WASI syscallů na KI.

**WASI není součást kernelu.** Je to čistá runtime vrstva nad wasm3, která překládá
WASI syscall čísla na KI volání (`debug.write`, `net.*`, `storage.*`, ...). Kernel
nikdy nevidí WASI — vidí jen svá vlastní KI volání. Tím zůstává `non-goals.md`
pravdivé: **kernel nemá žádná POSIX API**, ale *runtime* může hostit WASI pro cizí
aplikace — stejně jako hostuje prohlížeč v Lua (ADR-020).

**Nasazení a omezení:**
- Začíná se **podmnožinou WASI** (stdout, argv, filesystem) — ne plná WASI najednou.
- Síťová WASI volání jedou přes `net.*`, takže podléhají bezpečnostní brzdě sítě
  (ADR-020, `non-goals.md`).
- WASI ≠ GUI. Aplikace s okny potřebují Aster bindings; WASI pokrývá konzolové/
  výpočetní věci.
- Design domácích Wasm bindings v M7 se navrhuje tak, aby šlo WASI vrstvu přidat
  bez přepisu (Wasm importy oddělené od přímého volání KI).

---

## 8. Invarianty

- **Runtime nezávisí na kernel internals** (Architecture).
- **Lua nezapisuje do kernelových struktur** — jen přes KI (Architecture).
- **Program nemá přímý přístup k framebufferu** — jen přes Graphics API (Architecture).
- **Kernel nezná jméno žádného runtime** (Architecture).
