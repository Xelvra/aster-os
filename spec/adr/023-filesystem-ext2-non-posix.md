# ADR-023 — Persistence: ext2 backend, non-POSIX sémantika, tenké rozhraní

**Status:** Accepted
**Datum:** 2026-08-08

## Rozhodnutí

M6 adoptuje **ext2 jako první persistentní filesystem backend**, zpočátku **read-only**.
ext2 je pouze **on-disk reprezentace** — nedefinuje sémantiku souborů, identitu, namespace,
permissions ani bezpečnostní model Asteru. Rozhraní mezi Aster File API a backendem je tenké
a stabilní (`open` / `read` / `close` + opaque backend reference); **nikdy vlastní on-disk
formát** (navazuje na ADR-010).

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

## Rozhraní (hranice)

```text
Aster file API
    ├── open(path)
    ├── read(handle, ...)
    └── close(handle)
             │
             ▼
      backend reference (opaque)
             │
             ▼
      filesystem backend (ext2 / tar / ...)
             │
             ▼
        Block Device API
             │
        virtio-blk
```

Backend reference je pro volající opaque; backend je nahraditelný bez změny Block Device API
a vyšších vrstev. V M6 **nevzniká** generický VFS subsystém (mount tabulky, cross-fs cesty)
ani bohatý File object model (identity/capabilities) — tenký povrch `open/read/close` vychází
z reálných konzumentů (KI File API, Lua shell), ne ze spekulace.

## Důsledky

- M6.1 (rozpad v `roadmap.md`): Block Device API + virtio-blk → GPT → ext2 mount (read-only)
  → tenké Aster File API → integrace + deterministické testovací obrazy.
- **Ne v M6:** zápis, journal, ACL, extended attributes, sparse optimalizace, POSIX
  permissions jako bezpečnostní model, exotické ext2 feature flagy.
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
