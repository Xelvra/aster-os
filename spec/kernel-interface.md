# Kernel Interface (KI)

**Status:** V1 (draft). **Rozhodnutí:** ADR-004, ADR-003.
**Vztah k ABI:** Toto je **interní rozhraní**, ne ABI. ABI z něj vznikne až s Ring 3 a
instrukcí `syscall`, téměř beze změn.

---

## 1. Účel

KI je stabilní rozhraní mezi jádrem (a jeho podvrstvami) a zbytkem systému — deskem,
skriptovacím enginem a runtime. Je to ta vrstva, kterou dnes píšeme nejpečlivěji, protože
je to nejlevnější pojistka evoluce do mikrojádra.

**Základní princip:**

> API od prvního dne neví, že je všechno v Ring 0.

Například `Graphics.drawRect(...)` dnes vykoná přímé volání funkce, za dva roky půjde přes
IPC → Compositor — **bez změny volajícího kódu**.

---

## 2. Moduly rozhraní

Všechna veřejná rozhraní žijí v `src/kernel/api/`:

| Modul | Zodpovědnost | Detail |
|---|---|---|
| `sys.zig` | `dispatch(num, args)` — jediný vstupní bod operací | viz §3 |
| `debug.zig` | Ladící/konzolový výstup (výpis na serial) | viz §3.5 |
| `graphics.zig` | Kreslení: `drawRect`, `blit`, `drawGlyph`, border/round/gradient | `spec/graphics.md` |
| `input.zig` | Vstupní události: `pollEvent`, `nextEvent` | `spec/input.md` |
| `timer.zig` | Čas: `ticks`, `sleepMs`, tick zdroj | `spec/timer.md` |
| `runtime.zig` | Spouštění programů: `spawn`, `RuntimeKind` | `spec/runtime.md` |
| `sysmon.zig` | Systémové metriky: RAM usage pro shell | tento soubor |
| `power.zig` | Napájení: reboot (i8042 reset) | session menu, M5 |

> **Výjimka z pravidla:** `Yield` (vzdání se kvanta) je **triviální/interní** — nespravuje
> ho modul v `api/`, volá přímo `scheduler.yield()`. Nespadá pod plné pravidlo „KI je
> jediný veřejný povrch“ ve smyslu rozhraní pro Lua/UI; je to vnitřní kooperace se
> schedulerem (ADR-017).

**Pravidla:**

- Lua a UI **nikdy nevolají** interní funkce (framebuffer, alokátor, struktury kernelu).
  Jdou výhradně přes KI.
- Interní moduly (`renderer`, `framebuffer`, `pfa`, `idt`, ...) **nejsou** veřejné.
- KI funkce jsou čisté vstupně-výstupní body; interní změny pod nimi jsou volné.

---

## 3. `sys.dispatch` — jediný vstupní bod

### 3.1 Princip

```zig
pub const Syscall = enum(u64) {
    Debug   = 0,   // ladící/konzolový výstup
    Graphics = 1,  // sub-operační čísla viz spec/graphics.md
    Input   = 2,   // čtení událostí
    Timer   = 3,   // sleep/tick dotaz
    Runtime = 4,   // Runtime.spawn a související
    Yield   = 5,   // dobrovolné vzdání se časového kvanta (výhledově)
    Sysmon  = 6,   // systémové metriky (RAM usage pro shell, M5)
    Power   = 7,   // reboot (session menu, M5)
};
```

V dnešní implementaci je `dispatch` obyčejná Zig funkce, která provede přepínač a zavolá
interní handler. Až přijde Ring 3, tento enum se stane čísly syscallů a `dispatch` se
přepíše na instrukci `syscall`. **Čísla jsou zmrazená už teď** — přidávají se jen nová
na konec, nikdy se nemění ani nemazají.

### 3.2 Kostra (ilustrativní)

```zig
pub const SyscallArgs = struct {
    a: u64 = 0,
    b: u64 = 0,
    c: u64 = 0,
};

pub fn dispatch(num: Syscall, args: SyscallArgs) u64 {
    return switch (num) {
        .Debug    => debug.dispatch(args),   // api/debug.zig
        .Graphics => graphics.dispatch(args),
        .Input    => input.dispatch(args),   // api/input.zig
        .Timer    => timer.dispatch(args),   // api/timer.zig
        .Runtime  => runtime.dispatch(args),
        .Yield    => @intFromEnum(KiStatus.NotSupported), // scheduler.yield() od M7
        .Sysmon   => sysmon.dispatch(args),
    };
}
```

> **Předávání složených argumentů:** `SyscallArgs` má jen tři skalární `u64` (registry
> v budoucím ABI). Složené argumenty — stringy, buffery, obdélníky, barvy — se
> předávají **pointerem na paměť volajícího** v jednom z registrů (`b`/`c`), protože
> SASOS sdílí adresní prostor a pointer je zdarma. Žádné kopírování struktury přes
> registry. Callee nikdy neuchovává pointer za hranicí volání (platnost jen do návratu).

> **Poznámka:** Dokud neběží skutečný `syscall` přechod, je tahle vrstva tenká a přes ni se
> volá málo věcí — drž ji tak. Většina "jádra" běží přímo v procesu.

### 3.3 Chybové kódy (KI status)

Vrací se jako `u64` z `dispatch`. Konvence: `0` = úspěch, jiné hodnoty = chybové kódy.
Definované kódy (rozšiřitelné):

```zig
pub const KiStatus = enum(u16) {
    Success         = 0,
    InvalidArgument = 1,
    NotFound        = 2,
    NotSupported    = 3,
    NoMemory        = 4,
    Busy            = 5,
    Timeout         = 6, // výhledově: IPC / pomalá operace nepokrytá v čase
};
```

> `Timeout` se přidává **teď, dopředu** (čísla se nemění, jen přibývají na konec —
> pravidlo §4.2): volající kód ho může zpracovávat už dnes, aniž by ho IPC v Ring 3
> překvapilo. Semantika §6.2.

### 3.4 Sub-operační čísla

Jednotlivá rozhraní (Graphics, Input, ...) mají vlastní sub-operační enum. Ta se do
`dispatch` nedostávají globálně — každý modul si je spravuje sám a `dispatch` je jen
směrovač. Detail per modul v příslušné specifikaci.

### 3.5 Modul `debug` (triviální, dokumentovaný zde)

`debug` je malý, plnohodnotný KI modul (není interní) — umožňuje Lua/UI psát na serial
konzoli pro ladění. Nemá vlastní spec soubor, protože je triviální:

| # | Operace | Signatura | Poznámka |
|---|---------|-----------|----------|
| 0 | `write` | `(str: [*]const u8, len: u64) → ()` | výpis na serial, bez alokace |
| 1 | `status` | `() → u64` | flag pro aktivní ladění (0/1) |

- Žádné formátování (bez alokace); formátování řeší volající (Lua).
- Sub-op čísla jsou zmrazená jako ostatní (§4 pravidlo 2).

### 3.6 Modul `sysmon` (systémové metriky, M5)

Malý KI modul, který vystavuje reálné metriky jádra shellu (Lua). Nejdřív jen RAM
(ze stránkového alokátoru), rozšiřuje se s M6/M7 (CPU, disk, ...):

| # | Operace | Signatura | Poznámka |
|---|---------|-----------|----------|
| 0 | `ram_total_mb` | `() → u64` | celková RAM z `PageFrameAllocator.total_pages` |
| 1 | `ram_free_mb` | `() → u64` | volná RAM z `totalFreePages()` |

- Žádná alokace, žádné blokování — čisté čtení stavu alokátoru.
- Lua bindingy: `sysmon.ram_total_mb()`, `sysmon.ram_free_mb()` (viz `spec/runtime.md` §4).
- Sub-op čísla jsou zmrazená jako ostatní (§4 pravidlo 2).

---

## 4. Pravidla KI (normativní)

1. **KI je jediný veřejný povrch.** Nic mimo `api/` se nevolá z Lua/UI.
2. **Čísla se nikdy nemění ani nemazají** — jen přidávají na konec.
3. **KI funkce nesmí alokovat** na kritické cestě kreslení (viz `spec/invariants.md`).
4. **Žádná KI funkce nesmí nikdy selhat tichým návratem** — vždy vrací `KiStatus`.
5. **Změna signatury KI = nový ADR v `architecture-overview.md`** + major bump verze KI.
6. **Dokumentace KI je ABI-pravda.** Implementace se může měnit; signatury ne.

---

## 5. Verzování KI

KI má vlastní číslo verze, nezávislé na projektu:

```
KI_VERSION_MAJOR: rozbíjí volající kód (nový ADR, migrace)
KI_VERSION_MINOR: přidává operace, neporušuje stávající
KI_VERSION_PATCH: opravy dokumentace/sémantiky
```

V dnešní podobě (bez Ring 3) je to čistě deklarativní — číslo se drží v `api/version.zig`.
Až vznikne skutečné ABI, číslo se přenese do dokumentu specifikace ABI.

---

## 6. Migrační cesta: KI → ABI

Když přijde Ring 3:

1. `dispatch(num, args)` se přepíše na instrukci `syscall`; vstupní registry: `rax`=num,
   `rdi/rsi/rdx/r10/r8`=args (konvence x86_64).
2. Moduly `api/*` se rozdělí: rozhraní (zůstává) + transport (dnes call, zítra IPC).
   **Návrh budoucího transportu je rozhodnutý v ADR-018** (mailbox zprávy, comptime
   dispatch, IRQ routing) — neimplementuje se dřív než ve fázi oddělování.
3. Čísla z §3.1 zůstávají beze změny — stávají se čísly syscallů / identifikátory
   operací v IPC zprávách.
4. KiStatus se stává syscall návratovým statusem.

Pravidlo: **kód napsaný proti dnešní KI musí fungovat proti zítřejšímu ABI bez změn.**
Tohle je testovatelný požadavek — proto je KI oddělena od implementace už teď.

### 6.1 Sémantika: synchronní request/reply (základ evoluce)

KI je **synchronní request/reply kontrakt už dnes i zítra**. To je klíč k tomu, proč
přechod na IPC nevyžaduje refaktor volajícího kódu:

- **Dnes:** `gfx.drawRect(...)` = přímé volání → vrátí se, až je operace hotová.
- **Zítra (IPC):** `gfx.drawRect(...)` = zpráva compositoru + **blokování na odpovědi**
  → vrátí se, až je operace hotová.

Sémantika je identická; mění se jen transport. **Asynchronie nikdy neuniká z `api/*`
modulů do Lua/UI** — Lua nevidí porty, callbacky ani zprávy, jen volání a výsledek.

**Co se přechodem upřímně mění (vědomě):**

1. **Latence.** Volání se zpomalí (ring přechod, IPC, možná jiné CPU). UI operace jsou
   nízkofrekvenční (kreslení, čtení událostí), blokující čekání je přijatelné — viz
   KPI „0 syscallů" platí pro fázi Ring 0 (`architecture-overview.md`).
2. **Nová třída selhání.** Dnes chyby: `InvalidArgument`, `NoMemory`... Zítra navíc:
   „server nedostupný" (`Busy`, `NotFound`), případně `Timeout`. KI proto **od prvního
   dne vrací `KiStatus`** — volající už dnes chyby zpracovává, nové kódy ho nepřekvapí.
   Nepoužívá se umělé skrývání chyb (žádné tiché úspěchy).
3. **Žádný fire-and-forget.** Žádná KI operace není „pošli a zapomeň" — každá se buď
   dokončí, nebo vrátí `KiStatus`. To je invariant i pro budoucí IPC transport.

### 6.2 Pomalé operace (FS a dlouhé čtení, M6+)

Synchronní request/reply neznamená **blokování event loopu**. Pomalá operace (např.
čtení souboru z disku od M6) se liší od rychlé (kreslení) jen **délkou čekání** —
sémantika zůstává stejná, řeší se jinak:

- **Rychlé operace:** vykonají se hned, vrátí `KiStatus`.
- **Pomalé operace:** vykonají se **kooperativně** — volající (Lua úkol) se nechá
  suspendovat, event loop běží dál a pokračuje, až je výsledek hotový (obdoba
  kooperativního `sleepMs`, `spec/timer.md` §3). Žádné busy-wait.
- **Nevrací se „předčasně" s prázdným výsledkem:** buď se operace dokončí a vrátí
  data/`Success`, nebo vrátí `KiStatus` (vč. `Timeout`). Žádný „přijď později".
- **Asynchronie zůstává uvnitř `api/*`** — Lua vidí stále synchronní volání, jen se
  za ním kernel/lua runtime kooperativně odloží. To je konzistentní s §6.1.

> Důvod, proč to neřešíme `callback`/`event` exponovaným do Lua: callback rozbíjí
> request/reply kontrakt (dvě místa pokračování, ordering, reentrancy) a zbytečně
> mění rozhraní. Kooperativní suspendace zachovává jednoznačný tok řízení i sémantiku.
