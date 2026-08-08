# Handoff H3: QEMU runtime testy s diskem — page fault v reload testu

**Datum:** 2026-08-09
**Status:** open

---

## 1. Symptom

QEMU runtime testy (`tools/qemu-test.sh`) s připojeným testovacím diskem skončí
**page faultem** v runtime testu *"reload from Lua is deferred, state survives"*
(`testLuaTriggeredReload`, 8. test v pořadí) — systém se pak zastaví na `ASTER FAULT`
dumpu, QEMU nevrací exit 99.

> Reprodukce (přesně, kopírovatelné):
> ```bash
> ./tools/make-test-disk.sh /tmp/test-disk.img
> QEMU_TEST_DISK=/tmp/test-disk.img ./tools/qemu-test.sh
> ```
> Očekávaný výstup: `qemu-test: PASS (exit 99)`
> Skutečný výstup: fault + timeout skriptu (`qemu-test: FAIL (exit 124, expected 99)`).

Fault dump (poslední řádky serialu, ANSI odstraněn):

```
reload from Lua is deferred, state survives
ASTER FAULT
 err=0x0000000000000000
 rip=0xffffffff8005686b
 cr2=0xffff80000009f018
 rbp=0xffff80001ff7c050
 bt=0xffffffff8005674a
 bt=0xffffffff8004e561
 bt=0xffffffff8002ced6
 bt=0xffffffff8002cd8e
 bt=0xffffffff8002cd43
 bt=0xffffffff8002e8fe
 bt=0xffffffff80031640
 bt=0xffffffff800313f7
```

## 2. Prostředí

| Vrstva | Hodnota |
|---|---|
| Build | `zig build iso -Druntime-tests=true` (ReleaseSafe) |
| Toolchain | Zig 0.16.0 (pinned), x86_64-freestanding |
| Runtime | QEMU, KVM (`-enable-kvm`), `-M q35 -m 512M`, `-boot order=d` |
| Vlastní kód | commit `cad0273` + **necommitnutý WIP M6.1.5** (runtime_test.zig, qemu-test.sh, ci.yml, tools/make-test-disk.sh, tools/test-disk-root/, ADR-023) |

## 3. Co bylo vyzkoušeno

| # | Pokus | Výsledek | Závěr |
|---|-------|----------|-------|
| 1 | `./tools/qemu-test.sh` **bez** disku | PASS (exit 99), FS test se přeskočí ("no disk attached") | fault je vázán na přítomnost disku |
| 2 | `./tools/qemu-test.sh` s `QEMU_TEST_DISK` | **fault** (opakováno 3×, deterministicky) | reprodukováno |
| 3 | Host unit testy ext2/file API na reálném `mke2fs` obraze (mock BlockDevice, GPT offset 2048) | 89/89 PASS | FS logika + offset jsou v pořádku na hostu |
| 4 | `addr2line` / `llvm-addr2line` na rip/bt adresách (Debug build, offset 0xffffffff80000000 odečten) | `??` + "DWARF error: unknown format content type 8193" / "premature terminator" | Zig 0.16 DWARF není čitelný ani GNU, ani LLVM addr2line — **nelze namapovat adresy na řádky tímto nástrojem** |
| 5 | Kernel stack 16 KiB → 64 KiB + `lookupDir` buffer [64]→[32] (fix předchozího stack-overflow v M6.1.4) | fault přetrvává | není stack overflow (jiný bug) |

## 4. Hypotézy

1. **Heap allocator bug po velkých alokacích z probeStorage.** Bez disku dělá
   `probeStorage` jen malé alokace (`readSector` header/status/data ~1 KB, uvolněno).
   S diskem se poprvé v procesu alokuje velký heap buffer — GPT `discover` alokuje
   entry array (`num_entries × entry_size` = 128 × 128 = **16 KB**, pak free) —
   a navíc `VirtioBlk` si nechá 3 PFA stránky pro queue (leak). Reload (`lua_close` +
   `createState`) pak alokuje hodně heapu; crash na `cr2=0xffff80000009f018` (hhdm
   adresa, neplatné/poškozené mapování nebo use-after-free v heapu).
   - Potvrzení: gdb na `rip`/`cr2`, kontrola heap bloků (boundary tags) po
     `probeStorage`; heap host test s replikací pořadí alokací (velká alloc → free →
     mnoho malých).
   - Vyvrácení: heap testy projdou a fault je jinde.
2. **VirtioBlk/BAR mapování poškozuje paměť.** `VirtioBlk.init` mapuje BAR regiony
   přes `page_map.mapPage` a queue stránky z PFA; tyto stránky se po skončení
   `probeStorage` neuvolní (lokální `blk` zničen, stránky zůstaly). Poškozené/duplicitní
   mapování by mohlo corruptit pozdější alokace.
   - Potvrzení: vypnout `probeStorage` úplně (bez disku fault zmizí — vždy) a postupně
     zapínat (VirtioBlk init / setupQueue / GPT discover) a sledovat, kdy fault nastane.
   - Vyvrácení: fault přetrvává i bez mapování BAR (čistý test).
3. **Reload-specific interakce.** `testLuaTriggeredReload` volá `lua.reload()` →
   `createState` → `openLibraries` → `bindings.register`; fault až při renderu po
   reloadu. Bez disku stejný kód projde.
   - Potvrzení/vyvrácení: pořadí alokací v hypotéze 1.

**Doporučený další krok:** gdb (Debug build, ISO boot) s breakpointem na fault handler
nebo na `rip`; zkontrolovat, jestli `cr2` je heap alokace a jestli heap metadata před
faultem dávají smysl. Alternativně binárně prohledat hypotézu 1 (velká heap alokace
odhalí bug, který malé alokace nemaskují).

## 5. Reprodukce

Od čistého stavu:

```bash
git clone <repo> && cd aster-os && ./tools/install-hooks.sh
# (WIP změny M6.1.5 musí být v commitu — viz prostředí; bez nich nemá
#  qemu-test.sh podporu disku ani runtime FS test)
zig build test          # host testy zelené
./tools/make-test-disk.sh /tmp/test-disk.img
QEMU_TEST_DISK=/tmp/test-disk.img ./tools/qemu-test.sh   # FAULT
QEMU_TEST_DISK= ./tools/qemu-test.sh                      # PASS (kontrola)
```

## 6. Důležité artefakty

- Fault dump: §1 (rip, cr2, bt adresy).
- Debug kernel se symboly: `zig build -Doptimize=Debug` → `zig-out/bin/aster`
  (nm funguje, DWARF nelze číst addr2line — viz §3#4; pro gdb je použitelný).
- Testovací obraz: `tools/make-test-disk.sh` (rootfs v `tools/test-disk-root/`:
  `theme.lua`, `readme.txt`, `apps/hello.lua`).

## 7. Omezení a podezřelé okolnosti

- Fault je **deterministický** (3×), jen s diskem, jen v reload testu (před FS testem).
- Bez disku: runtime testy PASS, FS test se přeskočí.
- `probeStorage` (boot) běží **před** runtime testy — FS listing (`[ OK ] fs ext2` +
  seznam souborů) se objeví, takže mount+čtení v kernelu funguje; fault je v
  pozdějším reloadu.
- addr2line na Zig 0.16 DWARF nefunguje — pro mapování adres použít gdb, ne addr2line.
- `cr2=0xffff80000009f018` — typická hhdm adresa (0xffff8000...), podezření na
  neplatné fyzické mapování.

## 8. Ideální výsledek

- `QEMU_TEST_DISK=/tmp/test-disk.img ./tools/qemu-test.sh` vrací **exit 99**
  (všechny runtime testy PASS včetně nového FS testu mount/lookup/open/read/EOF/invalid).
- Bez disku dál PASS.
- Příčina zapsaná do `spec/troubleshooting.md` (pokud to je ne-obvious lekce) a handoff
  uzavřen (`Status: closed`, §3 doplněný finální řádek).
