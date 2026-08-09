# Runtime — Spouštění programů

**Status:** V1 (draft). **Rozhodnutí:** ADR-006, ADR-011, ADR-017.

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
    Lua = 0,     // jediný reálný kind v M0–M6
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

> **M0–M6: `Program` je logický placeholder, ne nezávislý lifecycle model.** V M6
> existuje **jeden globální `lua_State`** (shell) a `spawn(.Lua, ...)` nevytváří nový
> program — jen spustí `main.lua` na sdíleném státu a vrátí identifikátor provedení.
> `kill`/`status` jsou `NotSupported`. **M7:** `Program` se stává schedulable execution
> context — per-program `lua_State`/Wasm modul, preemptivní scheduler (ADR-017). Do M7
> se `Program.handle` nesmí interpretovat jako handle na izolovaný program.

Sub-op čísla pro `Runtime` v KI: `0=spawn`, `1=kill`, `2=status` (rozšiřitelné).

---

## 3. Životní cyklus (M0–M6 zjednodušený)

Pro jediný Lua runtime platí:

```
boot → runtime.init()          // vytvoří globální lua_State
     → runtime.spawn(.Lua, "main") → Program
     → event loop běží uvnitř shellu
```

- Zjednodušení: v M6 je Lua **vestavěný a jediný** program (shell). `spawn` je připravené,
  ale reálně běží jen "main" a nevytváří nezávislý program (§2).
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
| `power` | `power.reboot()` (i8042 reset, M5) |
| `sysmon` | `sysmon.ram_total_mb()`, `sysmon.ram_free_mb()` |
| `debug` | `debug.write(str)` (výpis na serial, přidává `\n`) |

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
  nebo `runtime.reload()` z Lua (session menu „Logout") — jen **nastaví flag**;
  samotné `lua_close`+`createState` provádí **event loop mimo jakýkoliv Lua call
  frame** (`api/runtime.zig` `requestReload`/`performReload`). Nikdy se nezavírá
  `lua_State`, na kterém právě stojí C funkce (use-after-free). Ověřeno runtime
  testem „reload from Lua is deferred, state survives".
- **Model restartů (session):** `F5`/`Logout` = restart **UI vrstvy** (shell) — kernel,
  paměť, drivery a ticky běží dál. `Reboot` = restart **celého stroje** (i8042 reset →
  BIOS → Limine → kernel → shell, `api/power.zig`). Restart **jen kernelu bez resetu
  stroje** neexistuje (single address space; re-init kernelu = reboot) — to je smysl
  F5/Logout: levnější než reboot. F5 a Logout jsou dnes identické; rozdělí se s M7
  (programy — logout je ukončí, F5 jen přenačte shell).
- **Marshalling je bezpečnostní hranice:** bindingy striktně validují typ a rozsah
  hodnot z Lua stacku (viz §4 + fuzz testy v `spec/verification.md` §3).
- **Chyba v `update()`/`render()` spouští hot reload (M5):** `callUpdate`/`callRender`
  vrací `CallResult` (`ok`/`no_function`/`err`); při `err` event loop automaticky
  znovu načte shell (`runtime.reload()`), aby se desktop zotavil z polorozkresleného
  stavu. Chybová zpráva Lua se loguje na serial. Ověřeno runtime testem „error
  containment".

**Známé omezení (M0–M6):** v M0–M6 běží **jediný `lua_State`** (shell). `lua_pcall`
chytí chyby, ale **ne nekonečné smyčky ani memory leak** — `while true do end` v
uživatelském skriptu zamrazí UI (kernel i IRQ běží dál). Zmírnění: preemptivní
scheduler od M7 (ADR-017) + per-program státy po `spawn`; do té doby je to vědomé
riziko jednojadrové kooperativní smyčky (`spec/invariants.md`).

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

## 7. Wasm (M7) — pravidla předem

- Runtime = wasm3 (vendored, C, MIT).
- Program v Wasm má vlastní lineární paměť (izolace přirozená pro Wasm).
- Komunikace s UI přes bindings + sdílené buffery (viz `spec/graphics.md` budoucí cesta).
- **Kernel nepřijme žádný Wasm-specifický kód.** Vše je za `Runtime.spawn`.
- Před nasazením: benchmark vs. Lua (kvalitní metriky v `roadmap.md`).

### 7.1 Dvě úrovně Wasm

Wasm má v Asteru **dvě odlišné role**, které se nesmí zaměňovat:

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
aplikace — stejně jako hostuje prohlížeč v Luay (ADR-020).

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
