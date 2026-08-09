# Aster OS — Architektonický přehled

**Verze:** 1.1 (draft)
**Status:** Current design — Schváleno k implementaci (Milníky M0–M6)

> Tento dokument je **hlavním architektonickým přehledem** projektu. Zachycuje aktuální
> návrh a jeho rozhodnutí. Slouží jako referenční bod pro konzultaci návrhu architektury a
> jako výchozí bod pro psaní kódu.
>
> Jednotlivá rozhodnutí žijí jako samostatné záznamy v `spec/adr/`. Podrobné dílčí
> specifikace v `spec/*.md` (viz index níže). Tento dokument je **přehledový**: čte se
> celý, dílčí dokumenty až na vyžádání.
>
> **Dvě roviny:** §3 popisuje **Current architecture** (co je implementované v M0–M6,
> `src/`). §4 popisuje **Target architecture** (M7+: Wasm runtime, per-program státy,
> oddělení do Ring 3). Dokument neprezentuje target jako hotový — kde se Current a Target
> liší, je to výslovně řečeno.

---

## 1. Shrnutí

Aster je experimentální desktopový operační systém napsaný v Zigu. První implementace
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
| Velikost kernel image | < 512 KB (s Lua; viz `roadmap.md` §2) |
| Kernel Entry → First Frame (z Limine handoff) | < 40 ms (cíl M4/M5; v QEMU TCG měřeno ≈ 90 ms — viz `roadmap.md` pozn. ³) |
| GUI paměť (idle) | < 32 MB RAM |
| UI kreslení | 0 syscallů, 0 kopií framebufferu *(platí pro fázi Ring 0; od Ring 3 — M8+ — se přidávají ring přechody, viz `roadmap.md`; výjimka: kurzor myši ukládá/obnovuje 12×19 px pod kurzorem)* |
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
║       # M0–M6              ║
║                            ║
║  CPU / MEMORY / IRQ        ║
║  STORAGE (M6)              ║
║  DRIVERS / SCHEDULER (M7+) ║
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
│     # M4     │  │       # M7/M9        │
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

### 3.1 Current architecture (M0–M6, implementováno)

```text
Lua shell (desktop, vendored Lua 5.4)
   │  KI bindings → sys.dispatch()
   ▼
KERNEL ROZHRANÍ (KI) — api/* (dispatch vrstva)
   │
   ├── graphics API ──→ renderer ──→ framebuffer (GOP/Limine)
   ├── input API ─────→ input/service ──→ fronta ← PS/2 IRQ, APIC timer
   ├── runtime API ───→ lua (jediný vestavěný program)
   ├── timer API ─────→ time.zig (monotónní tick)
   ├── sysmon API ────→ mem.Memory.stats()
   ├── debug API ─────→ serial (privilegovaný diagnostický sink)
   └── power API ─────→ i8042 reset

kernel/main.zig = jediný privileged composition root
   │  (sestavuje mem, cpu/idt+apic, drivery, fs, renderer, cursor, lua)
   ▼
subsystémy: mem/pfa+heap, cpu/idt+apic+time, drivers (ps2, virtio-blk),
            fs (gpt, ext2, file), render (renderer, font, mouse_cursor)
```

**Kurzor myši je privilegovaný graphics overlay**, ne součást Rendereru ani Input
subsystemu: `render/mouse_cursor.zig` ukládá/obnovuje pixely a kreslí sprite přímo do
framebufferu (12×19 px). Event loop aplikuje mouse events na overlay a píše výsledný
stav do `input/service`; service o framebufferu neví. Framebuffer je interní zdroj
graphics subsystemu — běžné kreslení jde výhradně přes Renderer, privilegovaný overlay
přes `mouse_cursor` (viz `spec/graphics.md` §7).

**M6 storage:** `virtio-blk → Block Device API → GPT → ext2 → File API`. File API je
**ext2-specific adapter** (ADR-023 — backend abstraction až s druhým backendem).

### 3.2 Target architecture (M7+, oddělení)

Výše popsané rozhraní zůstává; mění se obsah vrstev:

```text
Shell / UI (Lua)    Aplikace (Wasm — wasm3, M7)
   │                 │
   └───── KI ────────┘  (aplikace psané pro Aster volají Aster bindings)
   ▼
Runtime (generický): per-program lua_State/Wasm → scheduler (ADR-017)
   ▼
Program lifecycle: spawn / kill / status (M7)
```

- **M7:** Runtime přestává být "jeden vestavěný Lua program" — `spawn()` vytváří
  per-program státy, scheduler preemptuje, `Program` je schedulable execution context
  (do M6 je to logický placeholder, `spec/runtime.md` §2).
- **M8+ (oddělení):** subsystémy se stěhují za stabilní KI do Ring 3 (ADR-018); KI
  volání se z přímých stávají IPC — **bez změny volajícího kódu**. Přibudou
  memory protection, syscalls a MMU (žádné MMU v M0–M6).
- **Wasm je hostován za generickým Runtime API** (ADR-011): kernel nepřijme žádný
  Wasm-specifický kód, vše za `Runtime.spawn`.

### 3.3 Čtyři pilíře

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
| [021](adr/021-extended-rendering-primitives.md) | Rozšířená renderovací primitiva pro UI (roundRect, border, gradient) | Accepted |
| [022](adr/022-network.md) | Síť jako KI modul `net.*` — minimální stack (virtio-net, ARP/IPv4/ICMP/UDP), M9 | Accepted |
| [023](adr/023-filesystem-ext2-non-posix.md) | Persistence: ext2 backend (read-only), non-POSIX sémantika, tenké rozhraní | Accepted |
| [024](adr/024-keyboard-layout-registry.md) | Multi-layout klávesnice: KL registry + přepínání za běhu (`input.set_layout`) | Accepted |

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
├── .zig-version                  # exaktní verze toolchainu (0.16.0)
├── README.md                     # manifest + odkaz na .zig-version
├── spec/                         # TENTO SOUBOR + dílčí specifikace
│   ├── README.md
│   ├── architecture.md           # tento dokument
│   ├── manifest.md
│   ├── non-goals.md              # co systém vědomě nedělá
│   ├── code-style.md             # filozofie a pravidla kódu
│   ├── adr/                      # architektonická rozhodnutí (ADR-001..024)
│   ├── kernel-interface.md       # KI: sys.dispatch + interface moduly
│   ├── graphics.md               # Graphics API → Renderer → Framebuffer
│   ├── desktop-ui.md            # desktop UI port (bar, launcher, okna, widgety)
│   ├── input.md                  # vstupní události
│   ├── runtime.md                # Runtime.spawn + RuntimeKind
│   ├── timer.md                  # čas: tick zdroj (M2), KI timer, kooperativní sleep
│   ├── memory.md                 # paměť: PFA, heap alokátor, lua_Alloc
│   ├── invariants.md             # Safety / Performance / Architecture
│   ├── roadmap.md                # M0–M8 + kvalitní metriky
│   ├── verification.md           # verifikační pipeline + deterministický build
│   ├── debugging.md              # Debugging Survival Guide (GDB, serial dump)
│   ├── troubleshooting.md        # vyřešené pasti a lekce (C1..C27, H1..H2)
│   ├── handoff.md                # postup pro nevyřešené problémy
│   └── handoffs/                 # handoff dokumenty (open/closed)
├── src/
│   ├── kernel/                   # boot, mem/pfa+heap, cpu/idt+timer, drivers/ps2,
│   │   │                         # fb/framebuffer, render/renderer+font+text, api/,
│   │   │                         # time.zig (monotónní tick), lua/ (Lua 5.4 binding +
│   │   │                         # ui/ shell moduly), sys/
│   └── kernel/lua/ui/            # desktop shell v Luay: theme, wm, repl, launcher,
│                                 # input, main (concatenované do jednoho chunku)
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
| `code-style.md` | Pravidla struktury kódu a návrhu modulů (kontrolní seznam pro review). |
| `adr/` | Architektonická rozhodnutí (ADR-001..023), každé v samostatném souboru. |
| `kernel-interface.md` | KI: sys.dispatch, syscall čísla, interface moduly, pravidla verzování. |
| `graphics.md` | Graphics API / Renderer / Framebuffer — vrstvy a povolené operace. |
| `desktop-ui.md` | Desktop UI — port vzhledu/chování z cachyos-hypr-noctalia, reimplementováno (bar, launcher, okna, widgety). |
| `input.md` | Vstupní události: PS/2 klávesnice, fronta, mapování na Lua. |
| `runtime.md` | Runtime.spawn, RuntimeKind, vazba Runtime → Program, error containment. |
| `timer.md` | Čas: tick zdroj (M2), KI `timer`, kooperativní sleep. |
| `memory.md` | Paměť: PFA, obecný alokátor, `lua_Alloc`, cache atributy. |
| `invariants.md` | Bezpečnostní, výkonnostní a architektonické invarianty (kontrolní seznam pro review). |
| `roadmap.md` | Milníky M0–M8 s kritérii "hotovo" + tabulka kvalitních metrik. |
| `verification.md` | Verifikační pipeline (Zig), deterministický build, pravidlo bootovatelného commitu. |
| `debugging.md` | Debugging Survival Guide — GDB+QEMU, čtení serial dumpu, pravidla pro IRQ. |
| `troubleshooting.md` | Vyřešené pasti a lekce (Zig 0.16, Limine, heap, PS/2 myš). |
| `handoff.md` | Formální postup pro nevyřešené problémy + seznam handoffů. |
