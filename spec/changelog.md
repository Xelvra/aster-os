# Changelog

Veškeré významné změny v tomto projektu budou dokumentovány v tomto souboru.

Formát vychází ze standardu [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
a tento projekt dodržuje [Sémantické verzování](https://semver.org/spec/v2.0.0.html).

Číslo verze odpovídá milníku projektu (0.0.0 = M0 Boot, 0.7.0 = M7 Runtime).
Novější verze jsou nahoře.

---

## [0.7.0-alpha.1] — Milestone M7 — Runtime (v běhu)

Tato verze sleduje milník navazující na dokončené M6 Storage. Zatím žádné
přírůstky.

---

## [0.6.0] — Milestone M6 — Storage

### Added

* **Block device driver — virtio-blk:** Moderní (capability-based) PCI transport,
  vyjednání VIRTIO_F_VERSION_1, split virtqueue a čtení sektorů. Funguje na
  transitional i modern-only zařízení QEMU; boot log získá `[ OK ] storage
  virtio-blk`, když je připojen disk.
* **initfs — shell z tar initrd:** Moduly UI (`ui/*.lua`) se balí do taru, Limine
  je načte jako initrd modul a kernel je čte za běhu místo `@embedFile`.
* **Persistentní filesystem (ADR-023):** ext2 read-only jako první persistentní
  backend — pouze on-disk reprezentace, žádné POSIX sémantiky v API, stabilní
  rozhraní `open/read/close`, dveře otevřené pro FAT32, EROFS, 9P a ext4.
* **GPT partition discovery:** Oddíly se stávají block-device views (sektor
  oddílu mapuje na sektor disku), nezávislé na souborovém systému.
* **ext2 mount read-only + tenké Aster File API:** Validace superblocku/features
  (neznámé bity i `dir_index` odmítnuty), inode lookup, traversal adresářů,
  čtení dat přes direct + single-indirect bloky; `open`/`read`/`close` nad opaque
  backend referencí — volající nikdy nevidí ext2 metadata.
* **Testovací infrastruktura storage:** Deterministický testovací disk
  (`tools/make-test-disk.sh`, GPT + ext2 z `mke2fs -t ext2 -O ^dir_index`),
  CI smoke test s diskem, QEMU runtime testy (mount/lookup/open/read/EOF/invalid
  path) a volba `zig build run -Ddisk=disk.img`.
* **Lua knihovna `dbg`:** Lua debug knihovna se otevírá jako `dbg`
  (`dbg.traceback()`), protože jméno `debug` drží KI modul.
* **Boot log jako důkaz práce:** Stylizovaný barevný boot log (`/-\STER OS`,
  statusové řádky, boot sekvence) + capture tool, který ověřuje, že zaznamenaný
  boot nikdy nezastarává (CI + pre-push hook).
* **KVM akcelerace:** `zig build run` automaticky detekuje `/dev/kvm` — KVM je
  blíže reálnému hardwaru než TCG, TCG zůstává rychlá cesta pro automatické testy.
* **Dev nástroj pro changelog:** `tools/generate-changelog.sh` — jedním příkazem
  vygeneruje celou historii commitů (viz sekce Dev tools níže).
* **Release workflow:** `.github/workflows/release.yml` — na tag `v*` spustí plnou
  verifikaci a teprve při zelené publikuje `aster.iso` jako release asset.

### Fixed

* **Statická kontrola kódu:** Deduplikace I/O helperů, odstranění mrtvého kódu,
  propagace chyb místo prázdných `catch {}`, ochrana před přetečením descriptor
  tabulky ve virtio.
* **Ladění:** Přepsán debugging guide — ověřený GDB workflow (ISO + higher-half
  breakpointy), co funguje a co ne pro embedded Lua.
* **Přetečení kernel stacku:** Buffer 16,9 KiB pro directory entries přetekl
  16 KiB ISR stack při lookup adresáře; stack zvětšen na 64 KiB a buffer zmenšen.
* **Page fault v low memory (handoff H3):** PFA alokoval rámce pod 1 MiB, které
  bootloaderova hhdm direct map nemapuje (memory map je hlásí usable, ale page
  table nemá záznam) — heap tam umístěné bloky faultovaly při prvním dotyku.
  PFA nyní pod 1 MiB nealokuje nikdy.

---

## [0.5.0-alpha.1] — Milestone M5 — UI (desktop shell)

### Added

* **Desktopové prostředí & Okenní manažer:** Dlaždicové (tiling) i plovoucí okna,
  klávesové zkratky v Hyprland stylu, Noctalia stavová lišta, launcher
  s hledáním, přepínání pracovních ploch, fullscreen, togglesplit a hot reload UI
  (F5).
* **Živá transformace („config je kód"):** `gfx.invalidate()` překreslí prostředí
  bez stisku klávesy; `theme` tabulka je data — změna barvy se projeví okamžitě
  za běhu.
* **PS/2 myš:** 3-bajtové pakety, plynulý kernel kurzor (vykresluje jen pointer),
  nezávislá fronta myši, robustní detekce zařízení.
* **Error containment:** Chyba Lua skriptu je odchycena v `pcall`, shell se
  hot-reloadne — desktop se zotaví bez pádu jádra.
* **Systémový monitor (sysmon):** KI modul vyčítá reálnou RAM z page frame
  alokátoru a zobrazuje živě used/total/percent.
* **Session menu:** Lock (fullscreen overlay), Logout (reload shellu), Reboot
  (i8042 reset) — přes nový KI modul `power`.

### Fixed

* **Zamrzání vstupu:** Vyřešeno souběžné pohybování myší a psaní — oddělené fronty,
  ošetření sdíleného i8042 řadiče (input-empty, read-modify-write config,
  stale ACK).
* **Desynchronizace myši:** Resync paketu na start bitu 3, odmítnutí přetečených
  delta, nefiltrování platných datových bajtů 0xFA/0xAA.
* **Use-after-free reloadu:** `runtime.reload()` z menu zavíral `lua_State`
  uprostřed volání — reload je nyní odložen mimo Lua call frame.

---

## [0.4.0-alpha.1] — Milestone M4 — Lua runtime

### Added

* **Lua 5.4.8 v jádře:** Embedded interpreter (27 `.c` souborů) s freestanding
  libc shim — běh skriptů přímo v kernelu, žádná závislost na hostitelském OS.
* **Interaktivní REPL:** Po bootu se spustí Lua konzole — psaní kódu, Enter
  spustí, `print()` píše na obrazovku; řádkové editace a historie příkazů.
* **Lua bindings:** `gfx.*`, `input.next_event`, `time.ticks`, `sysmon.*`
  s přísnou typovou validací (floats odmítnuty); shell posílá hotový `char`.
* **Hot reload (F5):** Změna UI skriptu se projeví bez restartu systému.
* **Rozložení klávesnice:** Infrastruktura `input/layout.zig` (US 105+) — mapa
  `KeyCode`+shift/ctrl na znak, numpad, rozšířené klávesy, Alt/AltGr vrstva.

### Fixed

* **Shift release:** 0xAA je break scancode shiftu, ne self-test — `shift_pressed`
  už nezůstává „přidržený".
* **Heap alokátor:** Oprava coalescingu (předchozí + pohlcený blok), remapFn
  overlap a růst v souvislých blocích.

---

## [0.3.0-alpha.1] — Milestone M3 — Graphics

### Added

* **Framebuffer:** Limine GOP obalen do `Framebuffer` (base, šířka/výška, pitch,
  bpp, barevné shifty).
* **Vykreslovací engine:** `drawRect`, `blit`, `fillScreen`, `drawGlyph`,
  `drawText` s clippingem — bez heap alokace na render cestě.
* **Vestavěné VGA písmo (8×16):** Bitmap font (public domain) s `?` fallbackem.
* **Graphics API v KI:** `api/graphics.zig` s `GraphicsOp` 0–5 napojené na
  `sys.dispatch`.
* **Text na obrazovce:** Klávesnice → ASCII se shiftem; konzole s wrapem, scroll,
  backspace a kurzorem; psaní viditelné v QEMU.

### Fixed

* **ISR korupce registru:** `isr_common` ukládá/obnovuje `%rax` — timer IRQ
  přerušil render uprostřed a přepsal live registr.

---

## [0.2.0-alpha.1] — Milestone M2 — CPU

### Added

* **GDT/IDT:** 256 uniformních ISR stubů, fault policy, `lidt` přes
  deskriptorový buffer.
* **Local APIC timer (1 kHz):** Periodický tick, LAPIC EOI, SVR init (APIC
  enable + spurious vector 0xFF ignorován bez EOI).
* **IOAPIC:** Mapování 0xFEC00000 a naprogramování IRQ1 → vektor 0x21 pro ISA
  IRQ doručení v APIC režimu.
* **Vstupní subsystém:** Hardware-neutrální `KeyCode`/`KeyEvent` — driver je jen
  producent, aplikace nikdy nevidí scancody; USB HID může mapovat na stejný
  `KeyCode` bez změny KI.
* **KI dispatch vrstva:** `api/sys.zig` — `Syscall`/`KiStatus`, `Debug.write`,
  self-test při bootu.
* **Fault policy + backtrace:** `ASTER FAULT` dump (vec, err, rip, cr2, rbp)
  s freestanding frame-pointer backtrace.
* **Runtime testy v QEMU:** In-kernel testy ukončují QEMU přes `isa-debug-exit`
  (pass = exit 99, fail = exit 97).

### Fixed

* **PIC 8259 remap:** Do vektorů 0x20–0x2F (legacy fallback; aktivní ISA IRQ
  běží přes IOAPIC).
* **Velikost kernelu:** Odstraněn `link_gc_sections = false`, který kernel
  nafoukl 7× (196 KB → 28.8 KB).

---

## [0.1.0-alpha.1] — Milestone M1 — Memory

### Added

* **Bitmap Page Frame Allocator:** 4 KiB stránky, 1 bit na stránku,
  deterministická first-free alokace, zeroing na vyžádání, OOM jako chyba (nikdy
  panic).
* **First-fit heap alokátor:** Boundary tags, coalescing, dynamický růst z PFA —
  implementuje `std.mem.Allocator`.
* **Boot výpis paměti:** RAM layout (usable bytes, free pages) + heap alokátor
  self-test.
* **Cache atribut framebufferu:** Ověřeno z PTE + PAT MSR, že Limine mapuje
  framebuffer jako **WC** (žádné riziko frame latency).

---

## [0.0.0-alpha.1] — Milestone M0 — Boot

### Added

* **Základní architektura OS:** Kompletní architektonická specifikace jádra
  a systému v Zigu (spec/).
* **Bootování jádra přes Limine:** Funkční start v x86_64 long-mode přes
  bootloader Limine v emulátoru QEMU, serial marker `ASTER BOOT OK`.
* **Deterministický build:** Stejný commit + stejný Zig = identický hash binárky
  (ADR-014); verifikováno `tools/verify-reproducible.sh`.
* **Sériový ovladač & diagnostika:** Sériový výstup pro logování + infrastruktura
  pro troubleshooting.
* **Základní nástroje:** `zig build` (boot/iso/test), `tools/qemu-smoke.sh`,
  `tools/bench.sh`; MIT license; anglický README pro veřejné repo.

---

## Dev tools

**Changelog se generuje automaticky z historie commitů — žádné ruční psaní.**

### Jak vygenerovat aktuální CHANGELOG

1. **Jednorázové nastavení aliasu (v terminálu):**
   ```bash
   git config alias.changelog '!bash tools/generate-changelog.sh'
   ```

2. **Vygenerování changelogu:**
   ```bash
   git changelog
   ```

   Příkaz vytvoří/přepíše `CHANGELOG.md` aktuálním přehledem všech commitů.

### Alternativní použití skriptu

```bash
tools/generate-changelog.sh --log     # vytiskne celý log na stdout (bez zápisu)
tools/generate-changelog.sh --help    # nápověda
```

### Proč takto

* **Vždy aktuální:** Každý si changelog vygeneruje jedním příkazem přesně ve
  chvíli, kdy ho potřebuje.
* **Žádné merge konflikty:** Vývojáři si nebudou navzájem přepisovat soubor při
  merge requestech.
* **Čistý repozitář:** Verzovaný `CHANGELOG.md` je agregovaný přehled (co systém
  umí), plná historie commitů je dostupná jedním příkazem.
