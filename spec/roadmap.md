# Roadmap — Milníky a Kvalita

**Status:** V1 (draft). **Rozhodnutí:** ADR-015, ADR-016.

---

## 1. Dvě roviny sledování

Projekt se řídí **dvěma nezávislými posloupnostmi**:

### 1.1 Milníky (funkcionalita)

```
M0 Boot → M1 Memory → M2 CPU → M3 Graphics → M4 Lua
        → M5 UI → M6 Storage → M7 Runtime → M8 Stabilizace
        → M9 Ekosystém → M10 Adopce
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
| **M5 (měřeno)** | **371 KiB** | **2 MiB**⁴ | **≈ 90 ms**² (TCG) / **≈ 24 ms**⁵ (KVM) | TBD | TBD |
| M5 (cíl) | < 512 KB | ≤ 16 MB | < 40 ms | < 16 ms | TBD |
| **M6 (měřeno)** | **362 KiB** | **2 MiB**⁴ | **≈ 26 ms**⁶ (KVM) | TBD | TBD |
| M6 (cíl) | < 768 KB | ≤ 24 MB | < 50 ms | < 16 ms | TBD |
| M7 | < 1 MB | ≤ 32 MB | < 50 ms | < 16 ms | TBD |
| M8 | TBD | TBD | TBD | TBD | TBD |
| M9 | TBD | TBD | TBD | TBD | TBD |
| M10 | TBD | TBD | TBD | TBD | TBD |

**Definice:**
- **Kernel Entry → First Frame:** doba od Limine handoff (vstup do našeho kódu) po první
  vykreslený snímek. **Toto je primární, reprodukovatelně měřitelná metrika** — firmware
  a inicializace RAM jsou mimo naši kontrolu.
- **Firmware → First Frame:** celá doba od zapnutí QEMU (BIOS/UEFI) po první snímek.
  Měřitelná, ale závisí na emulaci/firmwaru — sledovaná, nikoli cílovaná.
- **Frame latency (p99):** percentil 99 rozložení doby mezi `render()` a `present()`.
  Latence je důležitější než FPS.
- **RAM (idle):** rezidentní paměť systému bez spuštěných aplikací.
  > ⁴ M5: **≈ 2 MiB** (PFA-managed: kernel image + heap + bitmap + stacky; framebuffer je
  > MMIO, ne RAM). Kernel reportuje v boot logu (řádek `[ OK ] memory`); ADR-015 splněno.

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
> ³ M5 rozpad Kernel Entry → First Frame (měřeno 2026-08-08): mem ≈ 9 ms, ps2+apic ≈ 2 ms,
> graphics ≈ 4 ms, **Lua createState ≈ 27 ms**, **Lua load (parse 25 KB shellu) ≈ 35 ms**,
> první render (WM) ≈ 23 ms. QEMU běží **bez KVM** (čistá TCG interpretace), proto je Lua
> interpretace dominantní — **cíl < 40 ms je v QEMU TCG nedosažitelný kvůli emulované Lua
> interpretaci, ne kvůli našemu kódu**. Na reálném HW by se boot vešel do cíle (Lua parser
> a `lua_newstate` běží nativně → mikrosekundy; alokace nejsou bottleneck, ~1071 allocs /
> 157 KB). **Až bude OS kompletně hotový, změří se tato metrika na reálném HW.**
> **KVM cesta (2026-08-08):** pro interaktivní práci a testování WM/myši se používá KVM
> (`zig build run` auto-přidá `-enable-kvm`, když je `/dev/kvm` přístupný; `-Dkvm=false`
> vynutí TCG, `-Dkvm=true` vynutí KVM; nástroje auto-přidají přes `tools/qemu-accel.sh`).
> KVM je bližší reálnému HW (TCG maskuje chyby, např. C28). TCG zůstává rychlý záchyt pro
> automatické testy.
> ⁵ **M5 KVM měření (2026-08-08, `tools/bench.sh` + runtime test):** Kernel Entry → First
> Frame **≈ 20–24 ms** (cíl < 40 ms je pod KVM dosažitelný — potvrzeno, že TCG byl
> bottleneck), render throughput **≈ 32 renders/10 ticks** (vs 3–4 v TCG → TCG ~8–10×
> pomalejší), RAM idle ≈ 2 MiB (pozn. ⁴), kernel image 371 KiB.
> **Render throughput** (M4): `testRenderThroughput` v runtime testech měří plné Lua
> rendery za 10 APIC ticků. Baseline po optimalizaci rendereru: **8–9 renders/10 ticks**
> (před tím 5). **Hodnota je vázaná na zátěž renderu:** 8–9 platí pro M4 shell (REPL
> konzole), M5 full-shell render (celý WM) měří **≈ 3–4 renders/10 ticks** (TCG variabilní,
> přeměřeno 2026-08-08). Pokles 8–9 → 3–4 je zátěž (těžiště: WM kreslí celý desktop), ne
> regrese render pipeline. **Pod KVM (pozn. ⁵) M5 full-shell měří ≈ 32 renders/10 ticks.**
> Při změně render pipeline se číslo nesmí zhoršit **při stejné
> zátěži** bez zdůvodnění.
> ⁶ **M6 měření (2026-08-09, `tools/bench.sh`, KVM):** Kernel Entry → First Frame
> **≈ 26 ms** (cíl < 50 ms ✓), kernel image **362 KiB** (370 840 B, cíl < 768 KB ✓),
> RAM idle ≈ 2 MiB (pozn. ⁴, cíl ≤ 24 MB ✓). **Optimalizační průchod M6 (pravidlo 5):**
> metriky drží cíle beze změn (image 371 → 362 KiB poklesem z dead code), žádná
> optimalizace nebyla nutná; frame latency p99 stále bez měřicího mechanismu (TBD).
> Firmware → First Frame ≈ 3,3 s (BIOS + Limine, mimo náš kód).

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
- [x] **PS/2 klávesnice** — IRQ1, scancode → KeyEvent (subsystem `input/service.zig`).
- [x] Začátek **dispatch vrstvy** (`api/sys.zig`), KI enumerace.
- [x] Atomická fronta událostí (spec `input.md`), `dropped` čítač.
- [x] **Runtime testy v QEMU** (`isa-debug-exit`, exit kód) — první běžící runtime
      testy (tick, IDT, fronta událostí); mechanismus spec `verification.md` Krok 4b.
- [x] **Freestanding backtrace** v panic/fault handleru (spec `invariants.md` §1).
- [x] Metriky do tabulky (M2 28.8 KB, First Frame ≈ 0.5 s — viz §2).

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
- [x] `ui/` moduly **embedded** v binárce (theme, wm, repl, launcher, input, main —
      concatenované do jednoho chunku), spouštěné při bootu.
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
      bez klávesy; `ui/theme.lua` deklarativní theme (barvy jako data) se mění živě z REPL.
- [x] Okna: seznam oken, focus, z-order, drag (tiling + float, Super+Alt+Space).
- [x] Taskbar + launcher — Lua klienti Graphics API (taskbar 35px: launcher, clock,
      workspace kaple, volume/session; launcher se search boxem + filtrováním).
- [x] REPL konzole (`~`) — psaní Lua kódu do běžícího systému (jako okno v shellu).
- [x] **Živá transformace:** příkaz v Luay okamžitě překreslí prostředí (barvy, tvary)
      bez ztráty oken/obsahu terminalu; **F5** = manuální refresh (spec `runtime.md` §5a).
      (REPL příkaz mění theme za běhu bez ztráty oken; bar height se čte živě ze theme —
      runtime test „live theme change"; F5 = hot reload = restart shellu dle §5.)
- [x] Restart shellu nesmí shodit jádro (error containment, `spec/runtime.md` §5;
      runtime test „error containment").
- [x] Metriky do tabulky (bench 2026-08-08: kernel 366 KiB, Kernel Entry → First Frame
      ≈ 90 ms; render throughput ≈ 3–4 renders / 10 ticks — full-shell render, viz pozn. ³).

> **Optimalizační průchod M5 (pravidlo 5 v §4):** proběhl — renderer throughput měřen
> (3–4 TCG / **32 KVM**, pozn. ⁵), Kernel Entry → First Frame měřen pod KVM (≈ 24 ms,
> cíl < 40 ms dosažitelný), RAM idle změřeno (2 MiB, pozn. ⁴), velikost kernelu drží cíl
> < 512 KiB. Zbývá frame latency p99 (měřicí mechanismus zatím není) a měření na reálném
> HW po M8 stabilizaci (pozn. ³).

### M6 — Storage

**Cíl:** načítání souborů za běhu.

- [x] **initfs** z Limine initrd (RAM disk) — load `.lua` / assetů za běhu.
      **Formát: tar** (jednoduchý, streamovatelný, dobře se generuje build-time;
      rozhodnutí z fáze přípravy — implementuje se zde). Shell moduly (`ui/*.lua`) se
      načítají z taru místo `@embedFile` (Limine module request + `src/kernel/fs/tar.zig`).
- [x] **Block device driver** — **virtio-blk** (standard QEMU), čtení. Bez block device
      neexistuje žádná persistence; driver je samostatný bod (až pak FS). Modern
      (capability-based) transport, funguje na transitional (0x1af4:0x1001) i modern-only
      (0x1af4:0x1042) zařízení; boot log `[ OK ] storage virtio-blk`.
- [ ] **Partition table** — **GPT** (standard), čtení; ext2/ext4 i FAT32 na disku potřebují
      partition table. Nikdy vlastní formát.
- [ ] **Perzistence: ext2 read-only** (ADR-023) — **nikdy vlastní formát**. ext2 je jen on-disk
      reprezentace, žádná POSIX sémantika v API (výhrady v ADR-023); feature check odmítá
      nepodporované features; subset je spárován s přesnou `mke2fs -t ext2` invokací
      (ADR-014; pozor na defaultní `dir_index`). FAT32/ext4/EROFS/9P jsou budoucí backendy
      dle triggerů v ADR-023, ne povinný cíl.
- [x] **Kooperativní čtení:** pomalé FS operace neblokují event loop — kooperativní
      suspendace (spec `kernel-interface.md` §6.2, `timer.md` §3). — **uzavřeno principem
      (2026-08-09):** v M6 se FS čte výhradně mimo event loop (boot probe + runtime testy),
      žádné pomalé čtení neběží uvnitř `update()`/`render()` — event loop nemá co blokovat.
      Plná kooperativní suspendace (deadline fronta, resume) se implementuje s tasky
      v **M7** (ADR-017 scheduler); viz `kernel-interface.md` §6.2.
- [ ] **Auto-reload na uložení:** uložení `theme.lua`/config souboru → automatické
      překreslení prostředí bez klávesy (spec `runtime.md` §5a spouštěč 2).
- [ ] (Výhledově: ukládání, editor.)
      > **Poznámka (2026-08-08):** uložení nastavení (`theme.lua` apod.) nepůjde vyzkoušet,
      > dokud disk neumí zapisovat — ext2 je read-only, testovatelnost auto-reloadu je
      > vázaná na výhledové ukládání.

#### M6.1 — Persistence foundation (ADR-023)

- [x] **M6.1.1 Block device API:** stabilní rozhraní + **virtio-blk** (čtení sektorů); FS kód
      nezávisí na konkrétním driveru. *Exit: deterministické čtení bloků z disku.* —
      **hotovo:** `src/kernel/drivers/pci.zig` + `virtio.zig`, čte sektor 0 (verifikováno
      magic bajty), boot log `[ OK ] storage virtio-blk` jen když je disk přítomen.
      Lokálně se disk připojí přes `zig build run -Ddisk=disk.img`.
- [x] **M6.1.2 GPT partition discovery:** oddíly jako block-device views, nezávislé na FS.
      *Exit: nalezení cílového oddílu a čtení jeho sektorů.* — **hotovo:**
      `drivers/block.zig` (BlockDevice + PartitionView), `gpt.discover()` (čte header + entry
      array z disku, vrací oddíly jako views), `virtio.asBlockDevice()`; boot log `[ OK ] gpt
      N partition(s)` s diskem. QEMU boot order opraven na CD (`-boot order=d`) — GPT disk
      s protective MBR by jinak zablokoval boot. Host testy s mock BlockDevice.
- [x] **M6.1.3 ext2 mount (read-only):** superblock, block groups, bitmapy (validace), inode
      table, inode lookup, directory entries, data (direct + nutné indirect bloky); validace
      feature flags + **reject**. *Exit: mount host-created ext2 image + výpis souborů.* —
      **hotovo:** `ext2.zig` přepsán na `PartitionView` (čtení z disku), `readFile` (direct +
      single indirect), `find()`; feature subset opraven dle reálného `mke2fs -t ext2`
      (`filetype` = incompat 0x2, `dir_index` = compat 0x20 → reject); boot log
      `[ OK ] fs ext2` + výpis kořenového adresáře. Ověřeno na obraze
      `mke2fs -t ext2 -O ^dir_index` + GPT.
- [x] **M6.1.4 Tenké Aster File API:** `open` / `read` / `close`, opaque reference. **Ne:**
      inode čísla, uid/gid, mode bity, ACL, hardlink sémantiku, ext2 metadata. *Exit: runtime
      čte ext2 soubor, aniž ví, že ext2 existuje.* — **hotovo:** `fs/file.zig`
      (`File.open/read/close`, `fileSize`, `eof`; backend reference opaque), `ext2.readAt`
      (čtení od offsetu); boot log `  file <obsah>` z `theme.lua` na disku. Fix: kernel stack
      16 KiB → 64 KiB (16.9 KiB dir-entry buffer přetekl 16 KiB stack).
- [x] **M6.1.5 Integrace:** persistentní FS vedle initfs (oddělené backendy); deterministické
      testovací obrazy z host toolingu; QEMU runtime testy (mount, lookup, open, read, EOF,
      invalid path); dokumentace feature subsetu + přesné `mke2fs` flagy. *Exit: viz diagram
      níže.* — **hotovo:** `tools/make-test-disk.sh` (deterministický GPT+ext2 obraz),
      QEMU runtime test „ext2 filesystem on disk", CI krok s diskem, ADR-023 (feature subset +
      přesná invokace). **Bug z pořadí:** PFA alokoval low-memory stránky, které hhdm nemapuje
      → fault; fix `low_memory_end` (C32, H3 closed).

**M6.1 — doplňkové úkoly (teď):**

- [x] **M6.1.6 CI job s diskem:** qemu-smoke s `-drive ... -device virtio-blk-pci` + marker
      `[ OK ] storage`. Dnes CI nikdy netestuje storage — cap-walk bug by CI bez disku
      nikdy nechytilo. — **hotovo:** `tools/qemu-smoke.sh` podporuje `SMOKE_DISK` /
      `SMOKE_MARKER` (ANSI-strip + fixed-string grep), CI má krok „Storage boot smoke test".
- [x] **M6.1.7 Host unit testy GPT parseru:** čistá funkce nad `[]u8` (vzor `tests/mem/`). —
      **hotovo:** `src/kernel/fs/gpt.zig` (parseHeader + parseEntries, CRC32 validace, bez
      alokací) + `tests/fs/gpt_test.zig` (10 testů).
- [x] **M6.1.8 Host unit testy ext2 parseru:** superblock / features / inode / dir traversal. —
      **hotovo:** `src/kernel/fs/ext2.zig` (read-only reader: superblock validace, feature
      reject per ADR-023, inode lookup, dir traversal; žádné alokace) + `tests/fs/ext2_test.zig`
      (14 testů). Data/indirect bloky zůstávají M6.1.3.
- [x] **M6.1.9 Rozhodnout Lua `dbg` lib teď:** otevřít `luaopen_debug` jako `dbg`
      (`dbg.traceback()`), vyhnout se kolizi s KI modulem `debug`. Později to rozbije
      skripty. — **hotovo:** vlastní `dbg` lib (jen `traceback`) v `lua.zig`
      (`openDbg`/`dbgTraceback`); stock `luaopen_debug` nelze — `debug.debug` čte stdin.
      Runtime test „lua dbg lib (M6.1.9)" + `spec/debugging.md` §5 aktualizováno.
- [x] **M6.1.10 README quickstart:** `zig build run` jako první blok hned po Status. —
      **hotovo:** Quick start přesunut hned za Status (před Prerequisites), obsahuje i
      `-Ddisk=disk.img`.
- [x] **M6.1.11 Release/tag + prebuilt ISO workflow:** „stáhnu a spustím", ne „buildím z git". —
      **hotovo:** `.github/workflows/release.yml` — na tag `v*` spustí plnou verifikaci
      (build, host testy, smoke, runtime testy s diskem), a teprve při zelené publikuje
      `aster.iso` jako release asset (`gh` CLI, žádná third-party akce). — **Release je
      odložen (2026-08-09):** v alfě bez konzumenta nedává smysl; workflow zůstává
      připravený a spustí se tagem, až bude reálná poptávka (ukázka, milestone, M10).
- [ ] **M6.1.12 CI na Windows/macOS:** Zig je multiplatformní, build.zig by měl běžet.

```text
GPT disk image → GPT → ext2 partition → Aster FS backend → open/read/close → runtime
```

### Fáze 2 — hranice M6.1/M7

Rozhodnutí a přesuny mezi M6.1 a M7 (zapsáno 2026-08-08). Cíl: design a přesuny, které
se musí vyřešit **před** spuštěním dalších features, ne až na konci stabilizace (M8).

- [x] **Multi-layout klávesnice (design teď):** `input/layout.zig` přestane být hardcode
      US 105+; zavedou se **KL registry** — layout jako registrovaná mapovací tabulka
      (`KeyCode` × modifikátory → `char`/akce), přepínatelná za běhu. Design se dělá
      teď, než přibude cokoliv dalšího (Wasm aplikace, další runtimes). Rozšíření KI
      (`input.set_layout`) = nový ADR.
      *Exit: přepnutí layoutu za běhu (US ↔ CZ) na stejném řetězci scancodes, bez restartu.* —
      **hotovo:** ADR-024, `layout.zig` = KL registry (US default + CZ QWERTZ, ASCII
      fallback), KI `input.set_layout` / `layout_name` (InputOp 8/9), host testy přepnutí.
- [ ] **Sdílené buffery + present přesunuté z M7 dopředu (render quality):** tearing/flicker
      se řeší **před stabilizací (M8)**, ne na jejím konci. Render do vlastní offscreen
      surface + `present` do framebufferu (původní M7 položka, přesun viz M7 níže).
      *Exit: dvoubufferový present bez tearingu; zapíše se frame latency p99 (§2).*
- [x] **USB HID — ROZHODNUTO (2026-08-09): USB BUDE.** Bez USB není reálný hardware
      (PS/2 je mrtvé), takže USB HID stack je závazek — otázka není „zda", ale „kdy".
      Otevřené zůstává jen **umístění**: (a) USB HID stack dřív (~M6.3/M7.x), nebo
      (b) M10 = „QEMU + legacy HW (PS/2)" a USB HID jako samostatný milník.
      *Exit: zapsané rozhodnutí s dopadem na M10.* —
      **hotovo:** USB je potvrzený cíl; umístění se vybere při plánování M7/M10.

### M7 — Runtime (Wasm)

**Cíl:** izolované aplikace.

- [ ] wasm3 vendored; `Runtime.spawn(.Wasm, ...)`.
- [ ] První `.wasm` aplikace (C/Rust → wasm) kreslící do vlastní surface.
- ~~Sdílené buffery + present~~ — přesunuto do Fáze 2 (render quality před stabilizací).
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
- [ ] Nové features (zvuk/audio, síť M9, prohlížeč v Luay) se přidávají podle
      **ADR-020** — jako nové KI moduly na konec enumu, bez úpravy existujících.

---

### M9 — Ekosystém (Network, Audio, Browser, WASI)

**Cíl:** otevřít systém širšímu ekosystému aplikací.

- [ ] **Síť (M9, ADR-022):** KI modul `net.*` — virtio-net driver + ARP/IPv4/ICMP/UDP;
      parser bez faultu na cizím vstupu, síť defaultně vypnutá, fuzz testy
      (bezpečnostní brzda z `non-goals.md` řešena ADR-022).
- [ ] **Audio:** nový KI modul `sound.*` (ADR-020).
- [ ] **Prohlížeč v Luay:** klient Graphics/Input/Net API — žádný kernel-specifický kód
      (ADR-020).
- [ ] **WASI vrstva:** mapování WASI syscallů na KI pro cizí wasm aplikace
      (`runtime.md` §7.1) — začíná podmnožinou (stdout, argv, filesystem), ne plná WASI.

### M10 — Adopce (real hardware, image, docs, komunita)

**Cíl:** aby si systém mohl spustit a přispět i někdo mimo autora.

- [ ] **Důkaz ADR-018 (mailbox transport):** před plnou adopcí (stabilní ABI) se
      demonstruje slib „mikrojádro bez přepisu aplikací" — **jeden KI modul** přes
      mailbox IPC (Ring 3 transport; implementace se rozjíždí v M8, položka (b)) se
      spuštěnou existující aplikací **bez změny aplikačního API**. Důkaz, ne deklarace.
- [ ] **Boot na reálném hardware** — **navazuje na rozhodnutí o USB HID (Fáze 2)**:
      buď s USB stackem dřív (~M6.3/M7.x), nebo jako „QEMU + legacy HW (PS/2)".
      Měření metrik na reálném HW uzavře pozn. ³ v §2.
- [ ] **Instalovatelný image** (boot z disku, ne jen ISO v QEMU).
- [ ] **Dokumentace pro přispěvatele a anglická vrstva:** CONTRIBUTING (hotovo),
      pokračující anglická vrstva v `docs/` (web) — průběžně, **není podmínka M10**;
      viz jazyková strategie v `spec/README.md`.
- [ ] **Adopce:** stabilní ABI, další features dle ADR-020 na základě zpětné vazby.

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
   → ui/main.lua běží (concatenované ui/ moduly) → "Hello from Lua"
   → event loop: poll() → update() → render()
```
