# Lua WM — Architecture Blueprint / Design Doc

**Status:** V1 (draft).
**Zdroj:** `src/kernel/lua/ui/` + `src/kernel/lua/*.zig` + KI grafika/vstup.
**Navazuje na:** `spec/architecture.md`, `spec/runtime.md`, `spec/graphics.md`,
`spec/input.md`, `spec/desktop-ui.md`, `spec/kernel-interface.md`, `spec/invariants.md`.

> Tento dokument je **jediný ucelený blueprint** okenního manažeru (WM) napsaného v Luay.
> Spojuje v jednom souboru vrstvy, které se jinde v `spec/` řeší odděleně:
>
> - **Architecture Blueprint** (§2–§5) — kde WM žije a jak je celý postaven;
> - **Component / Subsystem Blueprint** (§6–§8) — rozpad na moduly, stav, layout engine;
> - **Technical Architecture Document (TAD)** (§9–§13) — grafická pipeline, vstup,
>   binding vrstva, runtime integrace, event loop;
> - **RFC / Design rationale** (§14) — proč je to postavené tak, jak je (rozhodnutí
>   a odmítnuté alternativy).
>
> Citační konvence: `soubor:řádek` odkazuje na aktuální zdroj; kód je anglicky,
> tento dokument česky (pravidlo `spec/README.md`).

---

## 1. Shrnutí

**Lua WM je desktop shell napsaný v Luay 5.4, který běží vestavěně v kernelu (Ring 0,
jediný adresní prostor).** Není to samostatný proces ani daemon — je to sada šesti
Lua modulů, které kernel **zkonkatenuje do jednoho chunku**, nahraje do jediného
globálního `lua_State` a volá každý frame dvě konvenční funkce: `update()` a `render()`.

Veškeré kreslení jde přes **KI bindings** (`gfx.*`, `input.*`, ...) → `sys.dispatch` →
`api/*` moduly → interní subsystémy. Lua nikdy nepíše přímo do framebufferu.

WM implementuje: tiling layout (splith/splitv), workspaces 1–3, floating okna s
dragem, fullscreen, scratchpad, taskbar s hodinami a workspace kaplemi, aplikaci
launcher (Super+Space), REPL/terminál jako okno, systémový monitor a session menu
(Lock/Logout/Reboot). Vzhled je **data** v `theme.lua`, měnitelná za běhu (F5).

---

## 2. Kontext: kde WM žije

```
 ┌──────────────────────────────────────────────────────────────┐
 │                 QEMU q35 / x86_64 (limine.conf)              │
 │                                                              │
 │  ╔═══════════════════════ ZIG KERNEL (Ring 0) ══════════════╗ │
 │  ║  main.zig  — jediný event loop, composition root         ║ │
 │  ║     │  poll() → update() → render()  (main.zig:332)      ║ │
 │  ║     ▼                                                    ║ │
 │  ║  LUA RUNTIME: lua.zig + libc.zig + cimport.zig           ║ │
 │  ║     └── jeden globální lua_State (vendored Lua 5.4)      ║ │
 │  ║          │  bindings.zig (gfx/input/time/...)            ║ │
 │  ║          ▼                                               ║ │
 │  ║  LUA WM SHELL: ui/{theme,wm,repl,launcher,input,main}.lua║ │
 │  ║          │  update() / render()                          ║ │
 │  ║          ▼                                               ║ │
 │  ║  KI: sys.dispatch (api/sys.zig)                          ║ │
 │  ║    ├─ api/graphics ─→ render/renderer ─→ fb/framebuffer  ║ │
 │  ║    │                  render/mouse_cursor (overlay)      ║ │
 │  ║    ├─ api/input ─────→ input/service ─→ fronta ← IRQ     ║ │
 │  ║    ├─ api/timer ─────→ time.zig                          ║ │
 │  ║    ├─ api/runtime ───→ hot reload / spawn                ║ │
 │  ║    ├─ api/sysmon ────→ mem.Memory                        ║ │
 │  ║    ├─ api/debug ─────→ serial                            ║ │
 │  ║    └─ api/power ─────→ i8042 reset                       ║ │
 │  ╚══════════════════════════════════════════════════════════╝ │
 └──────────────────────────────────────────────────────────────┘
```

Klíčové vlastnosti vrstvy:

- **Shell = data + kód v jednom chunkok.** Žádný `require`, žádný souborový systém
  v závislostech, žádné jmenné prostory — `local` proměnné jednoho chunku sdílí
  celý shell (`lua.zig:111`).
- **Kernel nezná UI.** Volá jen `update()` a `render()`; obsah shellu je zcela
  libovolný. To je nezávislost „Render/Runtime" z `spec/architecture.md`.
- **Všechna interakce přes KI.** Lua vidí jen binding tabulky (`bindings.zig:522`);
  žádný přímý přístup k framebufferu, frontám ani paměti kernelu.

---

## 3. Jak se shell sestavuje a načítá (packaging)

### 3.1 Build (build.zig)

Shell moduly se **nekompilují do binárky** (`@embedFile`), ale balí do **tar archivu**
(`initfs.tar`), který Limine nahraje jako modul (initrd). Důvod: moduly lze měnit za
běhu a kernel se nepřestavuje (M6, `spec/roadmap.md`).

```zig
// build.zig:90  — pořadí je ZÁVAZNÉ a musí souhlasit s lua.zig:115
const shell_files = [_][]const u8{
    "theme.lua", "wm.lua", "repl.lua", "launcher.lua", "input.lua", "main.lua",
};

// build.zig:99  — tar z rovných jmen (stripuje absolutní cesty zdroje)
const tar_cmd = b.addSystemCommand(&.{ "tar", "-cf" });
...
tar_cmd.addArg("--transform");
tar_cmd.addArg("s|^.*/||");
for (shell_files) |f| tar_cmd.addFileArg(b.path("src/kernel/lua/ui/{s}", .{f}));
```

- `addFileArg` → Zig **sleduje obsah** `.lua` souborů: editace libovolného modulu
  invaliduje archiv a ISO se přestaví se změněným shellem (`build.zig:96`).
- Pořadí souborů v archivu je **dependency order** (viz §3.3).

### 3.2 Načtení za běhu (lua.zig)

```zig
// lua.zig:119 — načte soubory z initrd do jednoho heap bufferu
fn loadShellSource() ![]const u8 {
    const tar = initrd orelse return error.NoInitrd;
    // součet délek všech 6 souborů → alloc → @memcpy za sebe
}

// lua.zig:136 — nahraje buffer jako JEDEN Lua chunk a spustí ho
pub fn runMain(entry: []const u8) !void {
    const src = try loadShellSource();
    defer heap_allocator.free(src);
    ...
    luaL_loadbufferx(L, src.ptr, src.len, "main.lua", null); // load
    lua_pcallk(L, 0, 0, 0, 0, null);                          // run
}
```

Sekvence startu (`main.zig:166`):

```
runtime.init(alloc, info.initrd)          // lua.init → createState → bindings.register
runtime.spawn(.{ .kind = .Lua, .entry = "main.lua" })  // lua.runMain
   → načte 6 souborů z initrd, zkonkatenuje, spustí jako jeden chunk
   → v globálu zůstanou update() a render()
```

### 3.3 Dependency order (proč právě toto pořadí)

| Pořadí | Modul | Definuje pro pozdější moduly |
|---|---|---|
| 1 | `theme.lua` | globální `theme` tabulku |
| 2 | `wm.lua` | `windows`, `focused`, `layout_pass`, `bar_render`, `win_render`, `find_win`, `set_focus`, `ws_capsules`, `window()`, session stav |
| 3 | `repl.lua` | `print`, `repl_render`, `sysmon_render`, REPL editovací stav |
| 4 | `launcher.lua` | `launcher_*` stav a funkce |
| 5 | `input.lua` | `handle_mouse`, `handle_key` |
| 6 | `main.lua` | globální `update()` / `render()` (entry) |

Protože jde o **jeden chunk**, pozdější modul vidí `local` stav modulů předchozích
— na tom stojí celý shell. Změna pořadí (např. `input.lua` před `wm.lua`) by shell
rozbila, proto je seznam duplikován na dvou místech se vzájemným odkazem
(`build.zig:90` ↔ `lua.zig:115`).

---

## 4. Architektura: moduly a soubory (mapa)

```
src/kernel/lua/
├── cimport.zig       # @cImport Lua C API (lua.h, lauxlib.h, lualib.h)
├── libc.zig          # freestanding libc shim pro Lua (malloc, vsnprintf, fabs, ...)
├── lua.zig           # runtime: state, init/reload, chunk load, callUpdate/callRender, gcStep
├── bindings.zig      # KI bindingy: gfx, input, time, debug, sysmon, runtime, power
└── ui/               # ─── LUA WM ───
    ├── theme.lua     # barvy + geometrie (data, hot-reloadovatelné)
    ├── wm.lua        # WM stav, tiling layout, bar, dekorace oken
    ├── repl.lua      # REPL/terminál okno + sysmon okno
    ├── launcher.lua  # aplikace launcher (Super+Space)
    ├── input.lua     # myš + klávesnice (Hyprland zkratky, hit-testing)
    └── main.lua      # update()/render() entry — orchestrace
```

Role jednotlivých souborů:

| Soubor | Odpovědnost | Veřejný povrch pro shell |
|---|---|---|
| `theme.lua` | deklarativní vzhled | globální `theme` |
| `wm.lua` | stav WM + tiling + bar + dekorace | `layout_pass`, `bar_render`, `win_render`, `set_focus`, `find_win`, `focus_topmost`, `ws_capsules`, `window`, session funkce |
| `repl.lua` | REPL stav/editing/eval + render | `repl_render`, `sysmon_render`, `print`, REPL stav |
| `launcher.lua` | launcher popup + akce | `launcher_open`, `launcher_render`, `launcher_run`, `launcher_filtered` |
| `input.lua` | vstupní obsluha | `handle_mouse`, `handle_key` |
| `main.lua` | frame orchestrace | globální `update`, globální `render` |

---

## 5. Komponentní rozpad (Component Blueprint)

### 5.1 `theme.lua` — vzhled jako data

Jediný modul bez závislostí. Definuje globální tabulku `theme` (viz `theme.lua:4`):

```lua
theme = {
    background, surface, surface_alt,          -- pozadí plochy / okna / titulku
    text, text_dim,                            -- texty
    accent, accent_b, accent_dark,             -- tyrkysová řada (aktivní dekorace)
    inactive, launcher,                        -- neaktivní border / tlačítko
    wm   = { gap_out, gap_in, border, radius, title_h,
             opacity_active, opacity_inactive },
    bar  = { height, radius },
    ws   = { "1", "2", "3" },                  -- jména workspace
}
```

Změna libovolné hodnoty + F5 (hot reload) = okamžité překreslení bez rebuildu kernelu
— „živá transformace UI" (`spec/runtime.md` §5a). Žádná hodnota se nesmí hardcodovat
v jiném modulu (bar je výjimka pro hodinové/rozložení konstanty viz §5.2).

#### Historie palety (zapsáno 2026-08-10)

Paleta je **Cachy paleta** (port z `cachyos-hypr-noctalia`, viz `spec/desktop-ui.md` §2).
Barevné hodnoty se od svého zavedení **nezměnily**; tato poznámka existuje proto, aby se
případná budoucí změna dala vysledovat vůči originálu:

| Období | Commit | Barvy |
|---|---|---|
| **M4** (REPL screen) | `e7d7623` → `ecf60d8^` | jen `background = 0x000000`, `text = 0xFFFFFF`, `accent = 0x82DCCC` |
| **M5** (první desktop) | `ecf60d8` (2026-08-08) | kompletní paleta níže, v `main.lua` |
| **M5** (split do `theme.lua`) | `d5fdba9` | identické hodnoty |
| **dnešek** | `HEAD` | identické hodnoty |

Jediná barva starší než M5 je **akcent `0x82DCCC`** (tyrkys) — existuje už od M4.
Kompletní paleta (zavedená v `ecf60d8`, beze změny dodnes): `background 0x111826`,
`surface 0x182545`, `surface_alt 0x223454`, `text 0xDDDDDD`, `text_dim 0x798BB2`,
`inactive 0x798BB2`, `accent 0x82DCCC`, `accent_b 0x00AA84`, `accent_dark 0x007D6F`,
`launcher 0x01CCFF`. Geometrie (`wm`/`bar`/`ws`) se rovněž od M5 nezměnila.

### 5.2 `wm.lua` — jádro okenního manažeru

**Stav WM** (vše `local`, sdílené celým chunkem):

| Proměnná | Typ | Význam |
|---|---|---|
| `windows` | `{Window}` | seznam oken; **pořadí = tiling pořadí** |
| `focused` | `string?` | title fokusovaného okna |
| `current_ws` | `u64` | aktivní workspace |
| `drag` | `{title,dx,dy}?` | probíhající drag hlavičky floating okna |
| `layout_mode` | `"splih"`/`"splitv"` | mód tiling layoutu |
| `fullscreen_win` | `string?` | title fullscreen okna |
| `z_counter` | `u64` | monotónní zdroj z-řazení |
| `session_*`, `locked` | — | session menu stav + zámek |

**Struktura okna** (`window()`, `wm.lua:20`):

```lua
{ title, ws, x, y, w, h, floating:bool, z }
```

**Klíčové funkce:**

- `window(title, ws)` — továrna; inkrementuje `z_counter`.
- `find_win(title)` / `ws_windows(ws)` / `topmost_of(ws)` — dotazy nad `windows`.
- `set_focus(title)` (`wm.lua:62`) — **zásadní invariant**: nastaví `focused` a zvětší
  `z`, ale **nepřehazuje `windows`** — list order je tiling order, fokus ho nesmí
  zamíchat. Focus proto nikdy nemůže změnit tiled layout.
- `focus_topmost(ws)` — zaostří topmost okno na workspace (typování hned funguje).
- `layout_pass()` (`wm.lua:105`) — přepočítá geometrii oken (detail §6).
- `ws_capsules()` (`wm.lua:173`) — **jediný zdroj pravdy** pro geometrii workspace
  kapslí; render (bar_render) i hit-testing (input.lua) ji sdílí, takže se nemohou
  rozejít.
- `bar_render()` (`wm.lua:184`) — taskbar; `session_menu_render()` — session popup.
- `win_render(w)` (`wm.lua:259`) — dekorace okna; `blend()` (`wm.lua:245`) — opacity
  směrem k barvě pozadí.

**Session menu** (Lock/Logout/Reboot): `session_run(id)` (`wm.lua:44`) —
Lock = overlay (zatím bez auth, libovolná klávesa odemkne), Logout = `runtime.reload()`
(restart UI vrstvy), Reboot = `power.reboot()` (i8042 reset, `api/power.zig:17`).

### 5.3 `repl.lua` — REPL/terminál a sysmon jako okna

**REPL stav je v globálních proměnných** (`lines`, `current`, `history`, `hist_idx`,
`cursor` — `repl.lua:4`), aby **přežil hot reload** (`x or x or ...` idiom). Kernel o
stavu neví.

- UTF-8 helpery (`cp_start`, `cp_end`, `prev_cp`, `next_cp`) — kurzor je byte offset,
  ale edituje se po code pointech, aby se neroztrhl vícebajtový znak.
- `print(...)` přepisuje globální Lua `print` — píše do scrollbacku místo stdout.
- `run(code)` (`repl.lua:67`) — `load(code)` + `pcall(chunk)`; chyby → řádek do
  scrollbacku. Bezpečné: chyba skriptu se nikdy nešíří do kernelu.
- `repl_render()` — word-wrap po `max_chars` code pointech, scrollback ukazuje
  posledních `max_lines` řádků, prompt vždy dole; kurzor se kreslí jako akcentový
  blok na správné pozici (i na zalomeném promptu).
- `sysmon_render()` — RAM used/total, %, ticky přes `sysmon.*` bindingy.

### 5.4 `launcher.lua` — aplikace launcher

- `apps` — statický seznam `{title, id}` (repl, sysmon, files, toggle fullscreen,
  close).
- `launcher_filtered()` — jednoduché substring filtrování (case-insensitive).
- `launcher_render()` — centrovany popup 320 px: vyhledávací pole + list.
- `launcher_run(id)` — mapuje id na akci: zobrazení/zaostření okna (`repl`, `sysmon`,
  `files`), přepínání fullscreen, zavírání. Okna se **znovu používají**, ne duplikují
  (`find_win` → přesun na aktuální ws, nebo vytvoření); `repl`/`sysmon`/`files` se
  přesunou na `current_ws`, aby se okno otevřelo tam, kde jsi.

### 5.5 `input.lua` — vstupní obsluha

Dvě velké funkce:

- `handle_mouse()` (`input.lua:21`) — prioritizovaná hit-testovací sekvence:
  1. otevřené session menu → klik na položku / mimo;
  2. otevřený launcher → klik na položku / mimo;
  3. klik: topmost okno pod kurzorem (od konce seznamu) → `set_focus`; drag jen
     floating oken (`is_in_header`); workspace kaple; session tlačítko;
  4. drag update s clampem na obrazovku.
- `handle_key(ev)` (`input.lua:118`) — session menu, launcher (psaní, backspace,
  šipky, Enter), **Super zkratky** (tabulka §7), Alt+Tab, a konečně REPL editace
  (všechny pohybové/editační klávesy, UTF-8 aware).

Modifikátorový stav (shift/ctrl/alt/super/alt_gr/caps) **nedrží Lua** — udržuje ho
`bindings.zig` (§11) a každý key event ho nese v tabulce.

### 5.6 `main.lua` — frame orchestrace

```lua
function update()   -- main.lua:4  — mutace stavu
    if locked then ... any key unlocks; return end
    layout_pass()
    handle_mouse()
    ev = input.next_event() → if key+pressed → handle_key(ev)
end

function render()   -- main.lua:24 — čisté kreslení, žádná alokace
    if locked then ... end
    gfx.fill_screen(theme.background)
    layout_pass()          -- znovu (geometrie může být zastaralá)
    bar_render()
    if fullscreen_win then win_render(fs) return end
    -- tiled a floating odděleně, obě vzestupně podle z
    for _, w in tiled   do win_render(w) end
    for _, w in floating do win_render(w) end
    repl_render(); sysmon_render()
    if launcher_open then launcher_render() end
    if session_open  then session_menu_render() end
end
```

Důležité: `render()` je **čistá funkce** vzhledem k framebufferu — mění jen pixel
buffer, ne stav WM (jediná výjimka: `fullscreen_win = nil` při odchozím fullscreen
okně, čistě kvůli konzistenci). Neobsahuje žádné alokace (invariant Performance).

---

## 6. Tiling engine (layout algoritmus)

`layout_pass()` (`wm.lua:105`) se volá **dvakrát za frame** (v `update()` i `render()`),
protože geometrie je odvozená z `theme` a stavu WM, ne naopak.

### 6.1 Pracovní plocha

```
area_x = gap_out
area_y = bar.height + gap_out
area_w = SW - 2*gap_out
area_h = SH - bar.height - 2*gap_out
```

### 6.2 Fullscreen

Pokud je `fullscreen_win` na `current_ws` → okno pokryje celý framebuffer
`(0,0,SW,SH)`, bar se nekreslí (guard v `bar_render`), žádné jiné okno se nekreslí
(guard v `render`). Pokud fullscreen okno zmizí/přesune se jinam → `fullscreen_win = nil`.

### 6.3 Tiling: splith (60/40)

Splith řeší dva případy (`wm.lua:136`):

**Přesně 2 okna** — side-by-side, pozice stabilní (první v tiling pořadí vlevo),
**fokusované okno dostane širší split:**

```
w1 = floor(area_w * 0.6)     w2 = floor(area_w * 0.4)
gap = gap_in + border
left:   w = (focused? w1 : w2) - gap          x = area_x
right:  w = (focused? w1 : w2) - gap          x = area_x + (left šířka)
```

Pravé okno navazuje přesně na levé (offset = šířka levého), takže nedochází
k překryvu ani mezeře. Fokus širšího split == Hyprland konvence.

**3 a více oken** — **master-stack**: první okno v tiling pořadí je master
(vlevo, širší `w1` na plnou výšku), zbylá okna se skládají **svisle v pravém
sloupci** (šířka `w2`, řádky rovnoměrně):

```
stack_n = n - 1
row_h = floor((area_h - (stack_n-1)*gap) / stack_n)
master:  x=area_x          w=w1-gap   h=area_h
stack:   x=area_x+w1       w=w2-gap   y=area_y+(i-2)*(row_h+gap)   h=row_h
```

Master-stack zajišťuje, že se `n` oken nikdy nepřekrývá (master má 60 %, stack
40 % šířky a svislé řádky vyplní zbytek výšky).

### 6.4 Tiling: splitv (stack)

N oken svisle, rovnoměrně:

```
row_h = floor((area_h - (n-1)*gap) / n)
w.y = area_y + (i-1) * (row_h + gap)
```

### 6.5 Floating okna

Floating okna **nejsou layout_passem posouvána** — drží si manuální `x/y/w/h`
(nastavené float-togglem nebo dragem). V layout_pass se jen **přeskočí** (netilingují
se). Při přepnutí zpět na tiling se `x/y/w/h` vynulují (okno se „vrátí do mřížky").

### 6.6 Z-order a paint order

- `z` je monotónní číslo; `set_focus` ho jen zvyšuje (**list se nepřehazuje**).
- `render()` kreslí tiled odděleně od floating, v obou skupinách **vzestupně podle z**
  (dole = starší). Floating je vždy **nad** tiled (jiná skupina, kreslí se později).

### 6.7 Workspace kaple (geometrie, jeden zdroj pravdy)

```lua
-- wm.lua:173
local x = 8 + 20 + 8 + 4 + 5*8 + 12          -- launcher + mezera + hodiny "HH:MM"
for i, name in ipairs(theme.ws) do
    w = 4 + name:len()*8 + 8
    { i=i, x=x, w=w };  x = x + w + 6
end
```

`bar_render` ji kreslí a `input.lua` ji **hit-testuje** — oba volají stejnou funkci,
takže kliknutí a kresba nemohou divergovat.

---

## 7. Klávesové zkratky (data, ne kód)

Vše v `handle_key` (`input.lua:118`). Super = `ev.super` (Hyprland konvence).

| Kombinace | Akce | Místo |
|---|---|---|
| Super+Enter | zobraz + zaostřit REPL | `input.lua:183` |
| Super+Q | zavřít fokusované okno | `input.lua:187` |
| Super+Space | launcher toggle | `input.lua:211` |
| Super+Alt+Space | float toggle (centrovat) | `input.lua:195` |
| Super+F / Super+D | fullscreen toggle | `input.lua:217` |
| Super+J | togglesplit (splih↔splitv) | `input.lua:224` |
| Super+šipky | focus ve směru (wrap) | `input.lua:279` |
| Super+Shift+šipky | swap s okolím v tiling pořadí | `input.lua:253` |
| Super+1/2/3 | přepnout workspace | `input.lua:174` |
| Super+Shift+1/2/3 | přesunout okno na workspace | `input.lua:247` |
| Super+S | scratchpad (float toggle) | `input.lua:227` |
| Alt+Tab | cyklovat okna workspace | `input.lua:298` |
| F5 | hot reload (kernel, `main.zig:378`) | — |

---

## 8. Grafická část (Technical Architecture — rendering)

### 8.1 Render pipeline (celý řetězec)

```
Lua (win_render / bar_render / ...)
  │  gfx.draw_rect(x,y,w,h,color)          ← bindings.zig (extern struct + pointer)
  ▼
sys.dispatch(.Graphics, .{ .a = op, .b = &args })   ← api/sys.zig:36
  ▼
api/graphics.zig dispatch — @ptrFromInt(args.b) → typed struct → r.drawRect(...)
  ▼
render/renderer.zig — volá framebuffer primitiva (pixelColor konverze)
  ▼
fb/framebuffer.zig — přímý zápis do GOP paměti (volatile, clipping, WC wide-write)
```

- **Barva je jediná reprezentace `0xRRGGBB`** (u32) v celé cestě (`spec/graphics.md` §2);
  `framebuffer.pixelColor` přeloží do pixel formátu GOP (posuny masky).
- **Složené argumenty** (barvy, stringy) se předávají pointerem do paměti volajícího
  (`extern struct` v bindingech → `@ptrFromInt` v api) — žádná kopie.
- **Stringy bez kopie**: `TextArgs { text:u64(ptr), len:u64 }` (`bindings.zig:178`).

### 8.2 Kreslicí primitiva (co dělají — z implementace)

| Binding | Api op | Chování (framebuffer.zig) |
|---|---|---|
| `gfx.draw_rect` | `draw_rect` | `fillRect` — plný obdélník; 64-bit wide-write páry na zarovnaných řádcích, jinak 32-bit (WC buffer, `framebuffer.zig:68`) |
| `gfx.round_rect` | `round_rect` | střed + pásy `fillRect`, 4 rohy po `r×r` čtverci uvnitř oblouku (`framebuffer.zig:121`) |
| `gfx.rect_border` | `rect_border` | 4 `fillRect` pruhy (top/bottom/left/right), tloušťka clampnutá na `min(w/2,h/2)` |
| `gfx.gradient_border` | `gradient_border` | perimetr 2w+2h−4 px, po obvodu lineární interpolace colorA→colorB, barva se razítkuje jako `t×t` blok (`framebuffer.zig:164`) |
| `gfx.draw_text` | `draw_text` | iterace bytů → `font.glyph(c)` → `drawGlyphRow` (kreslí jen nastavené bity, zbytek nechá) |
| `gfx.fill_screen` | `fill_screen` | `fillRect(0,0,W,H)` |
| `gfx.present` | `present` | no-op v api (commit dělá event loop, §8.4) |
| `gfx.invalidate` | `invalidate` | nastaví `invalidate_requested` → event loop naplánuje re-render |
| `gfx.width/height` | `width`/`height` | rozměry framebufferu (z `renderer.fb`) |

**Font:** embedded bitmap font 8×16 (`font_data.zig`), `glyph(codepoint) → [16]u8`,
fallback na replacement znak. Text v Lua používá `glyph_w = 8`, `glyph_h = 16`
(`repl.lua:9`) a celočíselné layouty (pozice znaku = `x + i*8`).

### 8.3 Dekorace okna (win_render)

`win_render(w)` (`wm.lua:259`) kreslí v pořadí:

1. **Border** — aktivní: `gfx.gradient_border` (tyrkys→tmavá zeleň, `theme.accent` →
   `theme.accent_dark`); neaktivní: `gfx.rect_border` šedý.
2. **Title bar** — `draw_rect` s `blend(title_bg, opacity)`.
3. **Body** — `draw_rect` s `blend(theme.surface, opacity)`.
4. **Titulek** — text, aktivní barva vs dim.

`blend(color, factor)` (`wm.lua:245`) interpoluje barvu k `theme.background`
(neaktivní okno se „potopí" do pozadí): `out = color*factor + background*(1-factor)`
v celočíselné aritmetice (žádné FP v kernelu/renderingu).

### 8.4 Double buffering a present

- Renderer kreslí do **back bufferu** (PFA stránky, `main.zig:204`); Lua scéna, kurzor
  i bar kreslí tam.
- Po každém `render()` event loop zavolá `present()` (`main.zig:241`) — **jeden
  full-screen memcpy** z back bufferu do viditelného GOP framebufferu → žádný tearing
  uprostřed snímku.
- **Kurzor myši** je privilegovaný kernel overlay (`render/mouse_cursor.zig`):
  save/restore 12×19 px pod kurzorem + kresba sprite. Pohyb nečeká na Lua render loop
  (hladkost) — `poll()` aplikuje pakety a okamžitě `present()` (celá dávka jednou,
  `main.zig:410`). Po každém `render()` se kurzor překreslí `redraw()` (nesmí
  obnovovat zastaralé pixely, jinak artefakt tmavého obdélníku).

### 8.5 Paint order v render()

```
1. fill_screen(background)
2. bar_render()                     (vrchní pás; při fullscreen přeskočeno)
3. tiled okna      — vzestupně podle z
4. floating okna   — vzestupně podle z (nad tiled)
5. repl_render()   — REPL scrollback (okno "repl")
6. sysmon_render() — RAM/ticks (okno "sysmon")
7. launcher_render()   (pokud otevřen)
8. session_menu_render() (pokud otevřen)
```

### 8.6 Re-render model (invalidate / needs_render)

```zig
// main.zig:332
if (update()) { /* shell error → reload */ }
if (graphics.invalidate_requested) { needs_render = true; invalidate_requested = false; }
if (needs_render) { render(); needs_render = false; }
```

- `needs_render` se nastaví při: stisku klávesy, `gfx.invalidate()` (Lua — „překresli,
  i když nic nemačkám"), F5/reload, chybě renderu.
- Mezi frames se `hlt`uje; event loop se probudí na IRQ (PS/2, APIC timer).

---

## 9. Vstupní část (Technical Architecture — input)

### 9.1 Model myši: stav, ne eventy

- PS/2 pakety konzumuje **kernel overlay** v `poll()` (`main.zig:391`), spočítá
  absolutní pozici a uloží ji do `input/service.setMouseState(...)`.
- Lua **nedostává mouse eventy** (proto `buildEventTable` má `.mouse => unreachable`)
  — čte **stav** přes `input.mouse_x()/mouse_y()/mouse_left()/...`. Kliknutí a drag
  tak souhlasí s vykresleným kurzorem (`spec/input.md` §6).
- Bounded zpracování (max 64 paketů/poll), aby aktivní myš nevyhladověla klávesy/Lua.

### 9.2 Model kláves: fronta eventů

- IRQ → `service.pushKeyEvent` → kruhová fronta (256, atomické indexy,
  `queue.zig:15`) → `input.next_event()` z Lua vybere klávesy (mouse filtruje KI,
  `service.zig:74`).
- `buildEventTable` (`bindings.zig:319`) udržuje modifikátorový stav (shift/ctrl/
  alt/super/alt_gr/caps — `setShift`/`setCapsLock`/...) a vyrobí tabulku:

```lua
{ type="key", pressed=true, code="a",
  shift=false, ctrl=false, alt=false, super=false, alt_gr=false,
  char="a" }        -- char z layout.zig mapování (effectiveShift = shift XOR caps)
```

- **Shift XOR Caps** pro písmena (`bindings.zig:422`) — písmena jsou velká, když je
  aktivní právě jeden z nich.

### 9.3 Hit-testing a drag

`handle_mouse` hledá okno pod kurzorem **od konce seznamu** (poslední přidané =
naposledy focusované = „nejvýš" v dávce pořadí). Klik na hlavičku **floating** okna
zahájí drag (`drag = {title, dx, dy}`); hlavička je plocha pod borderem o výšce
`title_h` (`is_in_header`, `input.lua:6`). Během dragu se pozice clampuje do
obrazovky (`[0, SW-w]` × `[bar.height, SH-h]`).

### 9.4 REPL editace (UTF-8 aware)

Klávesy Enter/backspace/left/right/up/down/home/end/delete + `ev.char` pracují s
byte offsetem `cursor`, ale pohyb i mazání jde po code pointech (`prev_cp`/`next_cp`),
aby se nikdy neroztrhl vícebajtový znak. Historie: Up od nejnovějšího, Down do
draftu, `hist_idx` reset na 0.

---

## 10. Binding vrstva (Lua ↔ Kernel)

`bindings.zig:522 register()` registruje tabulky:

| Globál | Funkce | KI modul |
|---|---|---|
| `gfx` | draw_rect, round_rect, rect_border, gradient_border, draw_text, fill_screen, present, invalidate, width, height | `api/graphics` |
| `input` | next_event, mouse_x/y/left/right/middle, set_layout, layout_name | `api/input` |
| `time` | ticks | `api/timer` |
| `debug` | write | `api/debug` |
| `sysmon` | ram_total_mb, ram_free_mb | `api/sysmon` |
| `runtime` | reload | `api/runtime` |
| `power` | reboot | `api/power` |

**Marshalling pravidla** (`spec/runtime.md` §4):

- `checkInteger` / `checkString` striktně validují typ; špatný typ → `nil, err_string`
  (`"expected integer for 'x', got string"`), nikdy panic — binding je bezpečnostní
  hranice.
- **Žádné floaty** v jádře (kreslení celočíselné); `number` z Lua není v API.
- Barvy jen `0xRRGGBB` u32.
- Vše prochází `sys.dispatch` → `api/*`; binding nikdy neimportuje kernel internals
  napřímo.

---

## 11. Runtime integrace a error containment

- **Jeden globální `lua_State`** = shell (`lua.zig:8`). Alokace přes
  `luaAlloc` (`lua.zig:22`) na kernel heap alokátor + `libc.zig` shim (malloc/
  realloc/free/vsnprintf pro C stranu Luy).
- **Každý vstup kernel→Lua je přes `lua_pcall`** (`callGlobalFunction`,
  `lua.zig:176`): chyba `update()`/`render()` se nešíří do Zig stacku → vrátí se
  `CallResult.err` a event loop spustí hot reload (`main.zig:336`).
- **Hot reload odložený:** trigger (F5, chyba, `runtime.reload()`) jen nastaví flag
  (`api/runtime.zig:54`); `lua_close`+`createState` dělá **event loop mimo jakýkoliv
  Lua call frame** (`performReload`, `main.zig:346`) — nikdy se nezavírá stát, na
  kterém stojí C funkce (use-after-free prevence, `spec/runtime.md` §5).
- **GC rozpočet:** v každém `update()` se volá `gcStep(1024)` (`main.zig:420`) —
  inkrementální GC krok v budgetu frame, nikdy v `render()`.

---

## 12. Sekvenční diagramy

### 12.1 Boot → první frame

```
BIOS → Limine → _start (stack switch, SSE) → kernelMain
  → boot.collect (framebuffer info)
  → idt/pic/apic/paging/ps2 init
  → initGraphics (back buffer, renderer, cursor, mouse state)
  → runtime.init → lua.init → createState → bindings.register
  → runtime.spawn(.Lua, "main.lua") → lua.runMain (načte initrd → 1 chunk → spustí)
  → eventLoop: poll → update → render → "ASTER FIRST FRAME" → hlt
```

### 12.2 Jeden frame (update/render)

```
IRQ (timer/klávesa/myš) → probuzení z hlt
poll():  timer ticky → pop;  F5 → reload flag;  klávesa → needs_render
         myš → overlay move + setMouseState (dávka, jednou present)
update(): layout_pass → handle_mouse → next_event → handle_key  (+gcStep)
reloadRequested? → performReload (lua_close + createState + runMain)
needs_render? → render():
    callRender → fill_screen, layout_pass, bar_render, win_render*,
                 repl/sysmon/launcher/session overlay
    mouse_cursor.redraw (save+draw pod kurzorem)
    present() (back → front memcpy)
hlt
```

### 12.3 Super+Enter (ukázat REPL)

```
Lua handle_key → repl.ws = current_ws → repl_visible = true → set_focus("repl")
set_focus: focused="repl", z++ (bez reorder), gfx.invalidate()
event loop: invalidate_requested → needs_render → render() kreslí repl okno nahoře
```

### 12.4 Hot reload (F5 / chyba / runtime.reload)

```
poll() F5 → runtime.requestReload() (jen flag)
nebo update() vrátí err → requestReload() (zotavení z polorozkresleného stavu)
nebo session menu "Logout" → runtime.reload() → requestReload()
→ event loop: reloadRequested → performReload()
   → lua.reload(): lua_close(old) + createState() + runMain("main.lua")
   → needs_render = true (nový shell se nakreslí)
```

---

## 13. Invarianty a pravidla (dodržuje WM)

| Pravidlo | Kde platí |
|---|---|
| Žádný heap alloc při renderu | `render()` jen volá `gfx.*`; alokace (REPL, launcher) jen v `update()` |
| Žádné FP | `blend`, layout, gradient — vše celočíselné (`math.floor`, `>>`,`&`) |
| Determinismus | stejný vstup → stejné pixely (žádné náhodné pořadí) |
| Lua nikdy přímo do framebufferu | všechno přes KI bindings |
| Bindings jsou bezpečnostní hranice | `checkInteger`/`checkString` → `nil, err`, nikdy panic |
| Fokus nikdy nemění tiling pořadí | `set_focus` jen zvyšuje `z` |
| Jediný zdroj pravdy pro geometrii | `ws_capsules()` sdílí bar i input |
| Odložený reload | `lua_close` nikdy na aktivním C stacku |
| Event loop jediný konzument | frontu konzumuje jen `poll()` + `input.next_event()` (stejný kontext) |

Viz také `spec/invariants.md` (Safety / Performance / Architecture) a
`spec/code-style.md`.

---

## 14. Design rationale (RFC: proč to je takhle postavené)

| # | Rozhodnutí | Odmítnuté alternativy | Důvod |
|---|---|---|---|
| D1 | Jeden konkatenovaný chunk, ne `require`/moduly | `require` + FS, `package.loaded`, oddělené chunky | žádná FS závislost v kernelu; `local` stav sdílený napříč shellem; jednodušší hot reload (§3, `lua.zig:111`) |
| D2 | `update()`/`render()` konvence místo registrace | callback registry, `app.register({...})` | kernel nezná jména funkcí UI; konvence = nejmenší rozhraní (`spec/runtime.md` §4) |
| D3 | Pořadí v `windows` = tiling order, `z` jen focus | řadit podle `z` při každém focusu | focus by musel přehazovat list → rozhoupal by layout; oddělení focus od layoutu (`wm.lua:62`) |
| D4 | Geometrie kapslí jako funkce (1 zdroj pravdy) | duplikovat vzorec v renderu i inputu | dvě kopie vzorce by driftovaly → klikání mimo kresbu (bug) |
| D5 | Vzhled jako data (`theme`), hot reload F5 | config formát, recompile | „živá transformace", kernel se nikdy nepřestavuje (`spec/runtime.md` §5a) |
| D6 | Myš jako stav (poll), klávesy jako eventy | myš jako eventy, klávesy jako stav | overlay potřebuje hladký pohyb bez Lua round-tripu; klávesy jsou řídké, eventy stačí (`spec/input.md` §6) |
| D7 | Složené argumenty pointerem (extern struct) | kopie, marshalling do registry | žádná kopie velkých struktur; wire formát KI (§10) |
| D8 | Float toggle / scratchpad sdílí jednu cestu | samostatný scratchpad workspace | nejmenší kód; scratchpad = floating okno v „kapse" |
| D9 | Bindingy vracejí `nil, err` místo panic | pcall + log, ignore | marshalling je bezpečnostní hranice; kernel nesmí shodit skript |
| D10 | REPL stav v globálu přeživším reload | stav v userdata kernelu | uživatelské data nepřežívají `lua_State` (invariant use-after-free); globál je čistě Lua doména |

---

## 15. Rozšířitelnost a budoucí směr

- **M6 initfs/perzistence:** `theme.lua` a shell moduly se mají číst ze souborů na
  disku (ext2, `spec/roadmap.md`) — balení v initrd je mezistupeň; `addFileArg`
  tracking zůstává.
- **M7 programy:** `Program` se stává schedulable kontextem (ADR-017); okna dnes
  sdílí jediný shell — aplikace dostanou vlastní `lua_State`/Wasm modul a obsah okna
  bude z programu, ne z `repl/sysmon_render`.
- **Aplikace:** model „okno + render funkce" (`spec/desktop-ui.md` §4.7) se rozšiřuje
  o files (po FS), calculator, systémové widgety.
- **Animace:** fade přes interpolaci barev v renderu (bez GPU), vyhrazeno.

---

## 16. Slovník pojmů

| Termín | Význam |
|---|---|
| **WM** | Window Manager — Lua shell `src/kernel/lua/ui/` |
| **Chunk** | jeden Lua kus kódu; celý shell je jeden chunk |
| **KI** | Kernel Interface — `sys.dispatch` + `api/*` |
| **Tiling order** | pořadí v seznamu `windows` (layout), nezávislé na `z` |
| **z-order** | kreslicí pořadí (`z`), focus ho mění |
| **Overlay** | vrstva kreslená mimo Lua render (kurzor myši) |
| **Hot reload** | re-inicializace `lua_State` bez restartu systému (F5) |
| **invalidate** | žádost o re-render bez vstupu (Lua → kernel) |

---

## 17. Index zdrojů (mapa soubor → sekce)

| Soubor | Sekce |
|---|---|
| `src/kernel/lua/ui/theme.lua` | §5.1 |
| `src/kernel/lua/ui/wm.lua` | §5.2, §6 |
| `src/kernel/lua/ui/repl.lua` | §5.3, §9.4 |
| `src/kernel/lua/ui/launcher.lua` | §5.4 |
| `src/kernel/lua/ui/input.lua` | §5.5, §7, §9 |
| `src/kernel/lua/ui/main.lua` | §5.6 |
| `src/kernel/lua/lua.zig` | §3.2, §11 |
| `src/kernel/lua/bindings.zig` | §8.1, §10 |
| `src/kernel/lua/libc.zig` | §11 |
| `src/kernel/lua/cimport.zig` | §4 |
| `src/kernel/main.zig` | §8.4, §8.6, §11, §12 |
| `build.zig` | §3.1 |
| `src/kernel/api/graphics.zig` | §8.1 |
| `src/kernel/api/input.zig` | §9 |
| `src/kernel/api/runtime.zig` | §11 |
| `src/kernel/api/{timer,sysmon,debug,power,sys}.zig` | §2 |
| `src/kernel/render/renderer.zig` | §8.1 |
| `src/kernel/render/font.zig` / `font_data.zig` | §8.2 |
| `src/kernel/render/mouse_cursor.zig` | §8.4 |
| `src/kernel/fb/framebuffer.zig` | §8.2 |
| `src/kernel/input/{service,queue}.zig` | §9.2 |
