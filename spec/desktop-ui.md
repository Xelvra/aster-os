# Desktop — UI port z cachyos-hypr-noctalia

**Status:** V1 (draft). **Cíl:** atomický popis desktopu — co přesně vidí uživatel,
komponenta po komponentě. Zdrojem je [`cachyos-hypr-noctalia`](https://github.com/CachyOS/cachyos-hypr-noctalia)
(config/dotfiles pro Hyprland + Noctalia shell); portujeme **vzhled a chování**, ne
software (Hyprland/Wayland/GTK/Qt v našem kernelu neběží).

> **Transparentnost / licence:** upstream repo **nemá licenční soubor** (výchozí stav
> „all rights reserved") — Aster proto **neobsahuje a nevendoruje žádný jeho soubor**.
> Port znamená reimplementaci vizuálního konceptu a Hyprland konvencí vlastním kódem
> (barvy jako data, klávesové zkratky jako data); poděkování viz
> `THIRD-PARTY-NOTICES.md` (sekce „Thematic inspiration").

---

## 1. Vize

Aster má být použitelný desktop, ne jen okenní manager. Rozdíl:

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
| **Dekorace oken** (border, rounding, gaps, opacity) | `hypr/config/decorations.lua` | ✅ ano | `ui/wm.lua` (theme.wm) |
| **Zkratky** (Super+...) | `hypr/config/binds.lua` | ✅ ano | `ui/input.lua` (hotovo) |
| **Workspaces 1–3** | `hypr/config/workspaces.lua` | ✅ ano | `ui/wm.lua` (hotovo) |
| **Taskbar/bar** (launcher, clock, kaple, media, tray, network, volume, session) | `noctalia/config.toml` | ✅ vzhled ano | `ui/wm.lua` bar_render |
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

UI běží v Luay (`src/kernel/lua/ui/`), kernel poskytuje jen primitiva a vstup.

```
src/kernel/lua/ui/
├── theme.lua     # barvy + geometrie (port Cachy palety)
├── wm.lua        # okna, layout, bar, dekorace
├── repl.lua      # terminál/REPL jako okno
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

### 4.2 Bar — horní panel (🔶 částečně)
Noctalia bar, 35 px, plné šířky. Zleva:
- **Launcher tlačítko** (akcentová kaple `>`) — ✅, klik otevře launcher.
- **Hodiny** `HH:MM` — ✅ (živě z `time.ticks()`).
- **Workspace kaple 1–3** — ✅ (aktivní = akcent, klik přepne).
- **Mediální widget** (přehrává se?) — ⏳ (žádné audio v kernelu; placeholder "—").
- **Sysmon widget** (CPU/RAM v kapli) — 🔶 (RAM ano; CPU ⏳, viz §4.8).
- **Tray / Notifications** — ⏳ (placeholder ikona).
- **Network** — ⏳ (žádná síť; placeholder "Net —").
- **Volume** — ⏳ (žádné audio; placeholder "Vol —").
- **Session** (lock/logout/reboot) — ✅ (menu: Lock = overlay, jakákoli klávesa odemkne — bez auth; Logout = reload shellu; Reboot = i8042 reset). Model restartů viz `spec/runtime.md` §5 (F5/Logout = UI vrstva, Reboot = celý stroj).

Pravá část baru je dnes placeholder, ale **má správné rozložení** (widgety zprava).

### 4.3 Launcher (✅ hotovo)
- **Super+Space** otevře popup s vyhledávacím polem.
- Psaní filtruje aplikace, šipky mění výběr, Enter spustí.
- Položky: repl (terminál), sysmon, files, toggle fullscreen, close.

### 4.4 Okna a dekorace (✅ hotovo)
- Tiling: splith (60/40, fokus širší) / splitv, gaps out 8 / in 3, border 2.
- Aktivní okno: **gradient border** (tyrkys→tmavě zelená), rounding 10.
- Neaktivní: šedý border, opacity 0.85.
- Float (Super+Alt+Space), drag hlavičkou, fullscreen (Super+F/D), scratchpad (Super+S).

### 4.5 Workspaces (✅ hotovo)
- 1–3, přepínání Super+1/2/3, klik v baru.
- Okna se přesouvají Super+Shift+šipky / +1/2/3.

### 4.6 Terminál / REPL (✅ hotovo)
- **Super+Enter** zobrazí a zaostří REPL okno (`~ repl` v titulku).
- Píšeš Lua kód, Enter spouští; `print()` píše na obrazovku.

### 4.7 Aplikace (🔶 základ)
- **sysmon** (RAM used/total, %, ticks) — ✅ základ, ⏳ CPU graf.
- **files** — ⏳ placeholder (žádný FS; od M6 initfs).
- **calculator** — ⏳ (Lua `math` evaluace přes REPL).
- Model: každá aplikace = okno + `render` funkce, spouštěná z launcheru.

### 4.8 Sysmon — systémový monitor (🔶)
Cíl: btop/Noctalia sysmon widget v baru + okno.
- **RAM** — ✅ (`sysmon.ram_total_mb/free_mb`).
- **CPU** — ⏳ (potřeba CPU usage z kernelu; idle měření, M7 scheduler).
- **Procesy** — ⏳ (M7).
- Konfigurace widgetu: kaple v baru (temp, cpu, ram) dle `config.toml` sysmon widgetů.

### 4.9 Greeter / login screen (⏳ odloženo)
- Noctalia greeter je samostatný přihlašovací screen. Portovat až po M8 stabilizaci.
- Prozatím boot → rovnou desktop.

### 4.10 Splash a chování (🔶)
- **Splash:** zelený (`CACHYLGREEN`) text na bootu — ✅ možnost.
- **Middle-click paste:** ne (žádný clipboard; `misc.lua` má false).
- **Swallow** (terminál pohltí spuštěné okno): ⏳ (koncept pro REPL/launcher).

---

## 5. Zkratky (Hyprland standard — ✅ hotovo)

| Kombinace | Akce |
|---|---|
| Super+Enter | terminál (REPL) |
| Super+Q | zavřít fokusované okno |
| Super+Space | launcher |
| Super+Alt+Space | float toggle |
| Super+F / D | fullscreen |
| Super+J | togglesplit |
| Super+šipky | focus směr |
| Super+Shift+šipky / +1/2/3 | přesun okna |
| Super+1/2/3 | workspace |
| Super+S | scratchpad |
| Alt+Tab | cyklování oken |
| F5 | hot reload |

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

1. **Bar: reálné hodiny + session menu** — ✅ hotovo (M5 close: hodiny žijí z ticků, menu Lock/Logout/Reboot).
2. **Sysmon CPU widget** (potřebuje kernel binding, medium effort).
3. **Fade animace přepínání workspace** (bez GPU, medium effort).
4. **Files aplikace** (po M6 initfs).
5. **Greeter** (až M8).

---

## 8. Ověření (DoD desktopu)

- Každá komponenta má viditelný stav v `ui/` + zkratku/myš pro interakci.
- Screendump po bootu ukáže bar, okna, launcher (verifikační nástroj existuje).
- Render bez regrese: render throughput + first-frame latency v `roadmap.md`.
- Změna vzhledu přes `theme` bez recompilu (F5).
