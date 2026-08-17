# Handoff H6: funkční C stdio vrstva v kernel libc rozbíjí storage (file.open selže)

**Datum:** 2026-08-17
**Status:** open

---

## 1. Symptom

Přidání **funkční C stdio vrstvy** (`fopen`/`fread`/`fclose`/`feof`/`ferror`/`getc`/
`freopen` nad KI storage + `stdio_table` v bss) do `src/kernel/libc.zig` způsobí, že
runtime test `file.remove frees a multi-block file` selže: Lua `file.open("/README")`
vrátí `nil` (README na test disku existuje), takže script skončí `open-failed`.

> Reprodukce:
> ```bash
> zig build
> tools/make-test-disk.sh /tmp/aster-h6.img
> QEMU_TEST_TIMEOUT=150 QEMU_TEST_DISK=/tmp/aster-h6.img tools/qemu-test.sh
> ```
> Očekávaný výstup: `qemu-test: PASS (exit 99)`.
> Skutečný výstup: `qemu-test: FAIL (exit 97)` + `FAIL: file.remove frees a
> multi-block file` + `file.remove returned 'open-failed'` (dočasný debug print
> v testu).

Klíčové pozorování: **`fopen` se v běhu nikdy nevolá** (dočasný debug print ve
`fopen` se neobjevil; test dofile byl vypnutý). Problém tedy NENÍ v logice stdio —
je v tom, že **samotná přítomnost stdio kódu** (importy `sys`+`api_storage` do
`libc.zig`, `stdio_table`, ~100 řádků) mění chování storage při `file.open`.

## 2. Prostředí

| Vrstva | Hodnota |
|---|---|
| Build | `zig build` (ReleaseSafe default) |
| Toolchain | Zig 0.16 (místní `/usr/bin/zig`, CI `/opt/zig`) |
| Runtime | QEMU (`qemu-test.sh`: q35, 512M, `-smp 2`) |
| Disk | `tools/make-test-disk.sh` (16 MiB, GPT + ext2 `^dir_index`) |
| Vlastní kód | HEAD `85b4029` + rozpracovaný working tree (C stdio v libc.zig) |

## 3. Co bylo vyzkoušeno

| # | Pokus | Výsledek | Závěr |
|---|-------|----------|-------|
| 1 | Funkční stdio v `libc.zig` | `qemu-test` FAIL (97), `file.remove returned 'open-failed'` | reprodukováno |
| 2 | Atrapy (původní `fopen` vrací `null` atd., stdio kód odstraněn) | `qemu-test` PASS (99) | rozbíjí to funkční stdio kód |
| 3 | Debug print v `fopen` | print se nikdy neobjevil | `fopen` se nevolá → není to logika stdio |
| 4 | `testDofile()` vypnutý v `runAll` | stále FAIL | není to interference dofile testu |
| 5 | Čerstvý disk (`make-test-disk.sh`) | stále FAIL | není to persistentní/stale disk |
| 6 | Diagnostika scriptu (`pcall(file.remove)`) | bez `remove-err`, vráceno `open-failed` | selhává už `file.open("/README")` (storage.open → ext2.find NotFound) |

## 4. Hypotézy

1. **Hraniční rozložení binárky** (nejpravděpodobnější — stejný duch jako C50/C51).
   Přidání stdio kódu (importy + bss tabulka) posune layout binárky a tím rozbije
   něco v `storage.open`/`ext2.find` při `file.open` — ačkoliv fopen samotný se
   nevolá.
   - Potvrzení: přidat/odebrat *dummy* kód stejné velikosti (bez volání storage)
     a sledovat PASS/FAIL; porovnat disassembly `storage.open`/`ext2.find` mezi
     atrap a funkční verzí.
   - Vyvrácení: PASS nezávisle na velikosti kódu.
2. **Vedlejší efekt importů** (`sys`/`api_storage` nově v `libc.zig`): import sám
   nic neinicializuje, ale stojí za ověření (např. pořadí top-level kódu).
   - Potvrzení: přesunout importy do samostatného modulu / jen deklarovat extern.
   - Vyvrácení: FAIL zůstává i bez importů.
3. **Linker/relokace ve stylu C51**: nový kód změní layout funkcí a nějaká
   relokace se rozbije. C51 ale měl jasnou self-referential příčinu; tady se
   nic podobného neukázalo.
   - Potvrzení: `-d in_asm` QEMU log / porovnání disassembly storage/ext2.

## 5. Reprodukce

Od čistého stavu (HEAD `85b4029` + rozpracovaný working tree s funkčním stdio):

1. `zig build`
2. `tools/make-test-disk.sh /tmp/aster-h6.img`
3. `QEMU_TEST_TIMEOUT=150 QEMU_TEST_DISK=/tmp/aster-h6.img tools/qemu-test.sh`
4. Všimni si `file.remove returned 'open-failed'` v serial výstupu.

Pro kontrolu PASS: nahradit v `src/kernel/libc.zig` stdio implementaci atrapami
(`fopen` vrací `null`, `fread` vrací `0` atd.) a kroky 1–3 opakovat → exit 99.

## 6. Důležité artefakty

- Změna stdio vrstvy: `src/kernel/libc.zig` (sekce „C stdio over the kernel
  storage" — `stdio_table`, `stdioSlot`, `fopen`, `freopen`, `fclose`, `feof`,
  `ferror`, `fread`, `getc`; importy `api/sys.zig` + `api/storage.zig`).
- Test: `src/kernel/runtime_test.zig` (`testDofile` — dočasně vypnutý,
  `// testDofile();`; `testFileRemove` s dočasným debug printem
  `file.remove returned '{s}'`).
- Rozpracovaná wasm Fáze A (souvisí jen kontextově): `src/kernel/wasm/`
  (`cimport.zig`, `wasm.zig`, `inttypes.h`, `endian.h`), `src/kernel/apps/`
  (`hello.zig`, `fault.zig`), změny v `build.zig` a `api/runtime.zig`.

## 7. Omezení a podezřelé okolnosti

- Dofile/loadfile NEJSOU v commitnutém stavu — je to rozpracovaná práce na
  standardizaci Lua („dofile má fungovat jako stock Lua"), která narazila na tento
  blokující bug. C stdio vrstva je to, co má `dofile`/`loadfile` (a případně
  `io.*`) zpřístupnit.
- Zatím nebylo testováno: porovnání velikosti binárky (text/bss) mezi atrap a
  funkční verzí; disassembly `storage.open`/`ext2.find`; `-Doptimize=Debug`.
- Chování je deterministické (FAIL opakovaně), ne flaky.

## 8. Ideální výsledek

Funkční C stdio vrstva (dofile/loadfile standardně čte soubory z disku přes KI
storage) s **plným PASS**: `qemu-test` exit 99 vč. `testDofile` (dofile načte a
spustí soubor z disku) a `testFileRemove`. Bez regrese `file.open`. Lekce (když
se najde příčina) → `spec/troubleshooting.md`.
