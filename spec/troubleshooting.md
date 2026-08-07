# Troubleshooting — Známé pasti a lekce

**Status:** V1 (draft).
**Účel:** zachycovat chyby, které stály čas při vývoji, aby se nemusely znovu objevovat.
Dokument je **druhý mozek** — piš lekci ve chvíli, kdy je problém vyřešený, ne zpětně.

---

## Pravidla použití

- **Co sem patří:** ne-obvious chyba, která si vyžádala více než pár minut hledání, změnu
  toolchainu, nečekané chování build systému, past v protokolu. Opakování běžné chyby (syntaxe)
  sem nepatří.
- **Struktura záznamu:** `Symptom → Příčina → Řešení → Ověřit`.
- **Kdy:** ve chvíli vyřešení, ne na konci milníku. DoD (`spec/verification.md`) to vyžaduje.
- **Jazyk:** česky (dokumentace), kód/identifikátory anglicky.

---

## 1. Zig 0.16 — build API

Build API se mezi 0.15 a 0.16 výrazně změnilo. **Nejlepší zdroj je instalovaná std lib
(`/usr/lib/zig/std/Build.zig`, `Build/Step/Run.zig`), ne webové docs** — docs byly
v kontextu zpožděné.

| Záznam | Symptom | Příčina | Řešení | Ověřit |
|--------|---------|---------|--------|--------|
| Z1 | `addExecutable` nezná `root_source_file` | 0.16: executable staví na `root_module` | `b.addExecutable(.{ .root_module = b.createModule(.{ .root_source_file = ... }) })` | `zig build` |
| Z2 | asm clobbers: `: "memory"` = syntax error | 0.16: clobbers jsou struct | `: .{ .memory = true }` | `zig build` |
| Z3 | `var x: volatile T` = syntax error | 0.16: `volatile` je pointer qualifier, ne type qualifier | `@as(*volatile T, @ptrCast(&x))` | build |
| Z4 | naked `_start`: `call symbol` = "undefined label" | inline asm nevidí Zig symboly | `@extern(*const fn...)` + `call *%[target]` | boot |
| Z5 | `export fn` s duplicitním `extern fn` = error | stejné jméno v jednom modulu | jiné jméno + `@export(&impl, .{ .name = "sym" })` | build |
| Z6 | `export var` vyžaduje `extern struct` | automatický layout nemá garantovanou reprezentaci | `pub const S = extern struct { ... }` | build |
| Z7 | `standardOptimizeOption` ignoruje `-Doptimize` | 0.16 používá `--release` flag, ne `-Doptimize` | vlastní `b.option(OptimizeMode, "optimize", ...)` s defaultem `.ReleaseSafe` | `zig build -Doptimize=Debug` |

---

## 2. Limine — boot protokol

| Záznam | Symptom | Příčina | Řešení | Ověřit |
|--------|---------|---------|--------|--------|
| L1 | requests nefungují, kernel neví o framebufferu/hhdm | requesty jako `const` jsou DCE-odstraněné v ReleaseSafe (`comptime { _ = &x; }` nestačí) | `export var` + `extern struct` + `linksection(".limine_requests")` | `readelf -S` má `.limine_requests` |
| L2 | kernel nebootuje v ReleaseSafe s linker.ld, ale v Debug ano | linker script mění layout sekcí jinak per optimize | **linker.ld se nepoužívá** — Zig default layout dává `.limine_requests` jako samostatnou sekci | `zig build -Doptimize=ReleaseSafe` + smoke |
| L3 | #UD (invalid opcode) na `movdqu` hned po bootu | Limine **nezapíná SSE** (CR0.OSFXSR/CR4.OSXMMEXCPT), ale Zig generuje SSE instrukce | `error_tracing = false` v module + `enable_sse()` v `_start` | boot bez #UD |
| L4 | base revision check selhává | Limine zapisuje do request tagu; čtení bez `volatile` optimalizuje kompilátor | číst requesty přes `*volatile` pointer | boot, `base_revision[2] == 0` |
| L5 | requests v pořadí end→start marker | `linksection` do jedné sekce zachovává pořadí deklarací | start_marker, requesty, end_marker v **jednom** souboru ve správném pořadí | `readelf -x .data` |

---

## 3. Build a determinismus (ADR-014)


| Záznam | Symptom | Příčina | Řešení | Ověřit |
|--------|---------|---------|--------|--------|
| D1 | dvakrát build → jiný hash | `.debug_str` sekce obsahuje absolutní cestu do build cache (`/home/.../.zig-cache/...`), která se mění | `strip = optimize != .Debug` v module | `tools/verify-reproducible.sh` |
| D2 | `zig build iso` neprodukuje `zig-out/bin/aster` | iso step nezávisí na install stepu | spustit `zig build` (install) před/po iso; smoke skript buildí iso sám | `zig build && zig build iso` |
| D3 | smoke failuje, ale kernel běží | `find .zig-cache -name '*.iso' \| head -1` vybírá staré ISO z cache | `find ... -printf '%T@ %p\n' \| sort -rn \| head -1` | smoke dvakrát po sobě |

---

## 4. Nástroje (QEMU, xorriso, Limine host tool)

| Záznam | Symptom | Příčina | Řešení | Ověřit |
|--------|---------|---------|--------|--------|
| T1 | xorriso step: "file_hash IsDir" | `addFileArg` na adresář | `addDirectoryArg(iso_dir)` | `zig build iso` |
| T2 | `limine bios-install` FileNotFound | hostitelský `limine` nástroj není v systému | zkompilovat z `libs/limine/tools/limine.c` (cc) v build.zig; argv[0] přes `addFileArg` | `zig build iso` |
| T3 | smoke/bench čekají celý timeout | kernel haltuje, QEMU běží dál | číst serial živě přes FIFO (`-chardev pipe`), ukončit po markeru | smoke za ~3s ne 30s |
| T4 | `bc: příkaz nenalezen` v bench | `bc` není nainstalovaný | `awk "BEGIN { printf ... }"` místo `bc` | `./tools/bench.sh` |

---

## 5. Heap a PFA (M1)

| Záznam | Symptom | Příčina | Řešení | Ověřit |
|--------|---------|---------|--------|--------|
| H1 | host heap test: alokace vrací 170 (0xAA) | `std.mem.Allocator.alloc()` **poisonuje** paměť na `undefined` (0xAA v Debug/ReleaseSafe) — `std/mem/Allocator.zig:299` dělá `@memset(byte_ptr, undefined)` po `rawAlloc`; alloc **negarantuje** zeroed paměť | test nesmí očekávat zeroed data z `alloc`; PFA `allocPage(true)` zeroing ověřovat na úrovni PFA, ne heap | PFA test "allocPage returns first free page, zeroed" |
| H2 | heap test: segfault/crash, stránka má 170 | PFA/bitmapa/ram jsou **lokální proměnné** helperu `setup()`, po `return` zaniknou → dangling pointer; heap držel pointer na PFA uvnitř vraceného structu | alokovat vše v jednom stack frame testu; heap drží PFA **hodnotou** (kopie, bitmap je slice na sdílenou paměť) | `zig build test` |
| H3 | kernel triple fault, `ud2` (panic) v `grow`, stack s 0xaaaaaaaa | `Memory.init` vracel struct, ale `heap.HeapAllocator.init(&pfa_inst)` ukazoval na **lokální `pfa_inst`** v init → dangling pointer po `return` | inicializovat heap přes `&memory.pfa` (pole v structu) + heap drží PFA hodnotou | boot, "heap alloc test: ok" |
| H4 | kernel panic/infinite loop, "free pages" nikdy neskončí | memory map obsahuje **1 TB reserved MMIO** entry (`0xfd00000000`); `highestPage` z něj → bitmapa 34 MB a `totalFreePages` iteruje miliardy stránek | `isRamEntry()` filtruje typy (usable, reclaimable, ...); MMIO/reserved se nepočítají do bitmapy | boot, "free pages: ~130k" |
| H5 | kernel heap alokuje stránku `0x1000` (Limine data) | dangling PFA (H3) → garbage bitmap → alokace z obsazených regionů | H3 fix | boot |
| H6 | framebuffer cache atribut vrací `other` | `readEntry` maskoval `0x000FFFFFFFFFF000`, čímž smazal PAT/PCD/PWT bity | vracet celý entry; maskovat jen při výpočtu adresy child tabulky | boot, "framebuffer cache: wc" |
| H7 | `rdmsr` — "inline assembly allows up to one output value" | Zig 0.16 asm povoluje jeden return output | vícenásobné outputy přes `[_] "={eax}" (var)` operandy (vzor `cpuid` v std) | build |

---

## 6. IDT, APIC, IOAPIC, PS/2 (M2)

| Záznam | Symptom | Příčina | Řešení | Ověřit |
| C1 | lidt způsobí GP/triple fault, kernel ani nezačne | `IdtRegister = extern struct { limit: u16, base: u64 }` má v ABI velikost **16 B** (padding za `u16`), ale `lidt` čte **10 B** — načte base z offsetu 2, kde je padding, ne z offsetu 8 | descriptor držet jako `[10]u8` buffer a vstřelit base na offset 2; nebo `@alignCast` + vědomý layout | boot, IDT load bez GP |
| C2 | `lidt` v ReleaseSafe čte špatný pointer; v Debug OK | operandy `"m"(reg)` nechá kompilátor udělat pointer indirection přes registr, který v ReleaseSafe nemusí být ten, co čekáš; `lidt (%reg)` sám dereferencuje | constrain na `"r"(reg)` a v asm použít `lidt (%[reg])` — předá se *hodnota* adresy | boot, `lidt` OK v ReleaseSafe |
| C3 | APIC timer nestartuje / čte garbage | registry se píší na offsetech 0x320/0x3E0/0x380 (MB), ne 0x32/0x3E/0x38 | konstanty `0x320`, `0x3E0`, `0x380`, `0xB0` | boot, "ticks: 1000/2000..." |
| C4 | #PF při prvním přístupu na APIC/IOAPIC | Limine HHDM **nemapuje MMIO** (APIC 0xFEE00000, IOAPIC 0xFEC00000); kernel adresy jsou na `0xffffffff80000000+`, HHDM na `0xffff800000000000+` — nelze odečítat `hhdm_offset` od adresy kernelu | `page_map.mapPage(phys + hhdm_offset, phys, 0x1A)` s RW+PWT/PCD bity | boot, apic/ioapic bez #PF |
| C5 | ISR stubs: vektor 0x80+ generuje 5B instrukci, rozbije uniformní layout | `pushq $imm8` pro vektor ≥ 0x80 sign-extenduje a assembler vybere 5B `68 imm32` místo 2B `6A imm8` | stubs generovat přes `.byte 0x6a` (vynucený 2B push) + `.byte vector` | `objdump` ISR stubs všech 256 × 9 B |
| C6 | ISR stubs chybí v binárce (fault "no handler") | assembly `.s` soubor se k exe nepřidá, nebo linker DCE-odstraní stubs (nepoužité symboly) | přidat `exe.addAssemblyFile("src/kernel/cpu/isr.s")`; stubs jsou referencované přes `@extern` v `idt.zig`, takže DCE je neodstraní. **NEpoužívat `link_gc_sections = false`** — zruší DCE celé std a nafoukne kernel ~7× (196 KB → 28.8 KB) | `size` kernelu < 100 KB, faults jdou do handlerů |
| C7 | IRQ1 (klávesnice) nikdy nedojde; PIC unmask nepomáhá; poll funguje | v APIC režimu jdou ISA IRQ přes **IOAPIC redirection table**, ne přes PIC; bez zapsaného entry je IRQ1 maskovaný | v `apic.init` mapovat IOAPIC a `enableIsaIrq(1, 0x21)` (GSI = IRQ, entry: vektor, dest=0, unmasked, edge) | QEMU `-d int` ukáže `INT=0x21`; `key a down` po sendkey |
| C8 | po IRQ1 kernel zacyklí/hang, ticker i klávesnice zmrznou | IRQ šel přes IOAPIC→LAPIC, ale handler posílal **PIC EOI**; LAPIC ISR bit zůstává nastavený → po IRET se IRQ okamžitě znovu vyvolá | EOI do **LAPIC** (`writeReg(0xB0, 0)`), ne do PIC | klávesnice funguje, ticker běží dál |
| C9 | klávesnice odpovídá (poll vidí scancode), ale IRQ nedorazí | i8042 config nemá povolený IRQ1 enable (bit 0) + klávesnice není v scan módu | `ps2.init`: config `0x41` (IRQ1 enable + translation) + `0xF4` (enable scanning); handler filtruje ACK `0xFA`/`0xAA`/`0xFF`/`0x00` | `sendkey` → `key a down/up` |
| C10 | debug scancode se píše do serialu, ale event loop nic | scancode v ISR handleru se čte jen když `status & 0x01` (output buffer full) | handler i poll čtou jen přes `ps2_status`; EOI vždy po IRQ | konzistentní `key` zprávy |
| C11 | driver tlačí scancode (0x1E) přímo do fronty/KI | chybějící normalizační vrstva — scancode set-1 ≠ USB HID usage; aplikace by poznala konkrétní HW za hranicí driveru | subsystem `input.zig` (`KeyCode`/`KeyEvent`), driver mapuje scancode → `KeyCode`, fronta nese `KeyEvent` | USB HID by produkoval stejné události bez změny KI |
| C12 | fault handler tiskne `FAULT ENTERED`, ale `std.fmt.bufPrint`/formátovaný výpis se nikdy neobjeví — handler se opakuje | `std.fmt` v ReleaseSafe v fault/IRQ kontextu rekurzivně faultuje (pravděpodobně stack/frame traversal) | fault handler píše **vlastním hex formátováním** (přímé `serial.writeChar`), žádný `std.fmt` v fault kontextu | `ud2` → kompletní `ASTER FAULT` dump |
| C13 | `isa-debug-exit` nedá očekávaný exit kód | QEMU `debugexit` vrací `(val << 1) \| 1` (ne `val`), a `-no-shutdown` potlačí exit | pass = zapsat `0x31` → exit 99, fail = `0x30` → exit 97; bez `-no-shutdown` | `zig build runtime-test -Druntime-tests=true` |

---

## 7. Grafika a event loop (M3)
| Záznam | Symptom | Příčina | Řešení | Ověřit |
| C14 | #GP (vec 0x0d) v renderu/fillRect jen když event loop běží; s breakpointem OK | `isr_common` **ukládal jen callee-saved registry**, `%rax` (caller-saved) nechal zničit — timer IRQ (1 kHz) přeruší render, handler přes `callq handle_isr` přepíše `%rax`, smyčka pak zapisuje na kontaminovanou adresu | `isr_common` push/pop i `%rax`; `InterruptFrame` dostane pole `rax` (na konci, před `vector`) | render běží stabilně, žádný #GP v event loop |
| C15 | framebuffer zápis "nefunguje" (screendump ukazuje starý obsah), ale gdb vidí data v paměti | screendump zachycen uprostřed/po rychlém event loop renderu, nebo z VGA bufferu místo GOP; framebuffer `address` z Limine je **už v hhdm prostoru** (`0xffff8000fd000000`) — přičtení hhdm offsetu podruhé přeteče (safety trap) | psát přímo na `info.address` bez hhdm offsetu; renderovat jen když je stav `dirty`; ověřovat screendump po dostatečné prodlevě | `screendump` ukáže text, žádný fault |
| C16 | text psaný z klávesnice se neobjeví / obrazovka jen černá | event loop renderuje každou iteraci (`fillScreen` + text) — QEMU screendump zachytí stav uprostřed `fillScreen` (černý); nebo konzole není "dirty" | `Console.dirty` flag: render jen při změně stavu; `fillScreen` + `console.render` až tehdy | screendump po stisku klávesy ukáže text |
| C17 | pád #6 (invalid opcode) v `HeapAllocator.rawAlloc` po ~150 alokacích Lua, RIP se mění mezi běhy | **Bug v `coalesce`**: (1) adresa `prev` bloku se počítala z `block.size` (velikost aktuálního bloku) místo z boundary-tag footeru předchozího bloku → trefila náhodnou adresu; (2) po backward merge `rawFree` linkoval **původní pohlcený `block`** místo sloučeného → v free listu dva překrývající se bloky → corrupted struktura → nedeterministický RIP | `coalesce` čte footer předchozího bloku (`prev_footer.size`) a **vrací** sloučený blok; `rawFree` linkuje jen vrácený blok. Dále: `remapFn` používal `@memcpy(dst[0..min], src)` — overlap check ReleaseSafe → `ud2`; oprava explicitními slice stejné délky. Instrumentace (dočasná): magic v `BlockHeader` + `validate()` průchod free listu | Lua alokuje stovky bloků bez pádu; host testy heapu zelené |

---

## 8. PS/2 myš a sdílený i8042 kontrolér (M5)

Myš a klávesnice sdílí **jeden i8042 kontrolér, jeden data port (0x60) a jeden
status registr (0x64)**. Všechny níže uvedené bugy mají kořen v tomto sdílení.
Toto ladění stálo nejvíc času v M5 — čti pečlivě, než se dotkneš `drivers/ps2.zig`.

| Záznam | Symptom | Příčina | Řešení | Ověřit |
|--------|---------|---------|--------|--------|
| C18 | myš "vystřelí" kurzor do rohu obrazovky | **Rozsynchronizovaný 3-bajtový paket** — IRQ12 četl bajty na špatných hranicích (po dropu/strženém bajtu), `dx`/`dy` dostaly garbage hodnoty | První bajt paketu má **vždy bit 3 (0x08)**. Když očekáváš začátek paketu (`mouse_byte_idx == 0`) a bit 3 chybí, přeskoč bajt a realignuj na další (`handleIrq12`) | pomalý pohyb myši, kurzor nedělá skoky |
| C19 | myš se "teleportuje" / obrovské skoky | **8-bit delta přeteklo** — bit 6/7 b0 signalizuje, že `dx`/`dy` je bezvýznamné | `input.decodeMousePacket`: `if (b0 & 0xC0 != 0) return null` (zahoď paket) | rychlý pohyb, žádné teleporty |
| C20 | myš se pohybuje vertikálně obráceně | PS/2 hlásí **+dy jako pohyb nahoru**, ale obrazovka roste dolů | `decodeMousePacket`: `dy = -dy` (invertovat jednou při dekódování; spotřebitelé jen přičítají) | pohyb nahoru = kurzor nahoru |
| C21 | kurzor seká, "zamrzá", text se nevykreslí při psaní | **IRQ1 a IRQ12 sdílí data registr** — IRQ1 handler četl i myší byte jako falešný scancode (a naopak), čímž rozhazoval oba streamy | Každý handler čte data jen když status bit 5 odpovídá: IRQ1 `status & 0x20 == 0`, IRQ12 `status & 0x20 != 0` | klávesnice i myš fungují nezávisle |
| C22 | myš vůbec nedetekována (headless QEMU / HW bez myši) | `initMouse` bezpodmínečně povoloval port 2 a posílal `0xF4` — **bez myši kontrolér podrží příkaz a zablokuje sdílený data registr**, klávesnice zamrzne | Testovat port 2 (`0xA9`) před dotykem; timeout; ACK s bounded waitem — nikdy neviset | headless boot + klávesnice fungují |
| C23 | port-2 test (`0xA9`) vrací `0xFA` (ACK) místo `0x00` | **Starý ACK z klávesnice zůstal ve frontě** (`0xF4` v `initKeyboard` bez konzumace) → test přečetl špatný byte | `initMouse` nejdřív **vyprázdní output buffer**; `initKeyboard` konzumuje ACK explicitně | `0xA9` vrátí `0x00`, myš se zapne |
| C24 | myš/klávesnice se chovají eraticky (nepřesně, zasekaně) i po všech opravách | **i8042 je pomalý** — příkazy posílané back-to-back bez čekání na `status_input_full == 0` se ztrácí/korumpují sdílený config byte | **Každý** zápis do kontroléru přes `sendCommand`/`sendData`, které čekají na input-empty (bounded timeout). Read-modify-write config, ne natvrdo konstantu | stabilní pohyb i psaní |
| C25 | myš neposílá pakety, i když je init OK | Po `0xF4` (streaming) se **nesmí filtrovat bajty 0xFA/0xAA** z datového proudu — to jsou platné hodnoty `dx`/`dy` (250/170). Filtrace rozhazuje paket | ACK se čte jen **synchronně v `mouseCommand()`** při init, nikdy z proudu v `handleIrq12` | plynulý pohyb, žádné zasekávání |
| C26 | kurzor myši fyzicky nedosáhne viditelných okrajů okna | Framebuffer **800×600** se škálováním displeje (150 %/125 %) ne vždy sedí na hostitelský monitor — **QEMU-specifické** (ovlivněno i volbou VGA výstupu v QEMU); na reálném HW se chování liší a musí se ověřit až při bootu z USB | `zig build run`: `-display gtk,zoom-to-fit=on` — škáluje okno, framebuffer i myší souřadnice zůstávají nativní; `resolution: 800x600` v `limine.conf` | okno se vejde na obrazovku, kurzor dojede ke všem hranám |

**Shrnutí pravidel (nejdůležitější meta-lekce z M5):**

1. **PS/2 klávesnice a myš = jeden sdílený kontrolér.** Data port a status registr
   jsou společné. Nikdy nečti byte bez kontroly status bit 5 (0x20), který říká,
   komu patří.
2. **i8042 je pomalý.** Každý zápis do `0x60`/`0x64` musí počkat na
   `status_input_full == 0`. Back-to-back zápisy bez čekání = ztracené/korumpované
   příkazy na sdíleném config byte → eratické chování OBOU zařízení.
3. **Config byte je sdílený** — vždy read-modify-write, nikdy nepřepisuj natvrdo.
4. **Myš po `0xF4` streamuje čistá data** — `0xFA`/`0xAA` jsou platné `dx`/`dy`
   hodnoty, nikdy je nefiltruj z proudu. ACK jen synchronně při init.
5. **Synchronizace paketu** přes bit 3 (0x08) prvního bajtu; overflow delta
   (bit 6/7) zahoď; dy invertuj.
6. **Oddělené fronty** (keyboard vs mouse) — myš nemůže vyhladovět klávesnici.
7. **Kurzor myši = kernel overlay** (ulož/obnov pixely pod kurzorem), ne plný
   render per paket — jinak lag.

---

## 9. Jak předcházet (meta-lekce)

- **Měň jednu věc a ověřuj** — při M0 se střídaly strip/linker.ld/optimize současně, což
  zamlžilo příčiny. Jeden faktor na krok.
- **Po ne-obvious fixu zapiš záznam hned** — kontext vyprchá.
- **Ověřuj na stejném optimize, jako produkce** — Debug boot nepredikuje ReleaseSafe
  (L2, D1). Vždy nakonec `-Doptimize=ReleaseSafe` + smoke.
- **Nový toolchain (Zig major) = revize všech API předpokladů**, ne jen syntaxe.
- **Struct vracený hodnotou + pointer na jeho pole = dangling pointer.** Když `init()`
  vrací struct a vnitřní alokátor drží `&lokální_proměnná` z init, po return ukazuje na
  zaniklý stack frame (H3, H5). Alokátor drží závislost **hodnotou** nebo se struct
  inicializuje na místě.
- **Limine memory map obsahuje obří MMIO regiony** (řádově TB), které nejsou RAM.
  Bitmapa PFA a smyčky přes stránky musí filtrovat typy (H4).
- **APIC režim mění cestu ISA IRQ** — s lokálním APIC jdou legacy přerušení (klávesnice IRQ1,
  timer, atd.) přes **IOAPIC redirection table**, ne přes PIC. PIC remap + unmask nestačí;
  EOI se posílá do LAPIC, ne do PIC (C7, C8).
- **MMIO periferie (APIC/IOAPIC) vyžadují explicitní mapování** — HHDM je mapuje jen když
  bootloader řekne; bez `mapPage` je přístup #PF. Adresy kernelu (`0xffffffff8...`) a HHDM
  (`0xffff8000...`) jsou různé rozsahy, hhdm_offset platí jen pro fyzické mapování (C4).

---

## 10. Nevyřešené problémy → handoff

Problém, který se nepodaří vyřešit v čase (viz `spec/handoff.md` §1), **se nezapisuje do
této tabulky** (ta je jen pro vyřešené lekce). Použije se šablona v `spec/handoff.md` a
záznam jde do `spec/handoffs/`. Když se handoff vyřeší, příčina + řešení se doplní sem
jako běžný záznam a handoff se označí `closed`.
