# Non-Goals — Co Aster vědomě NEdělá

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
| **SMP / vícejádro** | ❌ Ne | Single-core v prvních milnících; SMP je zásadní zásah do scheduleru a paměti. |
| **USB** | ⚠️ Budoucí (rozhodnuto 2026-08-09) | USB HID stack je potvrzený cíl (bez USB není reálný hardware); umístění se vybere v Fázi 2/M7–M10 (viz `roadmap.md`). Do té doby PS/2 (M2). |
| **Networking / TCP-IP** | ⚠️ M9 (ADR-022) | Síť je plánovaná jako KI modul `net.*` (virtio-net, ARP/IPv4/ICMP/UDP) — viz ADR-022. Bezpečnostní brzda: parser bez faultu na cizím vstupu, síť defaultně vypnutá, fuzz testy; residuální riziko DoS v Ring 0 je přijato pro hobby rozsah (dlouhodobě Ring 3, ADR-018). |
| **GPU akcelerace** | ❌ Ne | Framebuffer přes GOP (Limine); renderer je softwarový. |
| **Bezpečnostní certifikace** | ❌ Ne | Neformální systém; izolace je managed runtime úroveň (ADR-002). |
| **Multi-user prostředí** | ❌ Ne | Jeden uživatel, žádné účty. |
| **Zvuk / audio** | ❌ Ne (teď) | Rozšiřitelné přes KI: nová feature = nový KI modul přidaný na konec enumu (pravidlo §4.2 v `kernel-interface.md`), nikdy úprava existujících. Do té doby mimo roadmapu. |
| **ACPI power management** | ❌ Ne | Žádné uspávání/spouštění; tick zdroj je Local APIC timer (MSR, bez MADT). **I/O APIC** je od M2 součást (hardcoded 0xFEC00000 pro QEMU — nutný pro doručení ISA IRQ v APIC režimu). **MADT parsování** (RSDP → RSDT/XSDT → MADT) je dluh do M7 (SMP): skutečné LAPIC ID, ISA IRQ→GSI overrides, NMI detekce. Viz `roadmap.md` M2. |
| **Perzistence před M6** | ❌ Ne | Žádný FS do M6 (ADR-010); assety embedded. |
| **Síťové/cloudové služby** | ❌ Ne | Lokální experimentální systém. |
| **Arm / jiné architektury** | ❌ Ne (teď) | Aktuálně jen x86_64 (QEMU `q35`). Port (např. ARM, RISC-V) není vyloučen, ale vyžádal by si arch-neutrální KI důsledněji a vlastní změnu rozsahu — není cílem dnes. |

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
