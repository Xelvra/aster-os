# Desktop — UI port z cachyos-hypr-noctalia

**Status:** V1 (draft). **Cíl:** atomický popis desktopu — co přesně vidí uživatel,
komponenta po komponentě. Zdrojem je [`cachyos-hypr-noctalia`](https://github.com/CachyOS/cachyos-hypr-noctalia)
(config/dotfiles pro Hyprland + Noctalia shell); portujeme **vzhled a chování**, ne
software (Hyprland/Wayland/GTK/Qt v našem kernelu neběží).

> **Transparentnost / licence:** upstream repo **nemá licenční soubor** (výchozí stav
> „all rights reserved") — Aster OS proto **neobsahuje a nevendoruje žádný jeho soubor**.
> Port znamená reimplementaci vizuálního konceptu a Hyprland konvencí vlastním kódem
> (barvy jako data, klávesové zkratky jako data); poděkování viz
> `THIRD-PARTY-NOTICES.md` (sekce „Thematic inspiration").

---

## 1. Vize

Aster OS má být použitelný desktop, ne jen okenní manager. Rozdíl:

- **Okenní manager (dnešní stav):** otevřeš okna, přepínáš workspace, zavíráš.
- **Desktop (cíl):** prostředí, které hned po bootu vypadá hotové — bar s hodinami
  a widgety, launcher, klikatelné věci, systémový monitor, konzistence barev
  v každém koutě obrazovky.

Tento dokument rozepisuje **každou viditelnou komponentu** zvlášť (atomicky), aby se
nedělala jedna velká "zkus desktop" krabice.

---

## 2. Komponentní rozpad cachyos-hypr-noctalia

Co repo obsahuje a co z toho portujeme:

| Komponenta | Soubory v repu | Portovatelné? | Kam to dáme |
|---|---|---|---|
| **Barvy (Cachy paleta)** | `hypr/config/colors.lua` | ✅ ano | `ui/theme.lua` |
| **Dekorace oken** (border, rounding, gaps, opacity) | `hypr/config/decorations.lua` | ✅ částečně — border/gaps/opacity ano, **rounding ne** (§4.4) | `ui/wm.lua` (theme.wm) |
| **Zkratky** (Super+...) | `hypr/config/binds.lua` | ✅ ano | `ui/input.lua` (hotovo) |
| **Workspaces 1–3** | `hypr/config/workspaces.lua` | ✅ ano | `ui/wm.lua` (hotovo) |
| **Taskbar/bar** (launcher, clock, workspace štítky, media, tray, network, volume) | `noctalia/config.toml` | ✅ vzhled ano | `ui/wm.lua` bar_render |
| **Launcher** (Super+Space) | binds + Noctalia launcher | ✅ ano | `ui/launcher.lua` (hotovo) |
| **Animace** (ease curves, slide) | `hypr/config/animations.lua` | ⚠️ částečně (bez GPU; viz §6) | kernel render |
| **Window rules** (float modály, centrování) | `hypr/config/windowrules.lua` | ✅ koncept | `ui/wm.lua` |
| **Cursor theme** (Bibata-Modern-Ice) | `.local/share/icons/...` | ⚠️ vzhled | kernel `mouse_cursor.zig` |
| **Greeter (login screen)** | `noctalia-greeter/` | ⏸️ odloženo | — |
| **Splash** (zelený text) | `misc.lua` col.splash | ✅ ano | boot serial/gfx |
| **Aplikace** (kitty, dolphin, btop, gnome-*) | app configs | ❌ nelze (Linux binárky) | vlastní Lua ekvivalent |
| **GTK/Qt theme, xsettingsd, qt6ct** | gtk.css, qt6ct.conf... | ❌ nelze | jen barvy v theme |
| **Blur / GPU efekty** | decorations.blur | ❌ nelze (kernel framebuffer) | — |

---

## 3. Architektura

UI běží v Lua (`src/kernel/lua/ui/`), kernel poskytuje jen primitiva a vstup.

```
src/kernel/lua/ui/
├── theme.lua     # barvy + geometrie (port Cachy palety)
├── wm.lua        # okna, layout, bar, dekorace
├── repl.lua      # terminál/REPL jako okno
├── editor.lua    # textový editor (Super+T)
├── files.lua     # file manager (Super+E)
├── launcher.lua  # Super+Space aplikace
├── input.lua     # klávesnice + myš (Hyprland zkratky)
└── main.lua      # update()/render() entry
```

**Zásady:**
- Vzhled je **data** (`theme` tabulka), ne kód — živá transformace, F5 hot reload.
- Každý widget je **atomická komponenta**: jedna funkce render + vlastní stav,
  skládatelné do bar/panel/popup.
- Žádný heap alloc při renderu; deterministický (invarianty).

---

## 4. Atomické komponenty (co vidí uživatel)

> Stav: ✅ hotovo / 🔶 částečně / ⏳ plánováno. Každá komponenta je popsaná
> samostatně, aby se portovala po jedné.

### 4.1 Barvy a celkový look (✅ hotovo)
- **Pozadí:** `#111826` (tmavě modrá). **Surface:** `#182545`. **Akcent:** `#82DCCC`
  (tyrkys), `#00AA84`, `#007D6F`. **Text:** `#DDDDDD`, dim `#798BB2`.
- Zdroj: `colors.lua` (CACHYLGREEN/CACHYMBLUE/...). V `theme.lua`.

Konfigurační paleta (`theme` tabulka v `theme.lua`, barvy `0xRRGGBB`):

| Proměnná | HEX kód | Odstín | Konkrétní použití v aplikaci |
|---|---|---|---|
| `accent_b` | `#00AA84` | Smaragdově tyrkysová | Hlavní akcent: Aktivní záložky, vybrané položky v nabídce, zvýrazněný text a primární tlačítka. |
| `accent_dark` | `#007D6F` | Tmavá tyrkysová | Sekundární akcent: Stav při najetí myší (hover), pozadí aktivního řádku nebo ohraničení prvků. |
| `inactive` | `#798BB2` | Tlumená šedomodrá | Neaktivní prvky: Neaktivní záložky oken, zakázaná tlačítka (disabled) a vedlejší texty na pozadí. |
| `red` | `#FF6B6B` | Korálově červená | Varování a chybové stavy: Soubory určené pouze pro čtení (read-only) ve správci souborů a chybové hlášky. |
| `exec` | `#6BCF6B` | Pastelově zelená | Spustitelné soubory: Označení spouštěcích skriptů a aplikací (např. `.wasm`) ve správci souborů. |
| `trash` | `#4A90D9` | Jasně modrá | Obsah koše: Všechny položky uvnitř `/.trash` ve správci souborů, bez ohledu na ostatní pravidla. |

### 4.2 Bar — horní panel (🔶 částečně)
Noctalia bar, 35 px, plné šířky. Zleva:
- **Launcher tlačítko** (štítek akcentu `>`) — ✅, klik otevře launcher.
- **Hodiny** `HH:MM` — ✅ (živě z `time.of_day_ms()`, CMOS RTC).
- **Workspace štítky 1–3** — ✅ (aktivní = akcent, klik přepne).
- **Active window štítek** — ✅ (uprostřed; fokusované okno).
- **Help F1** — ✅ (vpravo; klik otevře kontextový help jako F1).
- **Mediální widget** (přehrává se?) — ⏳ (žádné audio v kernelu; není).
- **Sysmon widget** (CPU/RAM v kapli) — ⏳ (není; RAM žije v okně sysmonu, viz §4.8).
- **Tray / Notifications** — ⏳ (placeholder ikona).
- **Network** — ⏳ (žádná síť; placeholder "Net —").
- **Volume** — ⏳ (žádné audio; placeholder byl odstraněn).
- **Session** — ⏳ (záměrně: UI power management neexistuje — always-live design, viz `spec/lua-wm.md` §1; restart/vypnutí je kernel-level akce, ne UI feature).

Pravá část baru nese jen `Help F1`; další widgety se přidávají od pravého okraje.
Jinak má bar správné rozložení.

> **Pojmenování:** workspace prvky v baru se v kódu jmenují `ws_capsules` (`wm.lua`) —
> pojmenovací konvence z Noctalia, ne popis tvaru; vizuálně jde o **obyčejné
> štítky** (bez zaoblení). Dokumentace používá neutrální „štítek".

### 4.3 Launcher (✅ hotovo)
- **Super+Space** otevře popup s vyhledávacím polem.
- Psaní filtruje aplikace, šipky mění výběr, Enter spustí.
- Položky: aplikace (repl, sysmon, files, editor) + akce (toggle fullscreen, close, **help**).

### 4.4 Okna a dekorace (✅ hotovo)
- Tiling: splith (60/40, fokus širší) / splitv, **gapless** (`gap_out = 0`, `gap_in = 0`
  v `theme.lua`) — okna se dotýkají, odděluje je jen border; border 2.
- Gapless je záměrná vizuální preference (okna k sobě, kompaktní dlaždicový vzhled),
  ne technické omezení — hodnoty jdou kdykoli změnit v `theme.lua`.
- Aktivní okno: **gradient border** (tyrkys→tmavě zelená).
- Neaktivní: šedý border, opacity 0.85.
- Float (Super+Alt+Space), drag hlavičkou, fullscreen (Super+F/D), scratchpad (Super+S).
- Myš na titulkové liště: **dvojklik = fullscreen** (všechna okna), pravý konec =
  **křížek** (zavřít, jen fokusované okno); jiná tlačítka se nekreslí (minimalismus).

### 4.5 Workspaces (✅ hotovo)
- 1–3, přepínání Super+1/2/3, klik v baru.
- Okna se přesouvají Super+Shift+šipky / +1/2/3.

### 4.6 Terminál / REPL (✅ hotovo)
- **Super+Enter** zobrazí a zaostří REPL okno (`~ repl` v titulku).
- Píšeš Lua kód, Enter spouští; `print()` píše na obrazovku.

### 4.6a Editor (✅ hotovo, M7.1)
- **Super+T** (i položka `editor` v launcheru) otevře **prázdný buffer**;
  čistý buffer se dalším Super+T resetuje, dirty se zachová (`ed_*` stav v `input.lua`).
- Textový editor: šipky, Home/End, Enter, Backspace/Delete, **Ctrl+S** uloží
  (`file.write`); nový buffer nabídne **save as:** v titulkové liště a soubor
  vytvoří (`file.create`). **Esc Esc** zavře editor jen u čistého bufferu.
- **Super+Z** otevře settings (`/wm/theme.lua`); uložení configu spouští auto-reload.
- Myš: kolečko scrolluje viewport, klik umístí kurzor; detail v `spec/editor.md`.

### 4.6b Files — správce souborů (✅ hotovo, M7.1)
- **Super+E** otevře files okno v kořenu (`files_*` stav v `input.lua`).
- Up/Down výběr, **Enter** otevře (adresář → dovnitř, soubor → **editace v editoru**),
  **Space** = náhled (read-only), **Delete** = přesun do koše `/.trash` (uvnitř koše
  trvalé smazání; `Ctrl+Delete` koš vyprázdní — M7.1.13), **Escape** o úroveň výš /
  ven z náhledu; položka **`..`** (zobrazuje se `/..`, DOS konvence) jde nahoru —
  hlavička je čistě okenní (dvojklik = fullscreen), aby dvojklik nekolidoval s `cd ..`.
- Detail viz `spec/lua-wm.md` §7a.4.

### 4.7 Aplikace (🔶 základ)
- **sysmon** (RAM used/total, %, ticks) — ✅ základ, ⏳ CPU graf.
- **files** — ✅ hotovo (M7.1: listing, koš, rename, hidden toggle; viz §4.6b).
- **calculator** — ✅ hotovo (M7 Fáze B, ADR-026/027): wasm sandboxovaná aplikace s
  vlastní offscreen surface, ne Lua/REPL evaluace. Floating okno fixní velikosti,
  spouští se z `/apps/calculator.wasm` na disku (launcher ji skenuje dynamicky).
- Model: každá aplikace = okno + `render` funkce, spouštěná z launcheru.

### 4.8 Sysmon — systémový monitor (🔶)
Cíl: btop/Noctalia sysmon widget v baru + okno.
- **RAM** — ✅ (`sysmon.ram_total_mb/free_mb`).
- **CPU** — ⏳ (potřeba CPU usage z kernelu; idle měření, M7 scheduler).
- **Procesy** — ⏳ (M7).
- Konfigurace widgetu: štítky v baru (temp, cpu, ram) dle `config.toml` sysmon widgetů.

### 4.9 Greeter / login screen (⏳ odloženo)
- Noctalia greeter je samostatný přihlašovací screen. Portovat až po M8 stabilizaci.
- Prozatím boot → rovnou desktop.

### 4.10 Splash a chování (🔶)
- **Splash:** zelený (`CACHYLGREEN`) text na bootu — ✅ možnost.
- **Middle-click paste:** ne (žádný clipboard; `misc.lua` má false).
- **Swallow** (terminál pohltí spuštěné okno): ⏳ (koncept pro REPL/launcher).

---

## 5. Zkratky (Hyprland standard + vědomé odchylky — ✅ hotovo)

> **Konvence ovládání = Hyprland jako základ.** Aster WM vychází z **Hyprland
> konvencí pro klávesové zkratky, tlačítka a navigaci**: pokud znáš Hyprland,
> víš, jak se v Asteru ovládá okenní manažer. Zkratky jsou **data** (`input.lua`),
> ne rozházený kód — přidávají se na jedno místo a fungují stejně. Žádné
> MC/Total Commander konvence (F3/F4) jako náhrada — soubory se otevírají
> Enterem (jako dvojklik v Hyprland file manageru), prohlížejí Spacem a mažou
> Delete.
>
> **Vědomé odchylky od striktního Hyprlandu** (zdokumentované, ne tiché):
>
> - **Esc Esc zavře editor / vystoupí z náhledu** (jen u čistého bufferu,
>   neuložené změny blokují). Hyprland nemá žádnou „dvojitý Esc" konvenci —
>   ESC je tam jednorázový výstup z klávesového režimu (submap) a okna se
>   zavírají jen dispatcherem (Super+Q). Dvojitý stisk je zde **pojistka proti
>   nechtěnému zavření** (v duchu vim/terminálů) a je to konvence Asteru, ne
>   Hyprlandu. Více viz `spec/lua-wm.md` §7.1 (Esc Esc).

| Kombinace | Akce |
|---|---|
| Super+Enter | terminál (REPL) |
| Super+T | editor (prázdný buffer) |
| Super+Z | settings (`/wm/theme.lua`) |
| Super+E | file manager |
| Super+Q | zavřít fokusované okno |
| Super+Space | launcher |
| Super+Alt+Space | float toggle |
| Super+F / D | fullscreen |
| Super+J | togglesplit |
| Super+šipky | focus směr |
| Super+Shift+šipky / +1/2/3 | přesun okna |
| Super+1/2/3 | workspace |
| Super+S | scratchpad (toggle vyhrazené app) |
| Alt+Tab | cyklování oken |
| F1 / Super+F1 | help — F1 kontextové (v okně) / Super+F1 globální WM help |
| F2 | editor: save as / files: rename |
| F3 | files: view vybraný soubor |
| F4 | files: edit vybraný soubor / Shift+F4: nový soubor |
| F5 | hot reload |
| F11 | fullscreen (jako Super+F/D) |
| F6–F10, F12 | **rezervované** (neobsazovat bez přehodnocení) |

> **F-klávesy = designová dualita** s Hyprland zkratkami (ne konfliktní duplicity):
> F1/F2/F3/F4/F5/F11 dělají totéž co odpovídající Super+... / Ctrl+S zkratka,
> ale druhou, zažitou cestou — uživatel si zvolí, kterou zná. **F6–F10 a F12
> jsou rezervované** (Hyprland reserved slots): od teď platí, že se nesmí
> přiřadit jiné akci bez přehodnocení, ať se při vývoji nepoužijí omylem na
> něco jiného.

> **Detailní popis chování každé zkratky** — co se přesně stane (vedlejší efekty,
> stav okna, workspace, z-order, jak se chová opakovaný stisk, jak okno interaguje
> se zkratkou) je v `spec/lua-wm.md` §7.1. Tahle tabulka je jen rychlý seznam;
> chování je popsáno tam.

---

## 6. Co portovat nejde (technické limity)

- **Blur, stíny, GPU animace** — potřebují compositor se shaderem; kernel framebuffer
  má jen přímý zápis. Animace → jen "fade" přes interpolaci barev v renderu (bez GPU).
- **GTK/Qt aplikace** (dolphin, kitty, gnome-*) — Linux binárky; nahrazujeme vlastními
  Lua okny.
- **Wayland IPC, dbus, systemd, uwsm** — operační systém, ne vzhled.
- **Síť, audio, tray** — kernel nemá ovladače; widgety zůstanou placeholdery do M6+.
- **Cursor Bibata** — binární kurzory; převezmeme vzhled (moderní šipka) v
  `mouse_cursor.zig`, ne formát.

---

## 7. Prioritizace (co portovat dál)

1. **Bar: reálné hodiny** — ✅ hotovo (M5 close: hodiny žijí z `time.of_day_ms()`, CMOS RTC).
2. **Sysmon CPU widget** (potřebuje kernel binding, medium effort).
3. **Fade animace přepínání workspace** (bez GPU, medium effort).
4. **Files aplikace** — ✅ hotovo (M7.1).
5. **Greeter** (až M8).

---

## 8. Ověření (DoD desktopu)

- Každá komponenta má viditelný stav v `ui/` + zkratku/myš pro interakci.
- Screendump po bootu ukáže bar, okna, launcher (verifikační nástroj existuje).
- Render bez regrese: render throughput + first-frame latency v `roadmap.md`.
- Změna vzhledu přes `theme` bez recompilu (F5).
