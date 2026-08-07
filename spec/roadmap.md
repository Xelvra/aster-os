# Roadmap — Milníky a Kvalita

**Status:** V1 (draft). **Rozhodnutí:** ADR-015, ADR-016.

---

## 1. Dvě roviny sledování

Projekt se řídí **dvěma nezávislými posloupnostmi**:

### 1.1 Milníky (funkcionalita)

```
M0 Boot → M1 Memory → M2 CPU → M3 Graphics → M4 Lua
        → M5 UI → M6 Storage → M7 Runtime → M8 Stabilizace
```

### 1.2 Kvalitní metriky (musí se hlídat při KAŽDÉM milníku)

```
Kernel Entry → First Frame   (primární boot metrika, reprodukovatelná)
Firmware → First Frame       (sledovaná, závisí na emulaci/firmwaru)
render throughput            (Lua renderů za tick okno, runtime test — M4)
frame latency (p99)
binary size
RAM usage
compile time
```

Pravidlo: **žádná nová feature se nepovažuje za hotovou, dokud se nezměří a nezapíše
hodnota do tabulky níže.** Jakmile by nová feature zvětšila binárku o >40 % nebo zdvojnásobila
frame latency bez zdůvodnění, musí přednost dostat optimalizace, ne další funkcionalita.

---

## 2. Tabulka kvalitních metrik

> Cílové hodnoty. Skutečné hodnoty se doplňují po dokončení každého milníku.
>
> Čísla v tabulce jsou **rozsahy a cíle, ne odhady s falešnou přesností.** Přesnou velikost
> kernelu nikdo nezná, dokud běží — hodnoty se zapisují z měření, ne z předpovědi.

| Milník | Kernel image | RAM (idle) | Kernel Entry → First Frame | Frame latency (p99) | Compile time |
|--------|-------------:|-----------:|---------------------------:|--------------------:|-------------:|
| **Cíl** | < 256 KB | < 32 MB | < 50 ms | < 16 ms | TBD |
| **M0 (měřeno)** | **12.0 KB** | — | **≈ 0.3 s**¹ | — | TBD |
| M0 (cíl) | < 64 KB | — | < 10 ms | — | TBD |
| **M1 (měřeno)** | **17.4 KB** | — | **≈ 0.4 s**¹ | — | TBD |
| M1 (cíl) | < 80 KB | ≤ 4 MB | < 15 ms | — | TBD |
| **M2 (měřeno)** | **28.8 KB** | — | **≈ 0.5 s**¹ | — | TBD |
| M2 (cíl) | < 96 KB | ≤ 4 MB | < 20 ms | — | TBD |
| **M3 (měřeno)** | **33.8 KB** | — | **≈ 0.6 s**¹ | — | TBD |
| M3 (cíl) | < 128 KB | ≤ 6 MB | < 25 ms | < 16 ms | TBD |
| **M4 (měřeno)** | **336 KiB** (RF 259) | — | **≈ 60 ms**² | TBD | TBD |
| M4 (cíl) | < 512 KB (s Lua) | ≤ 12 MB | < 40 ms | < 16 ms | TBD |
| M5 | < 512 KB | ≤ 16 MB | < 40 ms | < 16 ms | TBD |
| M6 | < 768 KB | ≤ 24 MB | < 50 ms | < 16 ms | TBD |
| M7 | < 1 MB | ≤ 32 MB | < 50 ms | < 16 ms | TBD |
| M8 | TBD | TBD | TBD | TBD | TBD |

**Definice:**
- **Kernel Entry → First Frame:** doba od Limine handoff (vstup do našeho kódu) po první
  vykreslený snímek. **Toto je primární, reprodukovatelně měřitelná metrika** — firmware
  a inicializace RAM jsou mimo naši kontrolu.
- **Firmware → First Frame:** celá doba od zapnutí QEMU (BIOS/UEFI) po první snímek.
  Měřitelná, ale závisí na emulaci/firmwaru — sledovaná, nikoli cílovaná.
- **Frame latency (p99):** percentil 99 rozložení doby mezi `render()` a `present()`.
  Latence je důležitější než FPS.
- **RAM (idle):** rezidentní paměť systému bez spuštěných aplikací.

> ¹ M0–M3 měřily `tools/bench.sh` **wall-clock** od spuštění QEMU po serial marker — zahrnují
> firmware/BIOS/Limine init, který je mimo kontrolu kernelu (≈ 3 s prodleva bootloaderu).
> Hodnoty jsou **odhad po odečtení ≈ 3 s** — původní měření byla 3.3 / 3.4 / 3.5 / 3.6 s
> wall-clock; fáze jsou hotové, nelze je změřit znovu čistě, takže jde o aproximaci.
> ² Od M4 měří `tools/bench.sh` odděleně **Firmware → First Frame** (zahrnuje ~3.3 s
> BIOS + Limine) a **Kernel Entry → First Frame** (čistý čas našeho kódu, marker
> `ASTER KERNEL ENTRY` na vstupu po Limine handoff → marker `ASTER FIRST FRAME`).
> Kernel image je velikost strippnutého ELF (`zig-out/bin/aster`). **RF** = `ReleaseFast`
> build (`zig build -Doptimize=ReleaseFast`) — bez safety checks, menší a rychlejší;
> produkce a verifikace běží na `ReleaseSafe` (safety checky zachytily reálné bugy C2/C17).
> Lua C kód se kompiluje s `-Os` (úspora ~40 KB oproti defaultu bez `-O`).
> **Render throughput** (M4): `testRenderThroughput` v runtime testech měří plné Lua
> REPL rendery za 10 APIC ticků. Baseline po optimalizaci rendereru: **8–9 renders/10 ticks**
> (před tím 5). Při změně render pipeline se číslo nesmí zhoršit bez zdůvodnění.

---

## 3. Milníky — detail

### M0 — Boot

**Cíl:** deterministický, reprodukovatelný build; QEMU bootne; serial marker.

- [x] Toolchain: Zig **0.16.0** (`.zig-version`), Limine vendored, Lua 5.4.8 vendored (zdroj).
- [x] `build.zig`: `zig build` → bootovatelný ISO/disk image; `zig build run` → QEMU.
- [x] `zig build test` → host unit testy (prázdná sada připravená).
- [x] Boot handoff z Limine (long mode, serial, GOP framebuffer init).
- [x] Serial výstup markeru `ASTER BOOT OK` (chycený `tools/qemu-smoke.sh`).
- [x] `tools/qemu-smoke.sh`: serial marker + timeout; `tools/bench.sh` kostra.
- [x] **Deterministický build:** stejný commit + stejný Zig = stejný hash binárky.
- [x] Výplň prvního řádku v tabulce metrik.

**Definition of Done (DoD):** QEMU bootne s markerem na stdout, host testy zelené,
`zig fmt --check` čisté, metriky zapsané, commit bootovatelný.

### M1 — Memory

**Cíl:** fyzický správce paměti.

- [x] Parsování Limine memory map (hranice RAM, rezervované regiony).
- [x] **Bitmapový Page Frame Allocator** (`src/kernel/mem/pfa.zig`).
- [x] **Obecný heap alokátor** nad PFA (`src/kernel/mem/heap.zig`, first-fit free list,
      slouží i jako `lua_Alloc`) — spec `spec/memory.md`.
- [x] Host unit testy PFA i heap alokátoru: alokace/uvolnění, fragmentace,
      out-of-memory, coalescing.
- [x] **Ověření cache atributu framebufferu** (UC vs WC) z Limine mapování — viz
      `spec/memory.md` §6; pokud je UC, zaznamenat jako riziko pro M3 frame latency.
- [x] Zápis RAM layoutu na serial při bootu.
- [x] Metriky do tabulky.

**DoD:** PFA + heap fungují a jsou pokryté testy; serial vypíše RAM layout; bootovatelný commit.

> **Odloženo (YAGNI):** buddy allocator, VMM, per-proces adresní prostory. Paging zůstává
> statický z Limine (ploché mapování). VMM přijde až s fází oddělování (Ring 3).
> Výjimka: **pouze framebuffer region** se může v M3 přepnout na WC přes PAT bez plného
> VMM (`spec/memory.md` §6).

### M2 — CPU

**Cíl:** přerušení, časovač, vstup.

- [x] GDT (dle potřeby), **IDT** se všemi entry, správné nastavení segmentů.
- [x] **Local APIC timer** jako tick zdroj (MSR `IA32_APIC_BASE`, LVT) + korektní
      remap legacy 8259 PIC. **I/O APIC**: pro doručení ISA IRQ v APIC režimu je nutné
      programovat redirection table (IRQ1 → vektor 0x21, BSP); **žádné ACPI MADT
      parsování** — IOAPIC adresa (0xFEC00000) je hardcoded pro QEMU. Dluh do M7
      (SMP): MADT (RSDP → RSDT/XSDT → MADT) pro skutečné LAPIC ID, ISA IRQ→GSI
      overrides a detekci NMI. Viz `spec/non-goals.md`.
- [x] **Fault policy:** defaultní IDT handlers pro double fault / GPF / page fault —
      výpis stavu na serial a halt (ne reset, ne tiché pokračování). Detail
      `spec/invariants.md` §1 (Safety).
- [x] **PS/2 klávesnice** — IRQ1, scancode → KeyEvent (subsystem `input.zig`).
- [x] Začátek **dispatch vrstvy** (`api/sys.zig`), KI enumerace.
- [x] Atomická fronta událostí (spec `input.md`), `dropped` čítač.
- [x] **Runtime testy v QEMU** (`isa-debug-exit`, exit kód) — první běžící runtime
      testy (tick, IDT, fronta událostí); mechanismus spec `verification.md` Krok 4b.
- [x] **Freestanding backtrace** v panic/fault handleru (spec `invariants.md` §1).
- [ ] Metriky do tabulky.

**DoD:** scancody a tickery na serial; dispatch vrstva kompiluje; host testy zelené;
první runtime testy v QEMU zelené (exit kód 0).

### M3 — Graphics

**Cíl:** viditelný text ve framebufferu.

- [x] GOP framebuffer init (Limine), `Framebuffer` struct.
- [x] **Renderer:** `fillRect`, `blit`, `fillScreen` s clippingem (spec `graphics.md`).
- [x] **Embedded bitmap font** + `drawGlyph`, `drawText`.
- [x] Graphics API modul (`api/graphics.zig`) + dispatch.
- [x] **Event loop** `poll() → update() → render()` (spec `input.md`).
- [x] Klávesnice → text na obrazovce (psaní viditelné v QEMU).
- [x] Metriky do tabulky.

**DoD:** píšeš na obrazovku z kódu; testy rendereru (blit clipping) host-zelené.

### M4 — Lua

**Cíl:** interaktivní Lua REPL v kernelu + hot reload.

- [x] Lua 5.4.8 kompilace jako C statická knihovna v `build.zig` (žádný system libc
      dependency pro target).
- [x] `@cImport` Lua hlaviček; `api/runtime.zig` s `RuntimeKind.Lua`.
- [x] Bindings: `gfx.*`, `input.*`, `time.*` (konvence spec `runtime.md` §4).
- [x] `main.lua` **embedded** v binárce, spouštěný při bootu.
- [x] Lua kreslí první snímek ("Hello from Lua"), reaguje na klávesnici.
- [x] **GC tempo:** rozpočet `collectgarbage("step", N)` v každém `update()`, měření
      frame latency p99; případně generační režim (spec `runtime.md` §6).
- [x] **Hot reload:** re-inicializace Lua státu bez restartu (klávesová zkratka F5);
      teardown userdata/callbacků starého státu (spec `runtime.md` §5).
- [x] **Runtime testy Lua bindings** v QEMU (`verification.md` Krok 4b) — reálné
      volání bindingů v kernel kontextu, ne jen host mocky.
- [x] Metriky do tabulky (velikost skočí o Lua, zdokumentovat).

**DoD:** "Hello from Lua" v QEMU, klávesnice funguje z Lua, hot reload funguje, testy
binding marshallingu zelené.

> **Stav:** Lua 5.4.8 běží v kernelu. Otevřeny liby `base`, `coroutine`, `table`,
> `string`, `utf8`, `math` (io/os/package/debug vyřazeny — bez FS, bez dynamic loading,
> integer-only KI). Freestanding libc shim (`libs/lua-5.4/include/` +
> `src/kernel/lua/libc.zig`): string/ctype/snprintf/strtod/pow/acos/asin/atan2 +
> `setjmp`/`longjmp` (asm), deterministické `time`/`clock`, file stubs pro
> `luaL_loadfilex`. Hot reload přes F5. Po startu běží **interaktivní Lua REPL** (banner
> + `> ` prompt, `load`/`pcall`, `print` na obrazovku). **Layout klávesnice** je
> infrastruktura (`input/layout.zig`, US 105+) — binding posílá `char`, Lua nemapuje.
> Koalesce bug v `HeapAllocator` opraven (špatný výpočet `prev` + linkování pohlceného
> bloku) — viz `spec/troubleshooting.md` C17. `grow()` alokuje 4 stránky (16 KB)
> najednou — Lua loadbuffer potřebuje alokace > 4 KB.

### M5 — UI (Shell v Luay)

**Cíl:** použitelný desktop v Luay.

- [x] **Živá transformace — základ:** `gfx.invalidate()` — shell (Lua) si vyžádá re-render
      bez klávesy; `main.lua` deklarativní theme (barvy jako data) se mění živě z REPL.
- [ ] Okna: seznam oken, focus, z-order, drag.
- [ ] Taskbar, launcher, menu — vše jako Lua klienti Graphics API.
- [ ] REPL konzole (`~`) — psaní Lua kódu do běžícího systému.
- [ ] **Živá transformace:** příkaz v Luay okamžitě překreslí prostředí (barvy, tvary)
      bez ztráty oken/obsahu terminalu; **F5** = manuální refresh (spec `runtime.md` §5a).
- [ ] Restart shellu nesmí shodit jádro (error containment, `spec/runtime.md` §5).
- [ ] Metriky do tabulky.

### M6 — Storage

**Cíl:** načítání souborů za běhu.

- [ ] **initfs** z Limine initrd (RAM disk) — load `.lua` / assetů za běhu.
      **Formát: tar** (jednoduchý, streamovatelný, dobře se generuje build-time;
      rozhodnutí z fáze přípravy — implementuje se zde).
- [ ] **Block device driver** — **virtio-blk** (standard QEMU), čtení. Bez block device
      neexistuje žádná persistence; driver je samostatný bod (až pak FS).
- [ ] **Partition table** — **GPT** (standard), čtení; ext2/ext4 i FAT32 na disku potřebují
      partition table. Nikdy vlastní formát.
- [ ] **Perzistence: standardní čtecí formát** — **nikdy vlastní**. Konkrétní výběr
      (FAT32, ext2/ext4, ...) se rozhodne v M6 podle potřeby; FAT32 je jen příklad,
      ne cíl.
- [ ] **Kooperativní čtení:** pomalé FS operace neblokují event loop — kooperativní
      suspendace (spec `kernel-interface.md` §6.2, `timer.md` §3).
- [ ] **Auto-reload na uložení:** uložení `theme.lua`/config souboru → automatické
      překreslení prostředí bez klávesy (spec `runtime.md` §5a spouštěč 2).
- [ ] (Výhledově: ukládání, editor.)

### M7 — Runtime (Wasm)

**Cíl:** izolované aplikace.

- [ ] wasm3 vendored; `Runtime.spawn(.Wasm, ...)`.
- [ ] První `.wasm` aplikace (C/Rust → wasm) kreslící do vlastní surface.
- [ ] Sdílené buffery + present (spec `graphics.md` budoucí cesta).
- [ ] **Preemptivní RR scheduler** pro více tasků (ADR-017) — kritické sekce se
      zakázanou preempcí, žádné locky; `sleepMs` přechází na blokující sleep úkolu
      (`spec/timer.md` §5).
- [ ] **Per-program `lua_State` / instance** po `spawn` — zamrzlý program (nekonečná
      smyčka) už nezamrzne prostředí; preempce + error handler úkolu (spec `runtime.md` §5).
- [ ] **Blokující synchronizační primitiva** (ADR-017): semafor, mutex, event group,
      message queue; **error handler úkolu** (`anyerror!void`).
- [ ] Benchmark wasm vs Lua; metriky do tabulky.

### M8 — Stabilizace

**Cíl:** uhlazený základ pro další vývoj.

- [ ] Audit invariantů (spec `invariants.md`) bod po bodu.
- [ ] Problémové metriky pod cílem; optimalizace podle měření (pravidlo č. 5 v §4 —
      poslední optimalizační průchod před stabilizací).
- [ ] Rozhodnutí o dalším směru: (a) více funkcí, (b) začít oddělovat do Ring 3.
      Pro volbu (b) je **transport KI připravený dopředu** (ADR-018: mailbox IPC,
      comptime dispatch, IRQ routing) — implementuje se až tady, ne dřív.
- [ ] Nové features (zvuk/audio, síť M9+, prohlížeč v Luay) se přidávají podle
      **ADR-020** — jako nové KI moduly na konec enumu, bez úpravy existujících.

---

## 4. Pravidla práce mezi milníky

1. **Každý commit = bootovatelný systém** (ADR-016). Rozbitý boot se opravuje okamžitě,
   nikdy "až za pár commitů".
2. **Metriky se měří a zapisují** na konci každého milníku (`tools/bench.sh`).
3. **Žádná nová feature bez zelené pipeline** (spec `verification.md`).
4. **Architektura se dál neoptimalizuje na papíře.** Další zlepšení vycházejí z reálných
   zkušeností z implementace (boot, text, Lua VM), ne z hypotetických scénářů.
5. **Po každém milníku (M-cast) proběhne optimalizační průchod.** Před zahájením dalšího
   milníku se zkontrolují metriky proti cílům a provedou se cílené optimalizace:
   - velikost binárky (sekce `.text`/`.rodata`, mrtvý kód, kompilační flagy C zdrojů),
   - hot spoty (render pipeline, heap allocator, event loop) — měřit, ne odhadovat,
   - benchmark **před a po** (`tools/bench.sh`, runtime test `render throughput`),
   - žádná optimalizace bez zapsané hodnoty do tabulky v §2.
   Výsledky se zapíší do tabulky metrik a případně do `spec/troubleshooting.md`.
6. Změny rozhraní (KI) = nový ADR v `spec/adr/`, nikdy tichá úprava.
7. **Dokumentace se aktualizuje s každou feature.** Feature bez zapsaného metrikového
   řádku *a* bez aktualizace příslušné specifikace není hotová (viz `spec/verification.md`
   DoD).

---

## 5. Sekvenční diagram prvního bootu (M0 → M4)

```
QEMU → BIOS/UEFI → Limine (bootloader)
   → handoff (long mode, mem map, GOP fb, serial)
   → kernel.main (M0)
   → mem.init / pfa (M1)
   → cpu.init: IDT, timer, PS/2 (M2)
   → fb.init, renderer, font (M3)
   → runtime.init: Lua state (M4)
   → main.lua běží → "Hello from Lua"
   → event loop: poll() → update() → render()
```
