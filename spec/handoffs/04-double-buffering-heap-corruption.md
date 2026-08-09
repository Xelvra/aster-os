# Handoff H4: double buffering (Phase 2) — heap corruption with a disk in QEMU runtime tests

**Datum:** 2026-08-09
**Status:** closed (ISR stub `isr_common` ukládal jen GPR, ne XMM registry — `handleIsrImpl` klaunuje XMM0 přes `movdqu`, takže timer IRQ mezi `movdqu` load/store alloc v kernelMain zničil XMM0 a do arg slotu runAll se zapsala poškozená data; fix XMM save/restore v `isr.s`, viz C33)

---

## 1. Symptom

Během implementace Phase 2 „sdílené buffery + present" (render do offscreen back
bufferu + `present`) se QEMU runtime testy **s připojeným testovacím diskem** chovají
nestabilně: fault (vektor `0xd` #GP nebo `0xe` #PF), jen s diskem. Bez disku celé
runtime testy prochází (`RUNTIME TESTS PASS`).

> Reprodukce:
> ```bash
> ./tools/make-test-disk.sh /tmp/test-disk.img
> QEMU_TEST_DISK=/tmp/test-disk.img ./tools/qemu-test.sh
> ```
> Očekávaný výstup: `qemu-test: PASS (exit 99)`.
> Skutečný výstup: fault (exit 97/124), poslední test před faultem
> „error containment" / „ext2 filesystem on disk (M6.1.5)".

Poslední reprodukovaný fault (Debug build, s diskem, **bez** back bufferu — renderer
kreslí přímo do framebufferu):

```
error containment (lua error)
RELOAD: start / closed / creating / created        (reload prošel!)
ASTER FAULT
 vec=0x000000000000000e
 rip=...
 cr2=...
 bt=... allocBytesWithAlignment (heap alloc)
 bt=... VirtioBlk.readSector
 bt=... gpt.discover
 bt=... runtime_test.testFilesystem
 bt=... runtime_test.runAll
 bt=... main.kernelMain
```

Fault nastává v **`testFilesystem`** (M6.1.5 runtime test) při `gpt.discover` →
`VirtioBlk.readSector` → **heap alokace** — heap je v tu chvíli poškozený předchozími
Lua `reload()` (close_state/createState).

## 2. Prostředí

| Vrstva | Hodnota |
|---|---|
| Build | `zig build iso -Druntime-tests=true` (ReleaseSafe i Debug) |
| Toolchain | Zig 0.16.0, x86_64-freestanding |
| Runtime | QEMU, KVM i TCG, `-M q35 -m 512M` |
| Vlastní kód | aktuální main; změny viz §3 |

## 3. Co bylo vyzkoušeno (a co už je opravené — KOMITNUTO v tomto stavu)

| # | Pokus | Výsledek | Závěr |
|---|-------|----------|-------|
| 1 | `max_pages_per_run` 64 → 1024 (back buffer ~470 stránek) | **Debug triple fault** hned v `Memory.init` (QEMU exit 0, jen 5 řádků boot logu) | `pages_storage: [1024]u64` (8 KiB) uvnitř `PageFrameAllocator` struct se kopíruje na bootloader stack → overflow |
| 2 | **FIX:** `pages_storage` přesunut do globální statické `pages_storage_global` (PFA má `[]u64` slice; jeden PFA, alokace nejsou z IRQ) | Debug bez disku **PASS**, s diskem fault (dál) | stack overflow odstraněn |
| 3 | Diagnostika: fault v `HeapAllocator.coalesce`/`unlink`, `UNLINK block=0xffff80000010f000` (back buffer stránka) | — | **heap free-list dostal blok v back buffer stránkách** |
| 4 | **FIX:** `coalesce` počítal `page_end = page_start + grow_pages*page_size` (4 stránky), ale `grow` alokuje `pages_count` (5+ pro FS heap) → forward merge přečetl data ZA grow regionem (back buffer / framebuffer) jako blok. Do `BlockHeader` přidán `grow_end` (konec grow regionu), forward merge je omezen `next_addr < block.grow_end` | — | heap poškození z merge mimo grow region odstraněno |
| 5 | **Back buffer (Phase 2) dočasně vypnut** (renderer kreslí do framebufferu, `present` nepřipojen) | bez disku PASS; **s diskem fault v `testFilesystem`** | bug 3 je NEZÁVISLÝ na back bufferu |
| 6 | `max_pages_per_run` zpět na 64 (bez back bufferu) | s diskem **stále fault** | bug 3 není z `max_pages`/`pages_storage` |
| 7 | `kernel_stack` (vlastní 64 KiB stack přes RSP switch v `_start`) | fault přetrvává | není stack overflow (tentokrát) |
| 8 | Markery v `lua.reload` | `RELOAD: created` se vypíše (reload projde), fault až v dalším testu | **bug je v heapu poškozeném PŘED `testFilesystem`**, ne přímo v reload kódu |
| 9 | **FIX:** ISR stub `isr_common` ukládal jen GPR (rax..rdi), ne XMM. Kernel běží se SSE povoleným a Zig generuje `movdqu` pro kopie structů (`handleIsrImpl` sám používá `movdqu` pro Event do input_queue). Když APIC timer IRQ dorazí mezi `movdqu 0x270(%rsp),%xmm0` (load alloc) a `movdqu %xmm0,(%rsp)` (store do arg slotu runAll) v kernelMain, ISR klaunuje XMM0, `iretq` obnoví jen GPR → arg slot dostane poškozená data (alloc.ptr=0) → #GP. Potvrzeno GDB+QEMU (watchpoint, single-step, layout-sensitive markery). **Fix:** XMM0–XMM15 save/restore v `isr_common` (256 B pod InterruptFrame, rdi zachycen před subq). S diskem Debug i ReleaseSafe **PASS 3× deterministicky** | bug v ISR, ne v heapu |
| 10 | **FIX (latentní):** ISR stuby pushují vektor přes `push imm8`, který sign-extenduje vektory ≥ 0x80 (spurious 0xFF → `0xFFFFFFFFFFFFFFFF`). Ověřeno, že `jmp isr_common` relaxation nenastala (všech 256 stubů = 9 B). Fix: `frame.vector & 0xFF` v `handleIsrImpl` | sign-extension latentní bug odstraněn |

## 4. Hypotézy

1. **Heap poškození po Lua `reload()` (createState/close_state) — s diskem se to poprvé projeví v `testFilesystem`, který dělá hodně heap alokací (gpt.discover 16 KB + readSector).** Bez disku se `testFilesystem` přeskočí (žádný disk → skip), proto PASS.
   - Co poškozuje heap při `reload`/`createState` a jen s diskem? Rozdíl s diskem: jiné pořadí PFA alokací (FS heap + virtio stránky před Lua) → free-list fragmentace jiná. Podezření na **heap allocator bug** (split/findBlock boundary tagy), který fragmentace s diskem odhalí.
   - Potvrzení: host unit test `tests/mem/heap_test.zig` replikující sekvenci „velká grow (5 stránek) → mnoho malých alloc/free → realloc" a hledající korupci boundary tagů; nebo logovat `rawAlloc`/`findBlock` (blok + tagy) kolem faultu.
2. **`grow_end` fix je neúplný** — backward merge v `coalesce` stále používá `page_start` (stránka bloku) jako spodní hranici, ne `grow_end`. Pro sub-blok na jiné stránce než začátek grow regionu by mohl backward merge číst footer PŘED grow regionem (přes stránky) — i když guard `prev >= page_start` brání čtení mimo stránku bloku, ne mimo grow region.
   - Potvrzení: fault v `coalesce` (backward) při `testFilesystem`; logovat `prev_footer.size` / `prev`.
3. **`testFilesystem` sám** (druhá `VirtioBlk` instance po `probeStorage`) — dvojitá inicializace PCI zařízení, DMA konflikt? Low probability (bez disku skip, ne ověřeno samostatně).
   - Potvrzení: spustit `testFilesystem` bez předchozích reload testů (skip live-theme/reload/error-containment) — pokud PASS, potvrzuje hypotézu 1.

## 5. Reprodukce

Od čistého stavu (tento commit):

```bash
git clone <repo> && cd aster-os && ./tools/install-hooks.sh
zig build test                # host testy zelené
./tools/make-test-disk.sh /tmp/test-disk.img
QEMU_TEST_DISK=/tmp/test-disk.img ./tools/qemu-test.sh   # fault (Debug i ReleaseSafe)
./tools/qemu-test.sh           # bez disku: PASS (kontrola)
```

Pro symbolizaci: `zig build -Doptimize=Debug -Druntime-tests=true` →
`gdb -batch zig-out/bin/aster -ex "info line *<offset>"` (offset = `rip - 0xffffffff80000000`).

## 6. Důležité artefakty

- `spec/troubleshooting.md` — vyřešené lekce (C32 low-memory; sem se po fixu přidá nová).
- Heap kód: `src/kernel/mem/heap.zig` (nový `grow_end` v `BlockHeader`).
- PFA: `src/kernel/mem/pfa.zig` (globální `pages_storage_global`).
- Back buffer (Phase 2): v `src/kernel/main.zig` je **dočasně vypnutý** (renderer kreslí do framebufferu) — viz §3#5; při zapnutí je potřeba i fix z §4.

## 7. Omezení a podezřelé okolnosti

- Bez disku: všechny runtime testy PASS (vč. Lua reloadů) — takže reload sám o sobě nefaultuje, jen s určitou heap fragmentací.
- S diskem: fault deterministicky v `testFilesystem` (heap alloc při `gpt.discover`/`readSector`), nezávisle na back bufferu a `max_pages_per_run`.
- Back buffer (Phase 2) je v pracovním stavu **vypnutý** — render je přímý, present nepřipojen; Phase 2 nelze považovat za hotovou.

## 8. Ideální výsledek

- `QEMU_TEST_DISK=/tmp/test-disk.img ./tools/qemu-test.sh` → **exit 99** (všechny runtime testy vč. FS testu) bez disku i s diskem, Debug i ReleaseSafe.
- **Vrátit back buffer** (Phase 2): renderer do PFA back bufferu + `present` (memcpy back→front), s ověřením, že fault zmizí.
- Vrátit CI krok „In-QEMU runtime tests with a test disk" v `.github/workflows/ci.yml` (dočasně odebrán 2026-08-09, aby CI nebylo červené).
- Lekci (příčina) zapsat do `spec/troubleshooting.md`, handoff uzavřít.

> **Splněno 2026-08-09:** root cause = ISR klaunoval XMM registry (viz §3#9); qemu-test
> s diskem vrací exit 99 (Debug i ReleaseSafe, 3× deterministicky), CI krok s diskem
> vrácen, lekce v `troubleshooting.md` (C33). Back buffer (Phase 2) zůstává záměrně
> vypnutý jako samostatný pending úkol (nevrací se tímto commitem).
