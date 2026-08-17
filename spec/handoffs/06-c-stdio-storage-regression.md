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
| 7 | Reprodukce na čistém klonu (pin Zig 0.16.0, HEAD `69182a6` = H6 stav, `testDofile` vypnutý) | `file.remove` **prošel** (3/3 `ok`), pak **hang** (timeout) po „create/lookup/remove across a multi-block directory" | H6 stav se přesně nereprodukuje → silně environment/layout citlivé |
| 8 | Stejná reprodukce na parent commitu `85b4029` („atrapy" — bez stdio kódu) | **taky FAIL**, ale jiné symptomy: `FAIL: read returns the theme config table` + `FAIL: file.remove frees a multi-block file`, pak hang na stejném multi-block místě | i bez stdio kódu selhává → potvrzuje layout citlivost, ne stdio logiku |
| 9 | Velikostní delta mezi `c486dee` (parent wasm) a `cd8d33f` (stdio WIP) | ~1,2 KiB | odpovídá ~100 řádkům stdio kódu |
| 10 | Lokální reprodukce (stejný stroj, HEAD layout i layout s debug printy) | PASS opakovaně (5× + smyčka 6× + 12× + 8× paralelně) | na tomto stroji se bug **nereprodukuje deterministicky**; ~30 běhů = 1× flake „RUNTIME TESTS FAIL" (detail FAILu nezachycen) → flake ~3 %, příliš řídký na bisection |
| 11 | Vynucený TCG (`-accel tcg`, bez KVM) | PASS (48 s) | závislost na stroji NENÍ rozdíl KVM vs TCG |
| 12 | 4× paralelní QEMU instance (host zátěž → silnější timing jitter) | všechny PASS | jitter zátěže flake nevyvolá spolehlivě |
| 13 | `e2fsck -fn` na image po úspěšném běhu | jen očekávané non-POSIX artefakty zápisové cesty (uvolněné inody nejsou nulované → „orphaned inodes"; `i_blocks` se nepíše; rozdíly bitmap odpovídají stale inode záznamům) — žádná korupce, kterou by kernel sám viděl | zápisová cesta při PASS disk viditelně nekontaminuje; e2fsck nálezy nejsou kořenová příčina |

## 4. Hypotézy

1. **Transientní korupce sektorových dat v DMA cestě** (nová, nejpravděpodobnější).
   Čtení/čtení-čtení občas vrátí nekonzistentní data (race dokončení used-ringu vs
   zápis data/status, nebo zaházené DMA buffer), čímž ext2 dostane cizí bajty —
   `file.open` → `NotFound`, přečtení starého obsahu („theme config table"),
   případně hang, když se korumpuje záznam, po kterém procházka adresářů/bloků
   zacyklí. Flake ~3 % na lokálu + deterministické (byť různé) projevy na jiných
   strojích = timing-sensitive, layout-sensitive (stejný duch jako C50/C51).
   - Potvrzení: `diag_verify_reads` v `drivers/virtio.zig` (viz níže) — VIO-DIFF /
     VIO-STALE přesně určí sektor a typ (transientní vs nedoručená data).
   - Vyvrácení: ani při vypnutém ověřování (a víc bězích) nikdy VIO-DIFF.
2. **Hraniční rozložení binárky** (dříve #1, oslabeno): přidání stdio kódu posune
   layout a rozbije něco v `storage.open`/`ext2.find` — ale parent commit bez stdio
   kódu selhává na jiném stroji stejně, takže stdio kód není příčina, jen posouvá
   „která operace se rozbije".
   - Potvrzení: dummy kód stejné velikosti / porovnání disassembly (viz artefakty).
   - Vyvrácení: PASS nezávisle na velikosti kódu (lokálně se skutečně chová takto).
3. **Vedlejší efekt importů** (`sys`/`api_storage` nově v `libc.zig`): prakticky
   vyloučeno — parent bez stdio selhává taky.
4. **Linker/relokace ve stylu C51**: C51 měl jasnou self-referential příčinu; tady
   se nic podobného neukázalo.

### Vyloučené příčiny (kódový audit 2026-08-17)

- **SMP race heapu/PFA**: AP jen `sti; hlt` (smp.zig `apEntry`), scheduler je
  BSP-only, ISR běží s maskovaným IF (interrupt gate) → heap operace (chráněné
  `irq.begin`) jsou atomické vůči preempci. Spawnuté tasky (taskA/taskB…) před
  storage testy parkují (čtou `task_stop` / hlt) a nedělají I/O.
- **PFA overlap s kernelem/initrd**: bitmapa startuje 0xFF a uvolňují se jen
  `.usable` záznamy; `.executable_and_modules` a `.bootloader_reclaimable`
  zůstávají alokované (pfa.zig `init`), takže rostoucí kernel nic nepřepíše.
- **Překlad DMA adres**: heap roste v přímém mapování (phys = virt − hhdm platí
  pro každou stránku heapu), deskriptory ukazují správně.
- **Truncace Limine memory mapy**: clamp na 64 záznamů je bezpečným směrem
  (drop = méně volné RAM, nikdy volné přes rezervované regiony).
- **Přetečení input queue**: SPSC bounded queue, přetečení = drop (ne spin/hang).
- **virtio ring bounds**: `next_desc` cykluje tak, že `head+2` nikdy nepřekročí
  `size`; `size` je omezeno na `queue_max` (256) → desc/avail/used tabulky se
  vejdou do jedné stránky.
- **e2fsck nálezy**: viz §3 řádek 13 — artefakty non-POSIX zápisu, ne korupce
  viditelná kernelu.

### Diagnostický instrument (běh na selhávajícím stroji)

`src/kernel/drivers/virtio.zig` nese záměrně malou, gateovanou diagnostiku:
`diag_verify_reads` (default `false`). Když se zapne, **každé** čtení se provede
dvakrát a kopie se porovnají, a DMA buffer se předplní sentinelem `0xAA`:

- kopie se liší → `VIO-DIFF sector=<N>` (transientní DMA korupce / race dokončení),
- buffer zůstal celý `0xAA` → `VIO-STALE sector=<N>` (used-ring se posunul bez
  zápisu dat device).

Postup na selhávajícím stroji (jeden běh):

```bash
sed -i 's/const diag_verify_reads: bool = false/const diag_verify_reads: bool = true/' src/kernel/drivers/virtio.zig
zig build
tools/make-test-disk.sh /tmp/aster-h6.img
QEMU_TEST_TIMEOUT=150 QEMU_TEST_DISK=/tmp/aster-h6.img tools/qemu-test.sh
# poslat celý serial log
```

Interpretace:
- `VIO-DIFF` → potvrzeno: sektor N se přečte nekonzistentně → race v DMA cestě
  (toto je hledaný mechanismus; fix = pořadí used-ring/data/status + fence).
- `VIO-STALE` → used-ring odbaven bez doručených dat → stejná rodina.
- žádný VIO řádek, ale přesto FAIL → korupce není v read-cestě; zkontrolovat
  image po běhu `e2fsck -fn` (extrahovaná partition, `dd ... skip=2048`), případně
  zkoumat zápisovou cestu (writeBlock/DMA write).

## 5. Reprodukce

Od čistého stavu (HEAD `69182a6` — H6 stav s funkčním stdio, `testDofile` vypnutý):

1. `zig build`
2. `tools/make-test-disk.sh /tmp/aster-h6.img`
3. `QEMU_TEST_TIMEOUT=150 QEMU_TEST_DISK=/tmp/aster-h6.img tools/qemu-test.sh`
4. Všimni si `file.remove returned 'open-failed'` v serial výstupu.

Pro kontrolu PASS: nahradit v `src/kernel/libc.zig` stdio implementaci atrapami
(`fopen` vrací `null`, `fread` vrací `0` atd.) a kroky 1–3 opakovat → exit 99.

> **Pozor:** bug je citlivý na prostředí. Na stroji s jinými verzemi
> QEMU/mke2fs/parted než u původní reprodukce se projev jiný (file.remove prošel,
> hang později; nebo i parent commit bez stdio selhává s jinými symptomy). Když se
> daný stroj nereprodukuje přesně, je potřeba nejdřív vyloučit divergenci testovacího
> disku (`mke2fs -E offset=` vs GPT partition, `udevadm` varování) a až pak hodnotit
> PASS/FAIL.

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
- Diagnostika DMA: `src/kernel/drivers/virtio.zig` (`diag_verify_reads`,
  `dmaRead`, `logVio`, `readSector` s dvojitým čtením — viz §4).
- Debug printy v pracovním tree (z předchozího šetření, před commitem smazat):
  `libc.zig` („STDIO fopen"), `mem/pfa.zig` (MEM-DBG), `mem/heap.zig` (HEAP-GROW),
  `runtime_test.zig` („file.remove returned" v osmi testech).

## 7. Omezení a podezřelé okolnosti

- Dofile/loadfile NEJSOU v commitnutém stavu — je to rozpracovaná práce na
  standardizaci Lua („dofile má fungovat jako stock Lua"), která narazila na tento
  blokující bug. C stdio vrstva je to, co má `dofile`/`loadfile` (a případně
  `io.*`) zpřístupnit.
- Chování na původním stroji je deterministické (FAIL opakovaně), ne flaky. **Na
  jiném stroji se reprodukce liší** (viz §3 řádky 7–8): HEAD `69182a6` tam
  file.remove prošel a běh hangl později; parent `85b4029` selhal s jinými
  symptomy a hangl na stejném místě. Různé toolchainy „přehazují", která storage
  operace se rozbije — typické pro layout-sensitive bug rodiny C50/C51.
- Host toolchainy (QEMU/mke2fs/parted) nejsou byte-for-byte identické s původní
  reprodukcí. `make-test-disk.sh` vytváří GPT + ext2 s `-E offset=`; varování
  `udevadm: not found` při tvorbě disku je kandidát na divergenci diskového
  layoutu — vyloučit nejdřív.
- Kandidáti na porovnání disassembly (Debug symboly, obě verze):
  `api.storage.dispatch`, `ext2.find`/superblock-read cesta, `.bss` globály
  `handles` (storage) a `stdio_table` (libc) — ověřit, jestli se některý neposune
  vůči fixní hranici (start PFA, disk read buffer).

## 8. Ideální výsledek

Funkční C stdio vrstva (dofile/loadfile standardně čte soubory z disku přes KI
storage) s **plným PASS**: `qemu-test` exit 99 vč. `testDofile` (dofile načte a
spustí soubor z disku) a `testFileRemove`. Bez regrese `file.open`. Lekce (když
se najde příčina) → `spec/troubleshooting.md`.
