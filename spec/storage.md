# Storage — Persistent filesystem (M6/M7.1)

**Status:** V1 (draft). **Navazuje na ADR:** 023 (ext2 backend), 010, 020 (nové KI
moduly na konec), 014 (deterministické obrazy).
**Rozhodnutí:** ADR-023, ADR-020.

---

## 1. Princip

Storage je vrstva mezi **tenkým File API** (KI modul `storage.*`) a fyzickým
diskem. Cílem není POSIX filesystem — je to **persistentní úložiště s non-POSIX
sémantikou** (ADR-023): single-user, žádná práva, žádné hardlinky, žádný namespace
mimo string cesty. Backend (dnes ext2) je **on-disk reprezentace, ne definice
sémantiky** — nikdy se z on-disk formátu neprotahuje POSIX sémantika do kernel API.

```
Lua / UI / runtime
   ↓  file.open / file.read / ... (bindings, spec/runtime.md §4)
storage.zig (api/storage.zig)     ← KI modul, jediný veřejný povrch
   ↓  file.zig (File API — tenký wrapper)
ext2.zig                           ← on-disk formát (ADR-023 subset)
   ↓
gpt.zig                            ← diskové oddíly (PartitionView)
   ↓
block.zig + virtio.zig + pci.zig   ← block device driver (virtio-blk)
```

**Vrstvy:**
- **`api/storage.zig`** — KI modul `storage.*`: handle tabulka, status packing,
  validace vstupu. Jediné místo, které Lua/UI/runtime vidí.
- **`fs/file.zig`** — tenký File API (`open`/`create`/`read`/`write`/`truncate`/
  `delete`/`rename`/`close`) nad backend referencí. Volající nikdy nevidí inode
  čísla, uid/gid, mode bity ani ext2 metadata — backend je nahraditelný detail
  (dnes ext2, TAR/initfs a jiné později). Backend reference je dnes **ext2-
  specifická** (`*ext2.Ext2`, ADR-023 ji zatím nedělá opaque).
- **`fs/ext2.zig`** — ext2 reader/writer nad block device view. Čte a zapisuje
  jen podporovaný subset features (ADR-023 §„Feature subset").
- **`fs/gpt.zig`** — GUID Partition Table parser: objeví oddíly jako
  `block.PartitionView` (offset + délka v sektorech, type GUID).
- **`drivers/block.zig`**, **`drivers/virtio.zig`**, **`drivers/pci.zig`** —
  block device driver: PCI scan → virtio-blk → sektorové čtení/zápis.
- **`fs/tar.zig`** — **initfs** (initrd tar z bootloaderu). Není backend
  persistentního FS — je to read-only zdroj embedded assetů (Lua shell moduly,
  fonty, `hello.wasm`/`fault.wasm`). Viz §6.

**Pořadí na boot path** (`main.zig` `probeStorage`):
`virtio-blk init → setupQueue → readSector(0) → GPT discover → najdi linux-filesystem
oddíl → ext2 init → storage.mount`. Každý krok je volitelný — při selhání se jen
vrátí a systém pokračuje **bez disku** (viz §5).

---

## 2. KI modul `storage` (normativní)

### 2.1 Sub-op čísla (zmrazená — `kernel-interface.md` §4 pravidlo 2)

| Op | Jméno | Význam |
|----|-------|--------|
| 0 | `open` | otevři soubor po absolutní cestě, vrať handle |
| 1 | `read` | čti až `len` bajtů od aktuálního offsetu, offset se posune |
| 2 | `write` | zapisuj na aktuálním offsetu, roste velikost souboru (alokace bloků) |
| 3 | `close` | zavři handle, uvolni slot |
| 4 | `truncate` | nastav velikost souboru (zmenšení = useknutí konce) |
| 5 | `list` | výpis adresáře; záznamy se zabalí do výstupního bufferu |
| 6 | `remove` | smaž soubor po absolutní cestě (uvolní bloky + inode + direntry) |
| 7 | `create` | vytvoř prázdný soubor po absolutní cestě, vrať handle |
| 8 | `rename` | přejmenuj/přesuň po absolutních cestách (stejný inode, žádná kopie) |

### 2.2 Návratová hodnota — výjimka z konvence (normativní)

Většina KI modulů vrací čistý `KiStatus`. **Modul `storage` balí status do horních
32 bitů návratové `u64`** (viz `kernel-interface.md` §3.7, jediná dokumentovaná
výjimka):

- horních 32 bitů = `KiStatus` (Success = 0), dolních 32 = hodnota:
  - `open`/`create` → handle,
  - `read` → počet načtených bajtů (0 = EOF),
  - `write`/`close`/`truncate`/`remove`/`rename` → 0,
  - `list` → počet zapsaných bajtů do výstupního bufferu.
- Volající **kontroluje status z horních 32 bitů**, teprve pak čte hodnotu.
  Bez diskontinuity mezi bajt počtem a chybovým kódem (bajt počty jsou < 2^32,
  `io_cap` = 1 MiB).

### 2.3 Handle model a životnost

- Handles jsou sloty v **pevné tabulce** (`handles[8]`, `handle_max`), index + 1
  je handle id (1..8; 0 je neplatné). Per-modul registry (composition-root výjimka,
  `spec/code-style.md` §1).
- `open`/`create` najdou první volný slot; plná tabulka → `Busy`.
- `close` uvolní slot (znovuotevření téhož souboru = nový handle).
- **Handle není platný přes boot/reload** — po F5 (hot reload shellu) se soubory
  znovu otevírají; teardown programů při reloadu se řeší samostatně
  (`spec/runtime.md` §5).

### 2.4 Argumenty a validace

| Op | args.b / args.c |
|----|-----------------|
| `open` | `args.b` = path pointer, `args.c` = délka |
| `create` | `args.b` = path pointer, `args.c` = délka |
| `read` | `args.b` = `ReadArgs {handle, buf, len}` |
| `write` | `args.b` = `WriteArgs {handle, data, len}` |
| `close` | `args.b` = handle |
| `truncate` | `args.b` = handle, `args.c` = nová velikost |
| `list` | `args.b` = `ListArgs {path, path_len, out, out_cap}` |
| `remove` | `args.b` = path pointer, `args.c` = délka |
| `rename` | `args.b` = `RenameArgs {old_path, old_len, new_path, new_len}` |

- Pointery se validují na hranici KI (`api/validate.zig`): nenulovost + zarovnání.
- Každá délka bufferu se **omezí na `io_cap` = 1 MiB** — volající délka nemůže
  vytvořit absurdní slice (2026-08-15-self-audit).
- Neplatný pointer/handle → `InvalidArgument`; plný handler `Busy`; neplatná cesta
  `NotFound`; zápis na plný disk `NoMemory` (z `OutOfSpace`); `NotAFile`/
  `NotADirectory`/`NameTooLong`/`FileExists` → `InvalidArgument`; I/O chyba
  `IoError`; cokoli neznámé → `NotSupported`.

### 2.5 `list` wire formát

Výstup je posloupnost záznamů `[name_len u8][is_dir u8][name bytes]`; `.`/`..` se
vynechávají. Pořadí: pořadí direntries na disku. Když se záznam nevejde do
`out_cap`, výpis se ukončí (záznamy se netruncují).

---

## 3. Sémantika (non-POSIX)

- **Cesty jsou absolutní stringy** (`/wm/theme.lua`, `/apps/calculator.wasm`),
  interpretované backendem. Žádný relativní namespace, žádné `..` zpracování
  v KI — backend dělá lookup po komponentách.
- **Žádná práva/vlastnictví** — `uid`/`gid`/`mode`/ACL se nečtou a nemapují do
  sémantiky Asteru (single-user). Read-only status některých souborů
  (`/wm/.theme.bak`, `/.repl_history`) je **pravidlo v shellu** (`files.lua`/
  `editor.lua`, shoda na příponu/jméno), ne atribut souboru (`spec/runtime.md`
  §5a.2).
- **Hardlinky nejsou koncept** — víc ext2 odkazů na stejný inode nemusí být
  rozlišitelných objektů.
- **Inode číslo není identita souboru** — je to opaque backend reference.
- **Zápis je non-crash-safe** (ADR-023, M7.1): žádný journal; pořadí
  data-před-metadaty je best-effort. Power loss uprostřed zápisu může nechat
  nekonzistentní metadata (trigger pro ext4 zůstává v ADR-023).
- **Nemapuje se POSIX otevření** — žádné O_APPEND/O_TRUNC atd. `write` píše
  na aktuální offset; nahrazení obsahu se dělá `truncate(0)` + `write`.

---

## 4. Kooperativní čtení (synchronní kontrakt)

KI kontrakt je **synchronní request/reply** (`kernel-interface.md` §6.2): žádné
„přijď později", žádný async. Storage operace ale stojí na pomalém I/O (virtio-blk
DMA read/write, sekundové časy na pomalém médiu). Jak to jde dohromady:

- Diskové operace se provádějí **uvnitř synchronního `dispatch()`** — volající
  (Lua binding) zablokuje, dokud I/O neskončí. To je přípustné, protože kernel je
  **BSP-only + preemptivní RR (ADR-017)**: IRQ (timer) běží i během blokující
  storage operace, takže systém nereaguje na vstup jen po dobu samotného I/O.
- **Žádné alokace v IRQ kontextu** — read/write cesta může alokovat na heapu
  (inode cache buffer, adresářové buffery), ale běží mimo ISR (v syscall kontextu),
  kde alokace povolená je (`spec/invariants.md`).
- Rychlé operace (`close`, `truncate` bez alokace) se vykonají hned; pomalé
  (`read`/`write` s novými bloky) blokují déle, ale vrací kompletní výsledek
  v jednom volání — volající nikdy nedostane „přijď později".

---

## 5. Chování bez disku

Disk je **volitelný** — systém nikdy na disku nezávisí:

- Bez disku / bez GPT / bez linux-filesystem oddílu / při selhání probe:
  `storage.mounted = null` a **každý sub-op vrací `NotFound`** (horních 32 bitů).
  Boot pokračuje, shell běží z initrd.
- Uživatelská konfigurace a soubory: bez disku se editor/file browser otevře,
  ale soubor nelze otevřít/uložit (`open` → NotFound). `/wm/theme.lua` zůstává na
  vestavěných initrd defaultech.
- Persistence: bez disku je vše v initrd **read-only a pomíjivé** (F5/reboot =
  reset na defaulty). Disk je jediné místo, kam se ukládá (M7.1).
- Zápis: **read-write od M7.1** (ADR-023 status update). Bez disku žádný zápis
  neexistuje — není čemu ukládat.

---

## 6. initfs (initrd tar) vs disk

| | initrd (initfs) | Disk (ext2) |
|---|---|---|
| Zdroj | bootloader modul (tar) | fyzický disk (virtio-blk) |
| Obsah | Lua shell moduly, fonty, `hello.wasm`/`fault.wasm` | `/wm/`, `/apps/`, `/README`, `/.trash`, `/.repl_history`, uživatelské soubory |
| Přístup | `fs/tar.zig` (read-only, flat names) | KI `storage.*` (cesty, read-write) |
| Životnost | statická, embedded, deterministická (ADR-014) | persistentní napříč rebooty |
| Role | fallback + defaulty | uživatelská data + aplikace |

- **Oddělené backendy** — initfs není mount do storage namespace; je to separátní
  zdroj pro embedded assety. Název souboru v initrd je **flat** (bez cesty),
  na disku je cesta.
- Spouštění programů: Lua shell se načítá z initrd; wasm aplikace se prioritně
  načítají z disku `/apps/*.wasm` (ADR-027), initrd je jen fallback pro
  `hello`/`fault` (smoke testy, nikdy launcher entry).
- Testovací disk `tools/make-test-disk.sh` stageuje čerstvě buildnutý
  `calculator.wasm` do `/apps/` (build artifact — není součást source-controlled
  fixture stromu `tools/test-disk-root/`).

---

## 7. Testovací obrazy a determinismus (ADR-014)

- Testovací disk se tvoří z hostitelského toolingu (`tools/make-test-disk.sh`),
  ne z vlastního image-builderu (ADR-023): GPT + jedna ext2 partition z kořenového
  stromu `tools/test-disk-root/`.
- **Závazná invokace je kontrakt (ADR-023):**

```bash
parted -s <disk>.img mklabel gpt
parted -s <disk>.img mkpart primary ext2 2048s 100%
mke2fs -q -t ext2 -b 1024 -O ^dir_index -d <rootfs_dir> \
       -E offset=$((2048 * 512)) <disk>.img
```

- `-b 1024` je součást kontraktu, ne detail: bez něj se velikost bloku liší host
  od hosta (ADR-014) a 4096B varianta zavěsí ext2 driver (`spec/troubleshooting.md`
  C54).
- `^dir_index` (HTree off) — reader indexed directory neumí (feature reject).
- Disk image je **bit-identický** napříč hosty/verzemi e2fsprogs (ADR-014 duch);
  runtime testy a CI s tímto diskem běží deterministicky.

---

## 8. Testy

- **Host unit testy:** `tests/fs/gpt_test.zig` (14), `tests/fs/ext2_test.zig`
  (31, vč. write/truncate/create/rename/unlink a multi-block GDT),
  `tests/fs/ext2_fuzz_test.zig` (2), `tests/fs/file_test.zig` (15).
- **Runtime testy (QEMU, s diskem):** mount, lookup, open/read/EOF, invalid path,
  write + readback (M7.1.1), write grow přes alokaci (M7.1.2/3), truncate
  (M7.1.3), KI storage open/read/write/close (M7.1.4), create (M7.1.11),
  unlink (M7.1.9), rename (M7.1.12). `QEMU_TEST_TIMEOUT=90` v CI po pinnutí
  bloku na 1024 B (`spec/troubleshooting.md` C54).
- **Běh bez disku:** smoke/runtime testy bez disku prokazují, že vše funguje
  i s `storage.mounted = null` (každý op → NotFound).

---

## 9. Invarianty

- **Storage je přes KI** — Lua/UI/runtime nikdy nevolají ext2/gpt/virtio přímo
  (Architecture, `kernel-interface.md`).
- **Žádné alokace v IRQ** — read/write cesta běží v syscall kontextu (Performance).
- **Bez disku systém funguje** — disk je rozšíření, ne závislost (Architecture).
- **Deterministické obrazy** — kontrakt `make-test-disk.sh` je ADR-023 (ADR-014).
- **Non-POSIX sémantika se neprotahuje do kernel API** (Architecture, ADR-023).