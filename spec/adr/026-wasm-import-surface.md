# ADR-026 — Wasm import surface a surface model (Fáze B)

**Status:** Accepted
**Datum:** 2026-08-18

## Rozhodnutí
Home-wasm programy (M7, wasm3) dostávají **stabilní import surface** (modul `env`)
a **surface model**: každý GUI program má vlastní offscreen pixel surface, kreslí
do ní přes importy `draw_rect`/`draw_text`, a kernel ji kompozituje do render
targetu na pozici, kterou každý frame určí WM (`api/runtime.surface_render(handle,
x, y)`). Program je **persistentní** — spawn volá exportovaný `start` jednou, pak
se per-frame tickují `update` (vstup, stav) a `render` (kresba do surface) — a je
**singleton per jméno** (spawn stejného jména vrací běžící instanci), což odpovídá
desktopové konvenci „jedna běžící instance aplikace" (editor/files v WM).
Vstup čte program přes importy myši v **surface-lokálních souřadnicích**.

Tím se uzavírá Fáze B M7 (`spec/roadmap.md`): kalkulačka ověří celý řetězec
end-to-end (wasm3 → vlastní lineární paměť → KI volání → composite do vlastní
surface → input eventy), bez ladění dvou neznámých najednou.

## Odůvodnění
- **Izolace je hodnota, ne výkon** (`spec/runtime.md` §7): program nikdy nekreslí
  přímo do framebufferu ani nečte globální stav — jen do vlastní surface a jen
  přes stabilní importy. To je vizuální důkaz izolace z manifestu („program, co
  spadne, a desktop běží dál" — trap containment z Fáze A + vlastní surface).
- **Kontrakt musí být stabilní od prvního dne** (ADR-003): wasm import surface je
  ekvivalent `kernel-interface.md` §4 pro Lua. Kalkulačka a benchmark ji zafixují;
  teprve pak se zve kontributory (M10 Adoption), jinak by první příspěvky rozbil
  vlastní refaktor.
- **Surface je runtime artefakt, composite je grafika.** Rozděluje to odpovědnosti:
  wasm runtime vlastní surface buffer (alokace, kresba), render target vlastní
  `api/graphics`. Šev mezi nimi je `api/runtime` — jediný modul, který smí znát
  konkrétní runtimes (composition-root výjimka, ADR-006). Žádná jiná vrstva
  kernelu nevidí wasm-specifický kód.
- **Žádné alokace při renderu** (`spec/invariants.md`): surface se alokuje při
  spawn (povolené „ojedinělé eventy"), ne v render path. Composite je jen blit.
- **WM zůstává majitelem oken** (z-order, tiling, focus) — kernel nevytváří
  „wasm okna". WM kreslí frame a v z-order řádném pořadí zavolá `surface_render`,
  takže překrývání oken funguje správně bez kernelové správy oken.
- **F5 a hot reload** (`spec/runtime.md` §5): wasm programy žijí kernel-side a
  přežijí restart Lua shellu. Dedup per jméno dělá z opakovaného spawuu idempotentní
  operaci, takže po F5 se nevytvoří druhá instance kalkulačky.

## Důsledky

### Import surface — stabilní kontrakt (modul `env`)

Zig targety importují z modulu `env` a pojmenují import podle `extern` symbolu.
Názvy, modul a signatury se **nikdy nemění**; rozšíření = nová funkce na konec.
Marshalling textu přes lineární paměť (offset, ne pointer).

| funkce | wasm3 signature | popis |
|---|---|---|
| `debug_write` | `v(i)` | NUL string offset z lineární paměti → serial (Fáze A) |
| `draw_rect` | `v(iiiii)` | `(x, y, w, h, color)` → surface, souřadnice relativní k surface |
| `draw_text` | `v(iiii)` | `(str_offset, x, y, color)` → surface, monospace glyfy |
| `surface_width` | `i()` | šířka surface v px |
| `surface_height` | `i()` | výška surface v px |
| `input_mouse_x` | `i()` | X myši relativně k surface origin (i32) |
| `input_mouse_y` | `i()` | Y myši relativně k surface origin (i32) |
| `input_mouse_left` | `i()` | stav levého tlačítka (0/1) |

### Surface

- **Fixní velikost** pro Fázi B: konstanta v `wasm.zig` (224×160 px, 32bpp
  `0x00RRGGBB`). Per-program velikost (exportovaná konstanta / spawn argument)
  je výhled, ne součást Fáze B.
- Alokace `w*h*4` z kernel heapu při spawn; uvolnění při `free` programu.
- Surface je `Framebuffer` (base = buffer, pitch = w*4, bytes_per_pixel = 4,
  red/green/blue shift 16/8/0) s vlastním `Renderer` — stejná primitiva jako
  hlavní framebuffer (`render/renderer.zig`), takže draw_rect/draw_text v surface
  sdílí font, clipping i pixel formát.
- **Composite:** `api/runtime.surface_render` blitne surface do render targetu
  (`graphics.renderer.blit(surface, 0, 0, x, y, w, h)`). WM volá op s content
  originem okna; pokud je window větší než surface, zbytek plochy zůstává body
  backgroundem WM.

### API

- `RuntimeOp.surface_render = 4` (append na konec enumu, čísla se nemění):
  args `SurfaceRenderArgs { handle: u64, x: i32, y: i32 }` přes `args.b`.
  Návrat: `Success` / `NotFound` (neznámý handle) / `NotSupported` (Lua program).
- `api/runtime` rozšíří composition-root výjimku o `api/graphics` (kvůli blitu) —
  jediný api→api import v projektu, zdokumentovaný u importu.
- Poslední placement (x, y) se ukládá do `Program`; `input_mouse_x/y` =
  `input_service.mouseX() - placed_x` (a analogicky Y). Surface-lokální souřadnice
  = program žije ve vlastním souřadném prostoru, WM posun okna (drag/tiling/ws)
  se automaticky promítne přes aktuální `surface_render` placement.

### Životní cyklus programu

- `wasm.spawn(source, name)`: dedup per jméno (živý program se stejným jménem →
  vrací existující handle, `start` se nevolá znovu); najde volný slot ve statické
  tabulce `Program` (bez alokace); vytvoří runtime s `userdata = *Program`
  (`m3_NewRuntime`, `m3_GetUserData` v import handleru); alokuje surface; najde
  exporty `start`/`update`/`render`; zavolá `start` pod trap containment.
- `wasm.tickPrograms()` (volané z kernel `update()` fáze po `lua.tickPrograms`):
  per živý program volá `update()` a `render()` pod trap containment; trap →
  program se zahodí (free), shell a ostatní běží dál.
- Program bez exportu `update`/`render` (hello/fault) se po `start` nechá idle.
- `kill` zůstává Fázi B mimo (window close = program zůstává živý; dedup per jméno
  ho při znovuotevření vrací).

### Kalkulačka

- První GUI wasm program (`src/kernel/apps/calculator.zig`), writer v Zigu
  (`wasm32-freestanding`, bez libc — bump allocator nad lineární pamětí).
- Displej + 4×4 tlačítka (`7 8 9 +`, `4 5 6 -`, `1 2 3 *`, `C 0 = /`),
  kresba draw_rect/draw_text, hit-test v `update` přes `input_mouse_*`.
- Barvy hardcoded (theme import je výhled, ne Fáze B).
- Launcher entry `calculator` (hardcoded `apps` tabulka; dynamický scan je M8).
- WM: okno `calculator` + `runtime.spawn("calculator")` při prvním otevření,
  `runtime.surface_render(handle, content_x, content_y)` v `render_window_content`.

### Rozsah / non-goals

- Bez alpha kanálu (surface je plně opakní blit), bez resize, bez per-program
  velikosti, bez theme/barvy z WM, bez keyboard eventů pro programy, bez WASI.
- Keyboard pro wasm programy je výhled (import surface se rozšíří na konec).
- Benchmark (Fáze C) je samostatný úkol po kalkulačce.

## Související
- ADR-011 (wasm3), ADR-006 (generický Runtime API), ADR-003 (stabilní rozhraní)
- `spec/roadmap.md` M7 (Fáze A/B/C, benchmark jako dluh před uzavřením M7)
- `spec/runtime.md` §7 (Wasm stav a pravidla), §1 (Runtime generický)
- `spec/lua-wm.md` §7a.4 (aplikace), §15 (M7 programy, zbývá surface model)
- Změna tohoto návrhu = nový ADR odkazující na tento.