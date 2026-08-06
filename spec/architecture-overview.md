# Aster OS — Architektonický přehled

**Verze:** 1.0 (draft)
**Status:** Current design — Schváleno k implementaci (Milníky M0–M4)

> Tento dokument je **hlavním architektonickým přehledem** projektu. Zachycuje aktuální
> návrh a jeho rozhodnutí. Slouží jako referenční bod pro konzultaci návrhu architektury a
> jako výchozí bod pro psaní kódu.
>
> Jednotlivá rozhodnutí žijí jako samostatné záznamy v `spec/adr/`. Podrobné dílčí
> specifikace v `spec/*.md` (viz index níže). Tento dokument je **přehledový**: čte se
> celý, dílčí dokumenty až na vyžádání.

---

## 1. Shrnutí

Aster je experimentální desktopový operační systém napsaný v Zigu. První implementace
záměrně upřednostňuje **jednoduchost před izolací**: desktop, skriptovací engine i runtime
sdílejí jediný adresní prostor, aby se minimalizovala složitost a maximalizovala rychlost
iterace. Veřejná rozhraní jsou navržena jako **stabilní abstrakce**, takže jednotlivé
subsystémy bude možné později přestěhovat do izolovaných procesů **bez změny aplikačních API**.

Architektura je **evoluční SASOS** (Single Address Space, Ring 0): vše běží v jednom
adresním prostoru, ale přes stabilní rozhraní, která umožní pozdější oddělení do Ring 3.

**Hlavní cíle (KPI):**

| Metrika | Cíl |
|---|---|
| Velikost kernel image | < 256 KB (bez Lua) |
| Kernel Entry → First Frame (z Limine handoff) | < 50 ms |
| GUI paměť (idle) | < 32 MB RAM |
| UI kreslení | 0 syscallů, 0 kopií framebufferu *(platí pro fázi Ring 0; od Ring 3 — M8+ — se přidávají ring přechody, viz `roadmap.md`)* |
| Kompilace | reprodukovatelná (viz `spec/verification.md`) |

> Konkrétní hodnoty per milník jsou v `spec/roadmap.md` jako rozsahy a cíle, ne falešně
> přesná čísla — přesná čísla nikdo nezná dřív, než systém běží.

---

## 2. Filozofie a Manifest

### 2.1 Manifest (aktuální znění)

> **Aster je experimentální desktopový operační systém napsaný v Zigu.**
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

### 3.1 Vrstvy

```
┌────────────────────────────────────────────────────────────┐
│  APPLIKACE (userspace-in-process)                          │
│  ┌──────────────────────┐    ┌──────────────────────────┐  │
│  │  Shell / UI (Lua)    │    │  Aplikace (Wasm, nativ) │  │
│  └──────────┬───────────┘    └────────────┬─────────────┘  │
│             │   Runtime API               │                │
│             └──────────────┬──────────────┘                │
├────────────────────────────┼───────────────────────────────┤
│  KERNEL ROZHRANÍ (KI)      ▼                               │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Graphics API │ Input API │ Runtime API │ Sys.Dispatch│  │
│  └──────────┬───────────┬───────────┬──────────┬─────────┘  │
│             ▼           ▼           ▼          ▼           │
│  ┌─────────────┐ ┌────────────┐ ┌────────────┐ ┌─────────┐ │
│  │  Renderer   │ │  Event loop│ │  Runtime   │ │  Sys    │ │
│  └──────┬──────┘ └─────┬──────┘ └─────┬──────┘ └────┬────┘ │
│         ▼              ▼              ▼             ▼      │
│  Framebuffer       Input (PS/2)   Lua / Wasm VM   Core    │
│  ┌─────────────┐   ┌────────────┐  ┌────────────┐ ┌───────┐│
│  │  GOP / FB   │   │  Keyboard  │  │  Lua 5.4   │ │ Mem,  ││
│  │  (Limine)   │   │  IRQ       │  │  (vendored)│ │ CPU,  ││
│  └─────────────┘   └────────────┘  └────────────┘ │ Timer ││
│                                                    └───────┘│
└────────────────────────────────────────────────────────────┘
```

### 3.2 Čtyři pilíře

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
samostatný soubor v [`spec/adr/`](adr/README.md) — zde je jen přehled. Zapisováno proto,
aby pozdější konsultace návrhu měla k dispozici *proč*, ne jen *co*.

| ADR | Rozhodnutí | Stav |
|-----|------------|------|
| [001](adr/001-evolutionary-sasos.md) | Evoluční architektura (SASOS → mikrojádro později) | Accepted |
| [002](adr/002-single-address-space-ring0.md) | Single Address Space, Ring 0 | Accepted |
| [003](adr/003-stable-interfaces-day-one.md) | Stabilní rozhraní od prvního dne | Accepted |
| [004](adr/004-kernel-interface-not-abi.md) | Kernel Interface (KI), ne ABI | Accepted |
| [005](adr/005-renderer-layer.md) | Renderer jako samostatná vrstva | Accepted |
| [006](adr/006-generic-runtime-api.md) | Generické Runtime API | Accepted |
| [007](adr/007-lua-5-4-vendored.md) | Lua 5.4 vendored, staticky, ne LuaJIT | Accepted |
| [008](adr/008-event-loop-not-mlfq.md) | Scheduler: událostní smyčka, ne MLFQ | Accepted |
| [009](adr/009-minimal-rendering-primitives.md) | Minimální renderovací primitiva | Accepted |
| [010](adr/010-no-filesystem-yet.md) | Žádný souborový systém, dokud nebude potřeba | Accepted |
| [011](adr/011-wasm3-later.md) | wasm3 později, šev Runtime → Program | Accepted |
| [012](adr/012-limine-bootloader.md) | Limine bootloader | Accepted |
| [013](adr/013-zig-version-pinning.md) | Pinning Zigu mimo název projektu (.zig-version) | Accepted |
| [014](adr/014-deterministic-build.md) | Deterministický build | Accepted |
| [015](adr/015-measure-every-milestone.md) | Měření po každém milníku | Accepted |
| [016](adr/016-bootable-commit.md) | Bootovatelný commit | Accepted |
| [017](adr/017-concurrency-model-m7.md) | Concurrency model M7 (preemptivní RR, kritické sekce bez locků) | Accepted |
| [018](adr/018-ring3-ki-transport.md) | Transport KI v Ring 3: mailbox IPC, comptime dispatch, IRQ routing | Accepted |
| [019](adr/019-bootloader-gate.md) | Bootloader gate: kernel nezávisí na typech bootloaderu (BootInfo) | Accepted |
| [020](adr/020-future-extensibility.md) | Rozšiřitelnost: nové features jako nové KI moduly na konec | Accepted |

**Pravidla ADR:** rozhodnutí se nemění dodatečně — změna názoru = nový ADR odkazující na
starý. Čísla se nepřehazují a nemazají.

---

## 5. Známá rizika

Přiznaná dopředu, aby nebyla později "objevem". Rizika se řídí, ne ignorují:

| Riziko | Popis | Zmírnění |
|---|---|---|
| **Single address space** | Bug v nativním Zig kódu může zkorumpovat cokoli (kernel, framebuffer, ostatní moduly). | Lua/Wasm běží v managed runtime; nativní kód prochází invarianty (`spec/invariants.md`) a review. |
| **Embedded Lua v jádře** | Lua VM běží s plným oprávněním; bug VM nebo bindingů = pád systému. | Vendored stabilní verze, minimální binding plocha, host testy marshallingu. |
| **Žádná MMU izolace** | Není hardwarová hranice mezi komponentami. | Jazyková izolace (Lua/Wasm); ADR-002; non-goal do budoucna. |
| **Žádné userspace ovladače** | Ovladače (PS/2, timer) běží v jádře; jejich bug = pád. | Malý, kontrolovaný kód; QEMU smoke test jako záchyt. |
| **Žádná perzistence před M6** | Nelze uložit konfiguraci/editor do M6. | Vědomé non-goal (`spec/non-goals.md`); embedded assety to kompenzují. |
| **Jednojadro** | Single-core; SMP by byl zásah do scheduleru a paměti. | Non-goal (`spec/non-goals.md`); architektura jednojadro umožňuje měřit. |
| **Dokumentace těžší než kód** | Přerostení plánování do nekonečna. | Tento dokument je přehledový; detaily až na vyžádání; každé měřitelné rozhodnutí se ověřuje v kódu. |

---

## 6. Terminologie

| Termín | Význam |
|---|---|
| **SASOS** | Single Address Space Operating System — jeden adresní prostor, vše Ring 0. **Radikálnější varianta klasických SASOS** (Opal, Nemesis aj.): akademické systémy měly hardwarovou ochranu mezi doménami, Aster žádnou — ochrana je čistě jazyková (Lua/Wasm managed) a sdílený stav se chrání zakázáním preempce (ADR-017). |
| **KI** | Kernel Interface — stabilní rozhraní mezi jádrem a zbytkem systému. Budoucí základ ABI. |
| **Renderer** | Vrstva mezi Graphics API a Framebufferem; dnes `fillRect`/`blit`/`glyph`, zítra GPU/IPC. |
| **Runtime** | Vrstva odpovědná za spouštění programů (`Runtime.spawn`), abstrahuje Lua/Wasm/Native. |
| **Program** | Výsledek `spawn()` — handle na běžící modul. |
| **Event loop** | Hlavní smyčka `poll() → update() → render()`. |
| **Embedded asset** | Zdroj (lua skript, font) zakompilovaný do binárky. |

---

## 7. Repozitářová struktura

```
aster-os/
├── build.zig / build.zig.zon     # `zig build run` → QEMU, `zig build test` → host testy
├── .zig-version                  # exaktní verze toolchainu (0.15.2)
├── README.md                     # manifest + odkaz na .zig-version
├── spec/                         # TENTO SOUBOR + dílčí specifikace
│   ├── README.md
│   ├── architecture-overview.md # tento dokument
│   ├── manifest.md
│   ├── non-goals.md              # co systém vědomě nedělá
│   ├── coding-style.md           # filozofie a pravidla kódu
│   ├── adr/                      # architektonická rozhodnutí (ADR-001..020)
│   ├── kernel-interface.md       # KI: sys.dispatch + interface moduly
│   ├── graphics.md               # Graphics API → Renderer → Framebuffer
│   ├── input.md                  # vstupní události
│   ├── runtime.md                # Runtime.spawn + RuntimeKind
│   ├── timer.md                  # čas: tick zdroj (M2), KI timer, kooperativní sleep
│   ├── memory.md                 # paměť: PFA, heap alokátor, lua_Alloc
│   ├── invariants.md             # Safety / Performance / Architecture
│   ├── roadmap.md                # M0–M8 + kvalitní metriky
│   ├── verification.md           # verifikační pipeline + deterministický build
│   └── debugging.md              # Debugging Survival Guide (GDB, serial dump)
├── src/
│   ├── kernel/                   # boot, mem/pfa+heap, cpu/idt+timer, drivers/ps2,
│   │   │                         # fb/framebuffer, render/renderer+font+text, api/, sys/
│   └── shell/                    # main.lua (embedded) + UI v Luay
├── libs/
│   ├── limine/                   # vendored bootloader + hlavičky
│   └── lua-5.4/                  # vendored Lua 5.4 zdroj
├── tests/                        # host unit testy (PFA, font blit, binding marshalling)
├── tools/
│   ├── qemu-smoke.sh             # serial marker + timeout
│   └── bench.sh                  # měření metrik
└── images/                       # generované ISO / disk image
```

---

## 8. Index specifikací

| Dokument | Obsah |
|---|---|
| `manifest.md` | Filozofie projektu — jednoduchost před izolací, evolvabilní rozhraní. |
| `non-goals.md` | Co systém vědomě nedělá (POSIX, SMP, USB, networking, ...). |
| `coding-style.md` | Pravidla struktury kódu a návrhu modulů (kontrolní seznam pro review). |
| `adr/` | Architektonická rozhodnutí (ADR-001..020), každé v samostatném souboru. |
| `kernel-interface.md` | KI: sys.dispatch, syscall čísla, interface moduly, pravidla verzování. |
| `graphics.md` | Graphics API / Renderer / Framebuffer — vrstvy a povolené operace. |
| `input.md` | Vstupní události: PS/2 klávesnice, fronta, mapování na Lua. |
| `runtime.md` | Runtime.spawn, RuntimeKind, vazba Runtime → Program, error containment. |
| `timer.md` | Čas: tick zdroj (M2), KI `timer`, kooperativní sleep. |
| `memory.md` | Paměť: PFA, obecný alokátor, `lua_Alloc`, cache atributy. |
| `invariants.md` | Bezpečnostní, výkonnostní a architektonické invarianty (kontrolní seznam pro review). |
| `roadmap.md` | Milníky M0–M8 s kritérii "hotovo" + tabulka kvalitních metrik. |
| `verification.md` | Verifikační pipeline (Zig), deterministický build, pravidlo bootovatelného commitu. |
| `debugging.md` | Debugging Survival Guide — GDB+QEMU, čtení serial dumpu, pravidla pro IRQ. |
