# Graphics — Graphics API → Renderer → Framebuffer

**Status:** V1 (draft). **Rozhodnutí:** ADR-005, ADR-009.

---

## 1. Vrstvy

```
Lua / Shell
   ↓
Graphics API      ← KI (jediný veřejný povrch, který Lua vidí)
   ↓
Renderer          ← interní; dnes fillRect→fb, zítra GPU backend, později IPC compositor
   ↓
Framebuffer       ← přímý zápis do GOP paměti (Limine)
```

**Zásada:** Lua nikdy nevidí níž než Graphics API. Renderer nesmí znát Lua VM.
Framebuffer nesmí uniknout za Renderer.

**Kurzor myši je privilegovaný overlay (výjimka z hranice):** `render/mouse_cursor.zig`
ukládá/obnovuje pixely a kreslí sprite přímo do framebufferu (12×19 px), protože pohyb
myši nesmí čekat na Lua render loop. Je to kernelová overlay vrstva — součást graphics
subsystemu (vedle Rendereru), ne aplikační cesta:

```text
                  ┌── Renderer ──────────────→ Framebuffer
Event loop ───────┤
                  └── MouseCursor (overlay) ─→ Framebuffer
```

Renderer zůstává jediným framebuffer writerem pro **běžné GUI kreslení**; overlay má
omezený, výhradně kernelový přístup (save/restore + sprite). Input subsystem o
framebufferu neví — mouse events předává event loopu, který je aplikuje na overlay
(`spec/input.md` §9). Compositor (M8+) nahradí overlay konceptem vrstev.

---

## 2. Graphics API (KI)

Veřejná operace (čísla sub-op jsou rozšiřitelná, zmrazená):

| # | Operace | Signatura | Poznámka |
|---|---------|-----------|----------|
| 0 | `drawRect` | `(x, y, w, h, color)` | plný obdélník, nevyhlazený (M3) |
| 1 | `blit` | *(rezervováno)* | **bez volajícího** — číslo zmrazené (KI pravidlo „čísla se nemazají"), dispatch vrací `NotSupported`; YAGNI, `code-style.md` §1 |
| 2 | `drawGlyph` | `(codepoint, x, y, color)` | z embedded bitmap fontu |
| 3 | `drawText` | `(str, x, y, color)` | n-tice glyphů |
| 4 | `fillScreen` | `(color)` | |
| 5 | `present` | `()` | commit back bufferu do framebufferu (Phase 2; v event loopu, ne z Lua) |
| 6 | `invalidate` | `()` | shell žádá re-render bez klávesy (živá transformace, M5) |
| 7 | `roundRect` | `(x, y, w, h, radius, color)` | zaoblené rohy (M5, kaple v taskbaru) |
| 8 | `rectBorder` | `(x, y, w, h, thickness, color)` | ohraničení obdélníku (M5) |
| 9 | `gradientBorder` | `(x, y, w, h, thickness, colorA, colorB)` | lineární interpolace po obvodu (M5, aktivní okno) |
| 10 | `width` | `()` | šířka framebufferu v pixelech |
| 11 | `height` | `()` | výška framebufferu v pixelech |

**Typ barvy (rozhodnuto, V1):** `Color = u32`, reprezentace **`0xRRGGBB`** (horní byte 0).
Stejná reprezentace ve všech vrstvách (Lua → KI → Graphics API → Renderer → Framebuffer)
i v KI wire formátu. Žádná druhá reprezentace (viz `spec/runtime.md` §4).
Zápis do framebufferu podle jeho pixel formátu (RGBA/BGRA dle GOP info, §4).

**Předávání argumentů:** složené argumenty (barva, stringy) se přes `dispatch`
předávají pointerem na paměť volajícího (viz `spec/kernel-interface.md` §3.2).

**Povolené, ale odložené (YAGNI):** alpha blending, stb_truetype (TTF),
GPU backend, dvojitý buffer / vsync. Přidávají se až s reálným důvodem a měřením.

---

## 3. Renderer (interní vrstva)

Dnes je to tenká vrstva, která mapuje API operace na framebuffer. Je to **přesně to místo**,
kde se zítra objeví GPU backend nebo IPC → Compositor.

```
renderer.zig
    drawRect(...)      → fb.fillRect(...)
    blit(...)          → fb.blit(...)
    drawGlyph(...)     → font.rasterize(...) → fb.blit(...)
    drawText(...)      → iterace glyphů
    roundRect(...)     → fb.roundRect(...)
    rectBorder(...)    → fb.rectBorder(...)
    gradientBorder(...)→ fb.gradientBorder(...)
```

**Požadavky na Renderer:**

- Žádný heap allocation na kritické cestě (invariant Performance, viz `spec/invariants.md`).
- Žádná kopie celého framebufferu (výjimka: save/restore kurzoru myši 12×19 px, viz
  `spec/invariants.md` Performance).
- Deterministický: stejný vstup → stejné pixely.

---

## 4. Framebuffer

- Zdroj: **Limine GOP framebuffer** (UEFI) — width/height, pitch, bpp. `address` z Limine
  je **již v hhdm prostoru** (vyšší polovina; empiricky ověřeno v M3, QEMU q35) — zapisuje
  se přímo, bez přičítání hhdm offsetu. To je důvod, proč `cache_attr` walk (`memory.md` §6)
  bere tuto adresu jako virtuální.
- Reprezentace: `Framebuffer` struct s pointerem na paměť + metadaty.
- Formát pixelu: závisí na GOP; pro první verzi fixní RGBA/BGRA dle Limine info.
- Cache atribut (UC vs WC): viz `spec/memory.md` §6 — v M1 se ověří, v M3 případný
  přepis PAT na WC jen pro tento region.
- Prezentace (Phase 2, hotovo): render do offscreen back bufferu (PFA stránky),
  `present` kopíruje celý back buffer do framebufferu najednou — žádný tearing
  uprostřed snímku. Renderer, Lua scéna i kurzor myši kreslí do back bufferu;
  `present` volá event loop po každém renderu (viz `graphics.md` §7 a handoff H4).

### Primitiva (povolená minimální sada)

```zig
fn fillRect(fb: *Framebuffer, x: i32, y: i32, w: u32, h: u32, color: Color) void
fn blit(fb: *Framebuffer, src: [*]const u8, srcX: i32, srcY: i32, dstX: i32, dstY: i32, w: u32, h: u32) void
fn fillScreen(fb: *Framebuffer, color: Color) void
fn roundRect(fb: *Framebuffer, x: i32, y: i32, w: u32, h: u32, radius: u32, color: Color) void  // M5
fn rectBorder(fb: *Framebuffer, x: i32, y: i32, w: u32, h: u32, thickness: u32, color: Color) void  // M5
fn gradientBorder(fb: *Framebuffer, x: i32, y: i32, w: u32, h: u32, thickness: u32, colorA: Color, colorB: Color) void  // M5
```

Oříznutí (clipping) na hranice framebufferu je **povinné** ve všech primitivech.

- `roundRect` vyplňuje obdélník se zaoblenými rohy; rohové pixely mimo oblouk se nechávají
  beze změny (střed + pásy se plní `fillRect`, rohy po čtverci r×r).
- `gradientBorder` kreslí ohraničení, jehož barva lineárně interpoluje od `colorA`
  (levý horní roh) k `colorB` (pravý dolní) po celém obvodu (2w + 2h − 4 pixelů).

---

## 5. Font

- **Formát:** embedded bitmap font (kompaktní, fixní rozměr glyfu, např. 8x16).
- **Umístění:** zakompilovaný do binárky (`@embedFile`).
- **API:** `glyph(codepoint) → bitmap` s fallbackem na replacement znak pro chybějící
  codepoint.
- **Odloženo:** TTF přes stb_truetype, variabilní šířky, hinting, ligatury — až s FS (M6+).

---

## 6. Výkonnostní invarianty (viz `spec/invariants.md`)

- Žádná kopie celého framebufferu (výjimka: kurzor overlay ukládá/obnovuje 12×19 px pod
  kurzorem a kreslí 12×19 px sprite — `mouse_cursor.zig`, viz `spec/invariants.md`
  Performance).
- Žádný heap allocation při renderingu.
- Žádná dynamická alokace v běžném frame.
- Frame latency (p99) je sledovaná metrika (viz `spec/roadmap.md`).

---

## 7. Budoucí cesta (bez změny API)

```
M3:  Lua → Graphics API → Renderer(1) → Framebuffer (přímý zápis)
M? : Lua → Graphics API → Renderer(GPU) → Framebuffer          (nový backend, stejná API)
M? : Lua → Graphics API → IPC Compositor → Renderer → Framebuffer
```

Aplikace nikdy nekreslí přímo do framebufferu — to zůstane vynucené právě proto, aby tato
migrace byla možná.
