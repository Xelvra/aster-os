# Self-Audit — 2026-08-15

> **Historický záznam — neupravovat; nálezy se řeší v aktuálních dokumentech.**

Kompletní audit repozitáře Aster OS. HEAD `9588b20` (před začátkem oprav).

**Dynamicky ověřeno:** `zig fmt --check` ✅ · `zig build` (ReleaseSafe) ✅ · `zig build test` 128/128 ✅ · `qemu-smoke` PASS ✅ · `qemu-test` (čerstvý disk) PASS ✅ · `capture-boot --check` OK ✅ · `verify-reproducible.sh` PASS ✅ · `bench` 413 KiB / 390 ms wall / 101 ms kernel ✅.

---

## 1. Executive summary

Nadprůměrně udržovaný alfa prototyp: deterministický build (ADR-014) reálně funguje, boot-log i docs-sync brány jsou vynucené, ADR sada je konzistentní s kódem na klíčových rozhodnutích, testy pokrývají alokátory, ext2/GPT/ACPI parsování, dekódování myši a in-QEMU runtime běží na reálném disku i scheduleru. Git historie (231 commitů, conventional commits) čistá, atomicita dobrá, bootable-commit pravidlo v praxi dodržováno.

**Zásadní problém:** systém se tváří, že "nikdy nespadne" (error containment, `theme.lua:5` "the system never crashes"), ale v default ReleaseSafe buildu existuje **pět jednoduchých, z Lua dosažitelných vstupů, které kernel trvale zhltí (halt)** — out-of-range celočíselné argumenty Lua bindings a nepokryté negativní souřadnice ve framebufferu. Žádný `lua_pcall` to nechytí (nejsou to Lua chyby, ale Zig paniky). `spec/verification.md` slibuje testy adversariálních vstupů, ale žádný neexistuje.

Druhý pilíř: parsování nedůvěryhodného disku (GPT/ext2) má díry umožňující craftovanému disku zapisovat kamkoli a v ReleaseFast přepisovat paměť. ACPI parsování nevaliduje délky a I/O APIC adresu. CI/release nástroje vybírají ISO podle mtime/`head -1` ze 142 souborů v cache — mohou bootnout/publikovat testovací build.

**Top 5 zjištění:**
1. Lua bindings bez range-checku → kernel panic (5 variant) — `gfx.draw_rect(0,0,-1,...)`, `tonumber("1e9999999999")`, `string.format("%.2147483648f",0)`, `file.truncate(h,-1)` → halt.
2. ext2 bitmap OOB + `inodeTableLocation` přetečení na craftovaném superblocku → panic / zápis do paměti (ReleaseFast).
3. GPT partition LBA range se nevaliduje → podtečení hranice → neomezené čtení/zápis sektorů.
4. ACPI délky nevalidované + I/O APIC adresa z MADT bez kontroly → MMIO zápis na libovolnou adresu.
5. CI/release vybírá ISO nesprávně (mtime/`head -1`) + `capture-boot --check` po `qemu-test.sh` může selhat/bootnout špatný build.

---

## 2. Tabulka nálezů

| Závažnost | Oblast | Soubor:řádek | Popis | Doporučení |
|---|---|---|---|---|
| Critical | Lua/KI | `bindings.zig:91,135,400,456` | `@intCast` Lua i64 → užší typ bez range-check → ReleaseSafe panic (halt) | range-check ve `checkInteger`/`makeGfxOp`, vracet nil+chyba |
| Critical | Framebuffer | `framebuffer.zig:148` | `roundRect` negativní roh → `@intCast` panic | klipovat rohy do [0,w/h) před castem |
| Critical | Framebuffer | `framebuffer.zig:191,194-195,210` | `gradientBorder`/`gradRow` negativní x → panic (jediný primitiv bez klipu) | `@max(x,0)` v `gradRow` |
| Critical | Lua libc | `libc.zig:507` | `strtod` exponent i32 přeteče → `tonumber("1e9999999999")` panic | exponent přes u64 saturující |
| Critical | Lua libc | `libc.zig:617` | `vsnprintf` prec i32 přeteče → `string.format("%.2147483648f",0)` panic | prec saturovat (cap ≤64) |
| High | FS | `ext2.zig:160` | `inodeTableLocation` `@intCast(u32)` přeteče na craftovaném `inode_size`/`inodes_per_group` | checked arithmetic / bound před castem |
| High | FS | `ext2.zig:354-379,504-536` | bitmapa OOB při extrémních `blocks_per_group`/`inodes_per_group` (>4096) | reject `bpg/ipg > block_size*8` v init |
| High | FS | `gpt.zig:132-139` + `block.zig:30-39` | LBA range nevalidováno; `first>last` → u64 podtečení → libovolné sektory r/w | validovat `first<=last<=kapacita` |
| High | KI | `storage.zig:143-144,153-154,172-179` | I/O buffer pointery jen non-zero, bez range/alignment checku | `checkPtrMut` + cap délky |
| High | Lua libc | `libc.zig:608-610` | `vsnprintf` width usize wrap → věčný hang (nezachytí budget) | clamp width ≤512 |
| High | Lua libc | `libc.zig:702-711` | `fprintf` čte za 256B buffer | clamp n na buf.len |
| High | Config | `theme.lua:94-106` | sémanticky neplatný config (např. `theme.wm={}`) → nekonečný reload loop, desktop neobnovitelný | validace schématu po pcall + odmítnout persist |
| High | WM | `input.lua:92-119` | hit-test myší iteruje tiling list, ne z-order → overlap překlik na spodní okno | sortovat dle z desc |
| High | ACPI | `acpi.zig:106-116,120-131,141-150` | délky nevalidované (slice `<length`), I/O APIC adresa bez kontroly → MMIO zápis do RAM | validovat délky + adresu (0xFEC0-0xFEC1) |
| High | CI/Release | `release.yml:49`, `ci.yml` | `find|head -1` / mtime výběr ISO → může publikovat runtime-tests ISO | pevná cesta výstupu ISO |
| High | CI | `capture-boot.sh:20` | po `qemu-test.sh` je newest ISO runtime-tests → check selže | řád předem / pevná cesta |
| Medium | Mem | `mem.zig:55-67`, `pfa.zig:86` | bitmapa pod 1 MiB bez guardu (direct map hole, C32) → boot #PF / špatné účetnictví | guard low_memory_end |
| Medium | Mem | `heap.zig:56-61` | heap drží kopii PFA → `free_pages` diverguje (metrika RAM špatně) | držet `*PFA` / sdílený čítač |
| Medium | Mem | `heap.zig:203-217` | backward-coalesce omezen page startem → permanentní fragmentace | vázat na grow-region start |
| Medium | Mem | `page_map.zig:35-44` | walker ignoruje PS bit (huge pages) + OOM píše PTE na direct-map base | vrátit error, odmítnout PS |
| Medium | Sched | `task.zig:190-202` | `cli`/`sti` místo RFLAGS guardu → rozbije invariant ADR-017 | `irq.begin()` |
| Medium | Lua | `lua.zig:264-268` | `lua_gc(GCSTEP)` mimo pcall; OOM → unprotected error → `abort()`/trap | pcall GC nebo panic handler |
| Medium | Lua | `lua.zig:235-241` | chyba v `on_shell_error` leakuje objekt na stacku | deterministicky pop |
| Medium | Editor | `editor.lua:65-84` | `editor_load` mění identitu bufferu před `file.open` → stale obsah pod novou cestou | číst až po úspěšném open |
| Medium | Editor | `files.lua:138-147` | Enter/F4/Super+Z zahodí unsaved změny (porušuje invariant Super+T) | dirty guard |
| Medium | Editor | `editor.lua:236-262` | byte vs codepoint mix v horizontálním scrollu → roztržené UTF-8, špatný kurzor | počítat v codepointech |
| Medium | WM | `input.lua:114-137` | klik na hlavičku floating files = drag + navigace nahoru | gating na `drag==nil` |
| Medium | WM | `input.lua:101-110` vs `wm.lua:395-400` | hit-test křížku nebere ohled na `cb.x > content_end` (zavře i bez kresby) | sdílený helper |
| Medium | WM | `editor.lua:249-264` | fokusovaný řádek se kreslí bez oříznutí → bleeding přes floating okna | slice na max_chars |
| Medium | CI | `ci.yml` | chybí `verify-reproducible.sh`, Debug/ReleaseFast buildy, bezpečnostní scan | přidat |
| Medium | Build | `build.zig` | žádná kontrola Zig verze (ADR-013), tar/xorriso nedeterministické | check verze + deterministický tar |
| Medium | Git | `.git/hooks/pre-push` | instalovaný hook je stale (chybí `sync-docs.sh --check`) | `install-hooks.sh` detekuje drift / `core.hooksPath` |
| Medium | Tools | `qemu-smoke.sh:50-56`, `bench.sh` | FIFO hang když QEMU neexistuje; serial výstup zahozen | kontrola QEMU, tee logu |
| Medium | FS | `gpt.zig:123-126` | alokace 2 GiB z nevalidovaného `num_entries` | cap před alokací |
| Medium | Drivers | `ps2.zig:207-223` | `mouseCommand` rekurze bez omezení ("retry once" ≠ kód) | bounded retry |
| Medium | Drivers | `virtio.zig:162-181,210-213` | neomezená cap-chain chůze / reset wait | bound iterace |
| Medium | Drivers | `virtio.zig:335-341` | used.idx/status_byte nevolatile | volatile/acquire |
| Medium | KI | `api/*` `@enumFromInt` | nevalidovaný op kód → panic (latentní) | switch s else |

### Low/Info (souhrn)

- `heap.zig:110,125` size aritmetika může přetéct; `heap.zig:172-181` align >16 nepodporováno.
- `idt.zig:107-116` backtrace dereferencuje neošetřený rbp; `pfa.zig:65-67` memmap páry předpokládá page-align.
- `cache_attr.zig:22-38` walker nereší 1 GiB PS bit; `heap.zig:45`, `task.zig:101` hlt bez `cli`.
- `ps2.zig:156-158` neomezený drain loop v `initMouse`.
- `gpt.zig:51-74` parseHeader čte 96 B při guardu 92; `gpt.zig:89-91` off-by-one BufferTooSmall.
- `ext2.zig:231-251` sparse soubory čtené jako truncated; `ext2.zig:199-225` jen single-block dirs; `ext2.zig:28,30` mrtvé konstanty.
- `ext2.zig:702-707` block/inode bitmapa v GDT bez bounds-checku.
- `sys.zig:46` Yield vrací neposunutý status; `main.zig:305` komentář "read-only" nepravdivý.
- `tar.zig:30-35` matchname stříhá tečky; `virtio.zig:273-281` readSector nezná kapacitu.
- `bindings.zig:34-42` checkString bez null-guardu; `input.zig:61-68` layout_name bez out_cap.
- `framebuffer.zig:73,96-113,17-27` blit/fillRect i32 a pitch/height bez validace, bpp bez kontroly.
- `boot.zig:34-39,55-57` handoff minimálně validovaný; `boot.zig:43` 64-entry memmap ticho ořezává.
- `runtime.zig:76-77` next_handle wrap; `lua.zig:178` runMain pcall bez instruction budgetu.
- `renderer.zig:46` drawGlyph x+bit i32 overflow; `libc.zig:14,36-41` malloc header bookkeeping.
- `repl.lua` `esc_pending` stale, historie bez capu, `repl_visible` mrtvý stav, `repl_save_history` nevytváří soubor.
- `wm.lua` bar geometrie duplikovaná, `fullscreen_win=nil` mimo exit_fullscreen (3×), `input.lua` launcher geometrie duplikovaná, Super+digit bez boundu, y=bar_h double-hit, magic numbers.
- `spec/code-style.md` vynechává 2 výjimky; `sync-docs.sh` jen timestamp, ne obsah.
- `spec/architecture.md` ADR tabulka do 024, stale repo-struktura, missing editor/files; `spec/kernel-interface.md` chybí Storage; `spec/graphics.md` chybí width/height; `spec/runtime.md` chybí file.*; `spec/timer.md` tvrdí time.sleep_ms; `spec/roadmap.md` 366 vs 371 KiB, target <256 KB; `CHANGELOG` M5 session menu odstraněno, sleepMs "still open" (hotovo); `SECURITY.md` verze 0.6; `README` metrika končí M6 (aktuálně 413 KiB), caption "incl. bootloader" opačně; `boot-log.md` Commit stale; `verification.md` test count stale; `CONTRIBUTING.md` chybí sync/capture příkazy; `hooks/pre-push` komentář o README bloku.

---

## 3. Detailní sekce

### 3.1 Code Review (src/kernel + libs)

- **Paměťová bezpečnost:** alokátory (pfa/heap) na běžných cestách korektní (canary double-free, guardy); díry: PFA bitmapa pod 1 MiB (H3/C32), heap kopie PFA, backward-coalesce fragmentace, `page_map` PS-bit, `@intCast` v `inodeTableLocation`. **Žádný `catch unreachable`/`catch {}`/`TODO`/`FIXME`/zakomentovaný kód** — vynikající disciplína.
- **Parsování nedůvěryhodných vstupů:** ext2/GPT reálné díry (High); fuzz test nenašel 2 kombinované overflow (jednopoložkové mutace, 64 KiB image); ACPI délky nevalidované.
- **Souběh:** SPSC queue bez release/acquire (TSO maskuje), `task.zig` cli/sti místo RFLAGS, XMM save/restore v ISR ověřeno korektně.
- **Error containment:** Lua chyby pcall chytá, ale Zig paniky z Lua vstupů ne (Critical); `lua_gc` mimo pcall = OOM hazard.

### 3.2 Bezpečnostní audit

- **Single-address-space Ring 0** (vlastní design, `SECURITY.md`): jakýkoliv crash = halt celého OS; útočník s libovolným Lua/wasm kódem má plný HW přístup (deklarovaný trade-off, ale **žádný kód nesmí panikovat z uživatelského vstupu** — 5 Critical nálezů to porušuje).
- **Boot chain trust:** žádná krypto verifikace Limine→kernel; kernel konzumuje handoff s minimální validací (`boot.zig` mod.size, memmap type `@enumFromInt`).
- **Config jako kód:** `/wm/theme.lua` hot-reloadovaný při bootu i po uložení — sémanticky neplatný config = nekonečný reload loop (High), range chyby = kernel panic (Critical).
- **Disk jako vstup:** GPT/ext2 craftovaný disk → libovolné sektory r/w (High) — nejreálnější externí vektor.

### 3.3 Dokumentační audit

- **Vysoká kvalita**, ale M7/M7.1 předběhlo dokumentaci: spec README/architecture "M0–M6 approved" (stale), CHANGELOG "sleepMs still open" (implementováno), chybí Storage KI / `file.*` / `width`/`height` v KI spec, session menu v CHANGELOG M5 popisuje odstraněnou funkci, SECURITY.md verze 0.6 vs 0.7, README metrika končí na M6 (362 KiB) bez aktuálního 413 KiB, README caption "incl. bootloader" je opačně, roadmap "opaque backend" kontradikce s ADR-023.
- **EN web (docs/) vs spec:** `spec/code-style.md` vynechává 2 ze 3 výjimek "no global mutable state"; sync brána kontroluje jen timestamps, ne obsah.
- **Invariant "0 kopií framebufferu"** (`spec/invariants.md:60`, `architecture.md:43`) **porušen** Phase 2 `present()` — plný byte-by-byte copy každý frame; spec si vnitřně protiřečí.

### 3.4 Testing & CI/CD

- Testy kvalitní, ale chybí přesně to, co spec slibuje: adversariální/range vstupy (žádný test nevolá bindingy se zápornými/obřími hodnotami — a právě ty panikují), `gradientBorder` negativní x, ACPI `length<36`, GPT obří `num_entries`, PFA `zero=true`, myš 9-bit extrémy, single-indirect fuzz cesty.
- **qemu-smoke ověřuje jen marker `ASTER BOOT OK` vypsaný PŘED `sti` a PŘED first frame** — neověří, že shell renderuje. CI "storage" smoke používá nulovaný disk.
- CI chybí: `verify-reproducible.sh`, Debug/ReleaseFast, security scan, `parted`/`e2fsprogs`.
- **ISO výběr `find|head -1`/mtime ze 142 souborů** → nedeterministický (High).
- `qemu-test`/`qemu-smoke` zahazují serial výstup → CI selhání bez diagnózy.

### 3.5 Build & závislosti

- `build.zig`: default ReleaseSafe, `-Druntime-tests` dobře drátované. Chybí kontrola Zig verze (ADR-013), tar/xorriso nedeterministické (ADR-014 kontroluje jen kernel binárku).
- **Lua 5.4.8** stock nezměněný, stdio/IO libs nekompilované, MIT OK. **Limine 12.5.2** unmodified, BSD-2. `THIRD-PARTY-NOTICES.md` verifikovaně sedí. `.gitattributes` správně.

### 3.6 Roadmap vs. realita

- M0–M6 ✅ fakticky hotové (runtime testy PASS). M7 rozpracované (preemptivní scheduler, instruction budget, ext2 write/create/rename, editor, files, historie, ADR-025).
- Rozpory: viz 3.3.

### 3.7 Git/proces hygiena

- 231 commitů, conventional commits, dobrá atomicita, bootable-commit v praxi dodržováno. Fuzz-fix commity exemplární.
- **Instalovaný pre-push hook je stale** (chybí sync-docs check; `install-hooks.sh` nedetekuje drift).

---

## 4. Prioritizovaný akční seznam

**P0 (okamžitě — uživatelem dosažitelný crash / reálné zneužití):**
1. Range-check všech Lua binding integerů (`makeGfxOp`, `gfxDrawText`, `gfxFillScreen`, `fileRead/Write/Truncate`). + runtime testy s `-1/2^31/2^32/2^63`.
2. Opravit negativní souřadnice v `roundRect` + `gradientBorder`.
3. `strtod` exponent a `vsnprintf` prec/width saturovat; `fprintf` clamp.
4. Validace `theme.lua` schématu po pcall, přerušit reload loop.
5. Zálohovat disk/GPT/ext2 validaci: bpg/ipg caps, `inodeTableLocation` checked math, GPT LBA range + kapacita.

**P1 (brzy):**
6. ACPI délky + I/O APIC adresa validace.
7. ISO výběr na pevnou cestu; serial do logu; `verify-reproducible.sh` do CI; kontrola Zig verze; deterministický tar/ISO.
8. Instalovaný hook refresh.
9. `input.lua` z-order hit-test; close-button `content_end` shoda; editor dirty guard; UTF-8 codepoint scroll.

**P2 (pak):**
10. Dokumentační sync (M7 status, KI Storage/`file.*`, invariant present copy, README metrika, SECURITY verze, CHANGELOG "Removed", roadmap opaque-backend, docs/code-style výjimky).
11. Alokátor: heap drží `*PFA`, backward-coalesce, page_map PS-bit + OOM, PFA low-memory guard.
12. Fuzz rozšířit (indirect paths, mutovaný `readInode`, paired extremes); adversariální testy jako normu.
