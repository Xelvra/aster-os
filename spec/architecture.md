# Aster OS — Architektonický přehled

**Verze:** 1.3 (konsolidace)
**Status:** Current design — Schváleno k implementaci (M0–M6 hotovo; M7 Fáze A+B hotové,
Fáze C — benchmark wasm vs Lua — zbývá jako dluh; M8 Stabilizace — oddělení do Ring 3)

> Tento dokument je **hlavním architektonickým přehledem** projektu. Zachycuje aktuální
> návrh a jeho rozhodnutí. Slouží jako referenční bod pro konzultaci návrhu architektury a
> jako výchozí bod pro psaní kódu.
>
> Jednotlivá rozhodnutí žijí jako samostatné záznamy v `spec/adr/`. Podrobné dílčí
> specifikace v `spec/*.md` (viz index níže). Tento dokument je **přehledový**: čte se
> celý, dílčí dokumenty až na vyžádání.
>
> **Dvě roviny:** §3 popisuje **Current architecture** (co je implementované v M0–M7,
> `src/`). §4 popisuje **Target architecture** (M8+: oddělení do Ring 3). Dokument
> neprezentuje target jako hotový — kde se Current a Target liší, je to výslovně řečeno.

---

## 1. Shrnutí

Aster OS je experimentální desktopový operační systém napsaný v Zigu. První implementace
záměrně upřednostňuje **jednoduchost před izolací**: desktop, skriptovací engine i runtime
sdílejí jediný adresní prostor, aby se minimalizovala složitost a maximalizovala rychlost
iterace. Veřejná rozhraní jsou navržena jako **stabilní abstrakce**, takže jednotlivé
subsystémy bude možné později přestěhovat do izolovaných procesů **bez změny aplikačních API**.

Architektura je **evoluční SASOS** (Single Address Space, Ring 0): vše běží v jednom
adresním prostoru, ale přes stabilní rozhraní, která umožní pozdější oddělení do Ring 3.

**Cílová platforma:** v současnosti **x86_64** (QEMU `q35`) — jediná implementovaná
architektura. Budoucí port (např. ARM, RISC-V) není návrhem vyloučen, ale dnes není cílem
a vyžádal by si vlastní změnu rozsahu (`spec/non-goals.md`).

**Hlavní cíle (KPI):**

| Metrika | Cíl |
|---|---|
| Velikost kernel image | < 512 KB (s Lua; viz `roadmap.md` §2) — původní cíl; per-milník se rozvolňuje (M7 cíl < 1 MB, wasm3 přibyl), viz `roadmap.md` tabulka metrik |
| Kernel Entry → First Frame (z Limine handoff) | < 40 ms (cíl M4/M5; v QEMU TCG měřeno ≈ 90 ms — viz `roadmap.md` pozn. ³) |
| GUI paměť (idle) | < 32 MB RAM |
| UI kreslení | 0 syscallů, 1 kopie framebufferu za frame *(Phase 2 present, `main.zig`; kurzor myši navíc ukládá/obnovuje 12×19 px. Platí pro fázi Ring 0; od Ring 3 — M8+ — se přidávají ring přechody, viz `roadmap.md`)* |
| Kompilace | reprodukovatelná (viz `spec/verification.md`) |

> Konkrétní hodnoty per milník jsou v `spec/roadmap.md` jako rozsahy a cíle, ne falešně
> přesná čísla — přesná čísla nikdo nezná dřív, než systém běží.

---

## 2. Filozofie a Manifest

### 2.1 Manifest (aktuální znění)

> **Aster OS je experimentální desktopový operační systém napsaný v Zigu.**
>
> První implementace záměrně upřednostňuje jednoduchost před izolací: desktop, skriptovací
> engine i runtime sdílejí jediný adresní prostor, aby se minimalizovala složitost a
> maximalizovala rychlost iterace. Veřejná rozhraní jsou navržena jako stabilní abstrakce,
> takže jednotlivé subsystémy lze později přestěhovat do izolovaných procesů **bez změny
> aplikačních API**.

Manifest zachycuje aktuální důvod existence projektu a aktuální kompromisy. Všechna
rozhodnutí popsaná v tomto dokumentu a v `spec/adr/` musí být interpretovatelná jako
důsledek manifestu.

---

## 3. Architektonický přehled

### 3.0 Vizuální přehled: boot → app

```text
┌──────────────────┐
│    BIOS / UEFI   │
│       BOOT       │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│      LIMINE      │
│    BOOTLOADER    │
└────────┬─────────┘
         │
         ▼
╔════════════════════════════╗
║         ZIG KERNEL         ║
║           RING 0           ║
║                            ║
║       # M0–M7              ║
║                            ║
║  CPU / MEMORY / IRQ        ║
║  STORAGE (M6/M7)           ║
║  DRIVERS / SCHEDULER (M7)  ║
║  / IPC (M8+) / CORE SRVS   ║
╚═══════════╤════════════════╝
            │
            ▼
┌──────────────────┐
│    KI (API/*)    │
│       # M2       │
└─────────┬────────┘
          │
  ┌───────┼───────┐
  │               │
  ▼               ▼
┌──────────────┐  ┌──────────────────────┐
│ LUA RUNTIME  │  │     WASM RUNTIME     │
│     # M4     │  │       # M7           │
└──────┬───────┘  │                      │
       │ ▲        │ ┌──────────────────┐ │
       │ └──────┐ │ │    ASTER APPS    │ │
       ▼        │ │ │      # M7        │ │
┌────────────┐  │ │ └──────────────────┘ │
│  SHELL/UI  │──┘ │                      │
│    # M5    │    │ ┌──────────────────┐ │
└────────────┘    │ │       WASI       │ │
                  │ │   FOREIGN APPS   │ │
                  │ │      # M9        │ │
                  │ └──────────────────┘ │
                  └──────────────────────┘
```

### 3.1 Current architecture (M0–M7, implementováno)

> **WM architektura:** desktop shell je „WM jako Lua kód" — architektonický vzor
> **AwesomeWM** (kernel = primitiva, Lua = WM logika; od 2007 ověřený na X11).
> Hyprland (cachyos-hypr-noctalia) je jen zdroj vizuálního designu a klávesových
> konvencí, ne architektury. Rozhodnutí a co z AwesomeWM přejímáme: `lua-wm.md` §14 (D11),
> licence/původ: `THIRD-PARTY-NOTICES.md` §5a.

```text
Lua shell (desktop, vendored Lua 5.4)      Wasm programy (wasm3, M7)
   │                                            │
   │  KI bindings → sys.dispatch()              │
   ▼                                            ▼
KERNEL ROZHRANÍ (KI) — api/* (dispatch vrstva)   (api/runtime.spawn)
   │
   ├── graphics API ──→ renderer ──→ framebuffer (GOP/Limine)
   ├── input API ─────→ input/service ──→ fronta ← PS/2 IRQ, APIC timer
   ├── runtime API ───→ lua / wasm (per-program státy)
   ├── timer API ─────→ time.zig (monotónní tick)
   ├── sysmon API ────→ mem.Memory.stats()
   ├── debug API ─────→ serial (privilegovaný diagnostický sink)
   └── power API ─────→ i8042 reset

kernel/main.zig = jediný privileged composition root
   │  (sestavuje mem, cpu/idt+apic+smp, sched, drivery, fs, renderer, cursor,
   │   runtime, lua, wasm)
   ▼
subsystémy: mem (pfa, heap, page_map), cpu (idt, apic, acpi, smp), sched (task,
            sync), drivers (ps2, virtio-blk, block, pci, pic, irq), fs (gpt, ext2,
            file, tar), render (renderer, font, mouse_cursor), input (service,
            layout, queue), wasm (hostitel), apps (hello, fault), time/rtc,
            bootlog, libc, serial
```

**Kurzor myši je privilegovaný graphics overlay**, ne součást Rendereru ani Input
subsystemu: `render/mouse_cursor.zig` ukládá/obnovuje pixely a kreslí sprite přímo do
framebufferu (12×19 px). Event loop aplikuje mouse events na overlay a píše výsledný
stav do `input/service`; service o framebufferu neví. Framebuffer je interní zdroj
graphics subsystemu — běžné kreslení jde výhradně přes Renderer, privilegovaný overlay
přes `mouse_cursor` (viz `spec/graphics.md` §7).

**Storage (M6/M7):** `virtio-blk → Block Device API → GPT → ext2 → File API` (read-write
od M7.1). File API je **ext2-specific adapter** (ADR-023 — backend abstraction až
s druhým backendem).

### 3.2 Runtime (M7, implementováno)

```text
Shell / UI (Lua)    Aplikace (Wasm — wasm3, M7)
   │                 │
   └───── KI ────────┘  (aplikace psané pro Aster volají Aster bindings)
   ▼
Runtime (generický): per-program lua_State / Wasm instance → scheduler (ADR-017)
   ▼
Program lifecycle: spawn / status (M7)
```

- **M7:** Runtime není "jeden vestavěný Lua program" — `spawn()` vytváří per-program
  státy, scheduler preemptuje, `Program` je schedulable execution context. Wasm3 je
  vendored a hostován za generickým Runtime API (ADR-011): konkrétní runtime jméno
  zná jen `api/runtime` (composition-root výjimka, ADR-006); zbytek kernelu jde vždy
  přes `Runtime.spawn`.

### 3.3 Target architecture (M8+, oddělení do Ring 3)

Výše popsané rozhraní zůstává; mění se obsah vrstev:

- **M8+ (oddělení):** subsystémy se stěhují za stabilní KI do Ring 3 (ADR-018); KI
  volání se z přímých stávají IPC — **bez změny volajícího kódu**. Přibudou memory
  protection, syscalls a MMU (žádné MMU v M0–M7).

### 3.4 Čtyři pilíře

1. **Evoluční SASOS** — jeden adresní prostor, Ring 0, žádné MMU/syscall/IPC režie.
   Lua, Wasm, UI = obyčejná volání funkcí.
2. **Stabilní švy od prvního dne (KI)** — rozhraní nevědí, že je všechno v Ring 0.
   Zítra se z přímých volání stanou IPC zprávy **bez změny volajícího kódu**.
3. **Žádná předčasná optimalizace** — nejjednodušší řešení, které funguje. Měří se
   po každém milníku (viz `spec/roadmap.md`).
4. **Bootovatelný commit** — každý commit musí zanechat systém spustitelný v QEMU.
   Žádné "na další tři commity to bude rozbité".

---

## 4. Rozhodovací protokol (ADR)

Každé rozhodnutí má číslo, verdikt, odůvodnění a důsledky. Plné znění každého ADR je
samostatný soubor v [`spec/adr/`](adr/README.md) — **kanonický index a plné znění je
`spec/adr/README.md`**, zde je jen odkaz, ne duplicitní tabulka. Zapisováno proto,
aby pozdější konsultace návrhu měla k dispozici *proč*, ne jen *co*.

**Pravidla ADR:** rozhodnutí se nemění dodatečně — změna názoru = nový ADR odkazující na
starý. Čísla se nepřehazují a nemazají. Stavy: `Proposed` / `Accepted` / `Superseded by ADR-0YY`.

---

## 5. Známá rizika

Přiznaná dopředu, aby nebyla později "objevem". Rizika se řídí, ne ignorují:

| Riziko | Popis | Zmírnění |
|---|---|---|
| **Single address space** | Bug v nativním Zig kódu může zkorumpovat cokoli (kernel, framebuffer, ostatní moduly). | Lua/Wasm běží v **sandboxu** (managed runtime — bezpečně oddělené izolované prostředí pro neověřený kód); nativní kód prochází invarianty (`spec/invariants.md`) a review. |
| **Embedded Lua v jádře** | Lua VM běží s plným oprávněním; bug VM nebo bindingů = pád systému. | Vendored stabilní verze, minimální binding plocha, host testy marshallingu. |
| **Žádná MMU izolace** | Není hardwarová hranice mezi komponentami. | Jazyková izolace: Lua/Wasm v sandboxu (managed runtime); ADR-002; non-goal do budoucna. |
| **Žádné userspace ovladače** | Ovladače (PS/2, timer) běží v jádře; jejich bug = pád. | Malý, kontrolovaný kód; QEMU smoke test jako záchyt. |
| **SMP dluh** | SMP bring-up je hotový, ale **scheduler je BSP-only** — APy idlují a neběží kernel práci; paralelní výkon se nevyužije. | Vědomý stav (`spec/non-goals.md`); AP práci na kernel taskách řešit, až to metriky vyžadují (ADR-015). |
| **Dokumentace těžší než kód** | Přerostení plánování do nekonečna. | Tento dokument je přehledový; detaily až na vyžádání; každé měřitelné rozhodnutí se ověřuje v kódu. |

---

## 6. Terminologie

| Termín | Význam |
|---|---|
| **SASOS** | Single Address Space Operating System — jeden adresní prostor, vše Ring 0. **Radikálnější varianta klasických SASOS** (Opal, Nemesis aj.): akademické systémy měly hardwarovou ochranu mezi doménami, Aster žádnou — ochrana je čistě jazyková (Lua/Wasm managed) a sdílený stav se chrání zakázáním preempce (ADR-017). |
| **KI** | Kernel Interface — stabilní rozhraní mezi jádrem a zbytkem systému. Budoucí základ ABI. |
| **Renderer** | Vrstva mezi Graphics API a Framebufferem; dnes `fillRect`/`blit`/`glyph` + rozšířená primitiva (roundRect, rectBorder, gradientBorder, ADR-021), zítra GPU/IPC. |
| **Runtime** | Vrstva odpovědná za spouštění programů (`Runtime.spawn`), abstrahuje Lua/Wasm/Native. |
| **Program** | Výsledek `spawn()` — handle na běžící modul. |
| **Surface** | Technický termín pro **kreslicí target** programu (např. vlastní okno wasm programu); nezaměňovat s barvou `surface` v `theme.lua`. |
| **Event loop** | Hlavní smyčka `poll() → update() → render()`. |
| **Embedded asset** | Zdroj (lua skript, font) distribuovaný v initrd taru (Limine module). |

---

## 7. Repozitářová struktura

```
aster-os/
├── build.zig                      # `zig build run` → QEMU, `zig build test` → host testy
├── .zig-version                   # exaktní verze toolchainu (0.16.0)
├── .version                       # verze projektu (ČÍTANÁ release workflowem, ne ručně)
├── .gitattributes                 # linguist-vendored / linguist-documentation (language stats)
├── README.md                      # manifest + odkaz na .zig-version
├── CHANGELOG.md                   # agregovaný changelog (anglicky, jedna verze na milník)
├── CONTRIBUTING.md                # jak přispívat (build, workflow, pravidla)
├── SECURITY.md                    # bezpečnostní politika
├── CODE_OF_CONDUCT.md             # kodex chování
├── THIRD-PARTY-NOTICES.md         # vendored závislosti (Lua 5.4.8, wasm3 v0.5.0, Limine)
├── boot-log.md                    # generovaný, CI-vynucený záznam bootu (capture-boot.sh)
├── limine.conf                    # konfigurace Limine bootloaderu
├── docs/                          # anglická webová vrstva (entry point, index.md)
├── hooks/                         # git hooky (pre-push: capture-boot + sync-docs)
├── .github/                       # CI workflow (ci.yml, release.yml)
├── spec/                         # TENTO SOUBOR + dílčí specifikace
│   ├── README.md
│   ├── architecture.md           # tento dokument
│   ├── manifest.md
│   ├── non-goals.md              # co systém vědomě nedělá
│   ├── code-style.md             # filozofie a pravidla kódu
│   ├── adr/                      # architektonická rozhodnutí (ADR-001..027)
│   ├── kernel-interface.md       # KI: sys.dispatch + interface moduly
│   ├── graphics.md               # Graphics API → Renderer → Framebuffer
│   ├── desktop-ui.md            # desktop UI port (bar, launcher, okna, widgety)
│   ├── lua-wm.md                 # Lua WM blueprint (moduly, tiling, grafika, bindings)
│   ├── editor.md                 # editor okno (klávesové/myšové konvence, plánovaný zoom)
│   ├── input.md                  # vstupní události
│   ├── runtime.md                # Runtime.spawn + RuntimeKind
│   ├── timer.md                  # čas: tick zdroj (M2), KI timer, kooperativní sleep
│   ├── memory.md                 # paměť: PFA, heap alokátor, lua_Alloc
│   ├── scheduler.md              # scheduler + SMP: preemptivní RR, task model, SMP BSP-only
│   ├── storage.md                # storage: KI file API → ext2 → gpt → block device
│   ├── invariants.md             # Safety / Performance / Architecture
│   ├── roadmap.md                # M0–M10 + kvalitní metriky
│   ├── verification.md           # verifikační pipeline + deterministický build
│   ├── debugging.md              # Debugging Survival Guide (GDB, serial dump)
│   ├── troubleshooting.md        # vyřešené pasti a lekce (C1..C54, B1..B4, H1..H6)
│   ├── 2026-08-15-self-audit.md       # kompletní repo audit
│   ├── 2026-08-16-re-audit.md        # navazující re-audit (opravené nálezy)
│   ├── handoff.md                # postup pro nevyřešené problémy
│   └── handoffs/                 # handoff dokumenty H1–H6 (viz handoff.md §6)
├── src/
│   ├── kernel/                   # boot/ (boot, limine, boot_info), cpu/ (idt, apic,
│   │   │                         # acpi, smp, pic, irq, io), mem/ (pfa, heap, page_map,
│   │   │                         # mem, cache_attr), drivers/ (ps2, virtio-blk, block,
│   │   │                         # pci), fb/ (framebuffer), render/ (renderer, font,
│   │   │                         # mouse_cursor), input/ (service, layout, queue),
│   │   │                         # fs/ (gpt, ext2, file, tar), sched/ (task, sync),
│   │   │                         # wasm/ (hostitel), apps/ (hello, fault, calculator),
│   │   │                         # lua/ (Lua 5.4 binding + ui/ shell moduly),
│   │   │                         # api/ (KI dispatch — vč. sys.zig, storage.zig),
│   │   │                         # + time.zig, rtc.zig, bootlog.zig, libc.zig, serial.zig
│   └── kernel/lua/ui/            # desktop shell v Lua: theme, wm, repl, editor,
│                                 # files, launcher, input, main (concatenované)
├── libs/
│   ├── limine/                   # vendored bootloader + hlavičky
│   ├── lua-5.4/                  # vendored Lua 5.4 zdroj
│   └── wasm3/                    # vendored wasm3 interpreter (M7)
├── tests/                        # host unit testy (pfa, heap, graphics, input, fs,
│                                 # cpu, queue, libc) + tests/lua/ shell regrese
├── tools/
│   ├── qemu-smoke.sh             # serial marker + timeout
│   ├── qemu-test.sh              # in-QEMU runtime testy (isa-debug-exit 99)
│   ├── qemu-accel.sh             # KVM/TCG akcelerace pro QEMU běhy
│   ├── capture-boot.sh           # regenerace boot-log.md
│   ├── sync-docs.sh              # EN web vs spec timestamp brána
│   ├── make-test-disk.sh         # deterministický ext2 test disk
│   ├── lua-shell-test.sh         # host běh tests/lua shell regresí
│   ├── verify-reproducible.sh    # deterministický build check (ADR-014)
│   ├── generate-changelog.sh     # generátor CHANGELOG.md
│   ├── install-hooks.sh          # pre-push hooky
│   └── bench.sh                  # měření metrik
└── zig-out/                      # výstup: aster.iso, boot/ (fixní cesta)
```

---

## 8. Index specifikací

Kanonický index specifikací a jejich obsah je [`spec/README.md`](README.md). Zde není
duplicitní tabulka — každý duplicitně udržovaný index reálně driftuje (ADR přehled v §4
odstraněn 2026-08-19 z téhož důvodu).
