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

---

## 2. Graphics API (KI)

Veřejná operace (čísla sub-op jsou rozšiřitelná, zmrazená):

| # | Operace | Signatura | Poznámka |
|---|---------|-----------|----------|
| 0 | `drawRect` | `(x, y, w, h, color)` | plný obdélník, nevyhlazený (M3) |
| 1 | `blit` | `(src, srcX, srcY, dstX, dstY, w, h)` | kopie bloku pixelů |
| 2 | `drawGlyph` | `(codepoint, x, y, color)` | z embedded bitmap fontu |
| 3 | `drawText` | `(str, x, y, color)` | n-tice glyphů |
| 4 | `fillScreen` | `(color)` | |
| 5 | `present` | `()` | výhledově: commit bufferu; dnes no-op/okamžitý |

**Typ barvy (rozhodnuto, V1):** `Color = u32`, reprezentace **`0xRRGGBB`** (horní byte 0).
Stejná reprezentace ve všech vrstvách (Lua → KI → Graphics API → Renderer → Framebuffer)
i v KI wire formátu. Žádná druhá reprezentace (viz `spec/runtime.md` §4).
Zápis do framebufferu podle jeho pixel formátu (RGBA/BGRA dle GOP info, §4).

**Předávání argumentů:** složené argumenty (barva, stringy) se přes `dispatch`
předávají pointerem na paměť volajícího (viz `spec/kernel-interface.md` §3.2).

**Povolené, ale odložené (YAGNI):** alpha blending, rounded corners, stb_truetype (TTF),
GPU backend, dvojitý buffer / vsync. Přidávají se až s reálným důvodem a měřením.

---

## 3. Renderer (interní vrstva)

Dnes je to tenká vrstva, která mapuje API operace na framebuffer. Je to **přesně to místo**,
kde se zítra objeví GPU backend nebo IPC → Compositor.

```
renderer.zig
    drawRect(...)  → fb.fillRect(...)
    blit(...)      → fb.blit(...)
    drawGlyph(...) → font.rasterize(...) → fb.blit(...)
    drawText(...)  → iterace glyphů
```

**Požadavky na Renderer:**

- Žádný heap allocation na kritické cestě (invariant Performance, viz `spec/invariants.md`).
- Žádná kopie framebufferu.
- Deterministický: stejný vstup → stejné pixely.

---

## 4. Framebuffer

- Zdroj: **Limine GOP framebuffer** (UEFI) — fyzická adresa, width/height, pitch, bpp.
- Reprezentace: `Framebuffer` struct s pointerem na paměť + metadaty.
- Formát pixelu: závisí na GOP; pro první verzi fixní RGBA/BGRA dle Limine info.
- Cache atribut (UC vs WC): viz `spec/memory.md` §6 — v M1 se ověří, v M3 případný
  přepis PAT na WC jen pro tento region.
- Žádné double buffering v M3–M4. Prezentace je přímý zápis (viz `present` no-op).

### Primitiva (povolená minimální sada)

```zig
fn fillRect(fb: *Framebuffer, x: i32, y: i32, w: u32, h: u32, color: Color) void
fn blit(fb: *Framebuffer, src: [*]const u8, srcX: i32, srcY: i32, dstX: i32, dstY: i32, w: u32, h: u32) void
fn fillScreen(fb: *Framebuffer, color: Color) void
```

Oříznutí (clipping) na hranice framebufferu je **povinné** ve všech primitivech.

---

## 5. Font

- **Formát:** embedded bitmap font (kompaktní, fixní rozměr glyfu, např. 8x16).
- **Umístění:** zakompilovaný do binárky (`@embedFile`).
- **API:** `glyph(codepoint) → bitmap` s fallbackem na replacement znak pro chybějící
  codepoint.
- **Odloženo:** TTF přes stb_truetype, variabilní šířky, hinting, ligatury — až s FS (M6+).

---

## 6. Výkonnostní invarianty (viz `spec/invariants.md`)

- Žádná kopie framebufferu.
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
