# ADR-023 — Persistence: ext2 backend, non-POSIX sémantika, tenké rozhraní

**Status:** Accepted
**Datum:** 2026-08-08

> **Status update (2026-08-16):** „zpočátku read-only" platilo pro M6. Od **M7.1**
> je ext2 backend **read-write** — `write`, `truncate`, `create`, `remove`,
> `rename` (non-crash-safe, bez journalu; viz `roadmap.md` M7.1). Zbytek ADR-023
> (on-disk reprezentace, non-POSIX sémantika, tenké rozhraní, nikdy vlastní
> formát) beze změny.

## Rozhodnutí

M6 adoptuje **ext2 jako první persistentní filesystem backend**, zpočátku **read-only**
(od M7.1 read-write, viz status update výše).
ext2 je pouze **on-disk reprezentace** — nedefinuje sémantiku souborů, identitu, namespace,
permissions ani bezpečnostní model Aster OS. Rozhraní mezi Aster File API a backendem je tenké
(`open` / `read` / `close`); **nikdy vlastní on-disk formát** (navazuje na ADR-010).

> **M6 status: ext2-specific adapter.** Veřejný File API je dnes typovaný na
> `*const ext2.Ext2` (`src/kernel/fs/file.zig`) — backend reference **není** zatím opaque.
> Toto je vědomé: s jediným backendem by backend-neutral interface byl předčasná
> abstrakce. **Backend abstraction je budoucí práce, ne součást M6 veřejného kontraktu.**
> Až přibude druhý filesystem backend (TAR pro initfs, 9P, ...), zavedou se skutečné
> společné operace (`open`/`read`/`close`) jako backend interface — podle toho, co ten
> druhý backend reálně vyžaduje, ne podle spekulace (viz „Budoucí triggery“).

## Odůvodnění

Aster filesystem především **čte** — journal (ext4) je mechanismus, který M6 nepotřebuje.
Hostitelské prostředí je Linux: `mke2fs` produkuje deterministické obrazy (ADR-014) bez
vlastního image-builderu. Aster není POSIX systém, proto se POSIX sémantika nesmí z on-disk
formátu protáhnout do kernel API. Dveře zůstávají otevřené **stabilním rozhraním**, ne
katalogem driverů.

Alternativy: **FAT32** (interoperabilita, ale LFN/8.3 komplikace — backend až při reálné
potřebě), **ext4** (extenty + journal — až pro crash-safe zápis), **EROFS/SquashFS**
(read-only + komprese — kandidát pro systémový image, ne pro persistentní data),
**9P/virtio-9p** (není formát, ale vysoce hodnotná dev integrace: hostitelská složka
v Asteru), **NILFS2** (log-structured, nika — nízká hodnota pro read-first),
**Btrfs/CoW** (snapshoty, integrita — odloženo na dobu zápisu), **bcachefs/ZFS** (jen
watchlist). Existence kandidátů není závazek je implementovat.

## Non-POSIX omezení

- **Inode číslo není identita Aster souboru** — je to opaque backend reference.
- `uid`, `gid`, `mode`, ACL a související metadata se **nečtou ani nemapují** do sémantiky
  Asteru (single-user, kernel nemá bezpečnostní hranici založenou na POSIX oprávněních).
- Cesty jsou **stringy interpretované backendem**, ne nutně POSIX namespace zakořeněný v `/`.
- **Hardlinky nejsou koncept na úrovni Asteru** — více ext2 odkazů na stejný inode nemusí být
  rozlišitelných objektů.
- Užitečná metadata v M6: **jméno, data, velikost**, případně timestamp. Vše ostatní zůstává
  implementační detail, dokud ho explicitně nevyžaduje nějaký požadavek.

## Feature subset + image builder

- Podporovaný subset ext2 features je **explicitní a dokumentovaný**; mount **odmítá
  nepodporované features** (feature check na `feature_ro_compat` / `feature_incompat` bity),
  nikdy je neinterpretuje částečně.
- Subset je **spárován s přesnou `mke2fs -t ext2` invokací** (ADR-014 — build nemá vlastní
  image-builder). Konkrétní past: **`dir_index` (HTree) je defaultně zapnuté i u `-t ext2`** —
  buď reader podporuje indexed directory, nebo builder použije `-O ^dir_index`.
  (`sparse_super` reader nezajímá — zálohy group descriptorů se pro čtení nepotřebují.)

### Podporovaný subset (implementováno M6.1.3–M6.1.5, `src/kernel/fs/ext2.zig`)

| Features | Bity | Stav |
|---|---|---|
| `filetype` (incompat) | 0x0002 | podporováno |
| `ext_attr` (compat) | 0x0008 | podporováno (xattr se nečtou) |
| `resize_inode` (compat) | 0x0010 | podporováno |
| `sparse_super` (ro_compat) | 0x0001 | podporováno |
| `large_file` (ro_compat) | 0x0002 | podporováno |
| **`dir_index` (compat)** | **0x0020** | **reject — HTree se nečte** |
| cokoli neznámé | — | **reject** |

### Přesná invokace (testovací obrazy, `tools/make-test-disk.sh`)

```bash
parted -s <disk>.img mklabel gpt
parted -s <disk>.img mkpart primary ext2 2048s 100%
mke2fs -t ext2 -O ^dir_index -d <rootfs_dir> -E offset=$((2048 * 512)) <disk>.img
```

- Čtenář dat: direct bloky + single indirect (`i_block[12]`); double/triple indirect se
  odmítají (`UnsupportedIndirect`).

## Rozhraní (hranice)

```text
Aster File API
    ├── open(path)
    ├── read(handle, ...)
    └── close(handle)
             │
             ▼
      ext2 backend (M6: specifický adapter, ne opaque interface)
             │
             ▼
        Block Device API
             │
        virtio-blk
```

V M6 **nevzniká** generický VFS subsystém (mount tabulky, cross-fs cesty) ani bohatý File
object model (identity/capabilities) — tenký povrch `open/read/close` vychází
z reálných konzumentů (KI File API, Lua shell), ne ze spekulace. Stejně tak nevzniká
backend-neutral interface: M6 má jeden backend, takže File API je ext2-specific adapter
(rozhodnutí výše).

## Důsledky

- M6.1 (rozpad v `roadmap.md`): Block Device API + virtio-blk → GPT → ext2 mount (read-only)
  → tenké Aster File API → integrace + deterministické testovací obrazy.
- **Ne v M6:** journal, ACL, extended attributes, sparse optimalizace, POSIX
  permissions jako bezpečnostní model, exotické ext2 feature flagy. **Zápis se
  implementuje v M7.1** (rozhodnutí 2026-08-12, non-crash-safe, data-před-metadaty
  best-effort; viz `roadmap.md` M7.1). **Vytváření souborů (`ext2.create`,
  M7.1.11):** alokace inode (bitmapa, přeskočí rezervované pod `first_ino`),
  init inode a zápis direntry do rodiče (reuse mrtvého slotu / zkrácení posledního
  záznamu, rec_len 4-aligned jako mke2fs). Adresář musí mít volné místo v bloku 0
  (stejné omezení jako `readDir`/`removeDirEntry`); selhání po alokaci inode
  nerollbackuje (best-effort jako `unlink`).
- initfs (TAR) a persistentní FS zůstávají **oddělené backendy**.
- Pozice backendů: **TAR** = boot/initfs, **ext2** = persistentní data, **9P** = dev
  integrace (mimo M6.1), výhledově **EROFS** = systémový image, **FAT32** = interoperability,
  **ext4** = crash-safe zápis.

## Budoucí triggery (kdy backend přehodnotit)

- **FAT32:** interoperabilita s Windows / removable media.
- **ext4:** crash-safe persistentní zápis.
- **EROFS/SquashFS:** komprimovaný immutable systémový image.
- **9P (virtio-9p):** hostitelská složka v Asteru — dev workflow.
- **Btrfs / jiný CoW:** snapshoty, integrita dat.

## Související

- ADR-010 (žádný FS do M6), ADR-014 (deterministický build), ADR-016 (bootovatelný commit)
- `spec/roadmap.md` (M6, M6.1), `spec/non-goals.md` („nikdy vlastní formát“)
