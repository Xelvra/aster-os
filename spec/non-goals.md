# Non-Goals — Co Aster OS vědomě NEdělá

**Status:** Current design
**Účel:** jasně vymezený rozsah projektu. Každý dotaz typu "proč tam není X?" se odkazuje
na tento dokument.

> Non-goal není "nikdy". Je to "ne teď, a pokud ano, tak výslovně schválenou změnou rozsahu
> (nový ADR)".

---

## Aktuální non-goals

| Oblast | Stav | Poznámka / kdy by se to mohlo změnit |
|---|---|---|
| **POSIX kompatibilita** | ❌ Ne | Žádná POSIX API v kernelu; KI je vlastní (ADR-004). **Výjimka:** runtime vrstva může hostit **WASI** pro cizí Wasm aplikace (viz `runtime.md` §7.1) — WASI je klient KI, ne součást kernelu. |
| **SMP / vícejádro** | ⚠️ Částečně | **SMP bring-up je hotový** (MADT, INIT-SIPI, APy po bootu idlují — `cpu/smp.zig`), ale **scheduler je BSP-only** — APy neběží žádnou kernel práci. Práce AP jader na kernel taskách je výhled, dokud to metriky nevyžadují (ADR-015). |
| **USB** | ⚠️ Budoucí (rozhodnuto 2026-08-09) | USB HID stack je potvrzený cíl (bez USB není reálný hardware); umístění se vybere v Fázi 2/M7–M10 (viz `roadmap.md`). Do té doby PS/2 (M2). |
| **Networking / TCP-IP** | ⚠️ M9 (ADR-022) | Síť je plánovaná jako KI modul `net.*` (virtio-net, ARP/IPv4/ICMP/UDP) — viz ADR-022. Bezpečnostní brzda: parser bez faultu na cizím vstupu, síť defaultně vypnutá, fuzz testy; residuální riziko DoS v Ring 0 je přijato pro hobby rozsah (dlouhodobě Ring 3, ADR-018). |
| **GPU akcelerace** | ❌ Ne | Framebuffer přes GOP (Limine); renderer je softwarový. |
| **Bezpečnostní certifikace** | ❌ Ne | Neformální systém; izolace je managed runtime úroveň (ADR-002). |
| **Multi-user prostředí** | ❌ Ne | Jeden uživatel, žádné účty. |
| **Zvuk / audio** | ❌ Ne (teď) | Rozšiřitelné přes KI: nová feature = nový KI modul přidaný na konec enumu (pravidlo §4/2 v `kernel-interface.md`), nikdy úprava existujících. Do té doby mimo roadmapu. |
| **ACPI power management** | ❌ Ne | Žádné uspávání/spouštění; tick zdroj je Local APIC timer (MSR). **I/O APIC discovery, LAPIC topologie, ISA IRQ→GSI overrides i NMI detekce: hotovo** (MADT parsing, `src/kernel/cpu/acpi.zig` + `apic.zig`; boot log rozlišuje důvod fallbacku — `no-rsdp` / `bad-checksum` / `no-madt` / `no-ioapic-entry`). Viz `roadmap.md` M2. |
| **Perzistence** | ✅ Hotovo | Od M6 initfs, od M7.1 ext2 **read-write** (ADR-023); assety v initrd taru. |
| **Síťové/cloudové služby** | ❌ Ne | Lokální experimentální systém. |
| **Arm / jiné architektury** | ❌ Ne (teď) | Aktuálně jen x86_64 (QEMU `q35`). Port (např. ARM, RISC-V) není vyloučen, ale vyžádal by si arch-neutrální KI důsledněji a vlastní změnu rozsahu — není cílem dnes. |
| **Multiplatformní CI (Windows/macOS)** | ❌ Ne | Kernel je `x86_64-freestanding` — **neběží na Windows ani macOS** a není POSIX/binárně kompatibilní s Linuxem (vlastní KI, ADR-004). Build host je jen toolchain; OS běží výhradně v QEMU (`q35`) / vlastním hardwaru. Host unit testy na Windows/macOS x86_64 testují **stejné kernel moduly na stejném host CPU** jako Linux x86_64 — nulový přínos; na arm64 macOS by navíc **selhaly** (x86_64 asm v kernel modulech). CI cílí na Linux (QEMU, ISO, runtime testy); `build.zig` zůstává v principu portabilní, ale multiplatformní build matrix se **netestuje** — kdyby přibyl vývojář na Windows/macOS, znovu se to posoudí změnou rozsahu (ADR). CI cache + `concurrency: cancel-in-progress` (2026-08-16) zůstávají jako součást **Linux** CI, ne multiplatformního záměru. |

---

## Co se sem dostane VŽDY, když přibude nová funkce

Přidání kteréhokoli z výše uvedených do rozsahu vyžaduje:

1. Nový ADR v `spec/adr/` (rozhodnutí se nemění mlčky).
2. Aktualizaci `spec/roadmap.md` (nový milník nebo rozšíření).
3. Aktualizaci metriky v tabulce kvality (ADR-015).
4. Kontrolu invariantů (`spec/invariants.md`), zvlášť Performance.

---

## Rozhodování: "ne" je výchozí

Když někdo navrhne novou funkci, výchozí odpověď je **ne**, dokud:

- je to potřeba pro existující milník,
- existuje měřitelný důvod (ne "bylo by to hezké"),
- rozhraní to zvládne bez rozbití KI,
- systém zůstane bootovatelný a metriky pod cílem (ADR-015, ADR-016).

Tento dokument je **aktuální stav**, ne dogma — mění se výslovně, stejným procesem jako
cokoli jiného.
