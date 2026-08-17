# ADR-022 — Síť jako KI modul `net.*` (minimální stack, M9)

**Status:** Accepted
**Datum:** 2026-08-08

## Rozhodnutí

Přidat síť jako nový KI modul `net.*` (ADR-020), cíleno na M9. Začíná minimálním
zásobníkem: **virtio-net driver + ARP + IPv4 + ICMP echo + UDP** (TCP až v další fázi).
Parsování cizího provozu se řídí disciplínou **„žádný fault na cizím vstupu"** a síť je
**defaultně vypnutá** (zapíná se explicitně).

## Odůvodnění

`non-goals.md` vyžaduje pro síť samostatný ADR + plán, protože parsování cizího provozu
v Ring 0 s fault policy = halt je **vzdálený DoS celého systému**. Tento ADR řeší
bezpečnostní brzdu:

- **Parser bez faultu na cizím vstupu:** ARP/IPv4/ICMP/UDP se parsuje striktně
  validovaně, **bez alokace v IRQ**, s ohraničenými buffery a **bez rekurze** —
  malformovaný paket se zahodí, nikdy nezpůsobí panic/halt.
- **Síť je defaultně vypnutá** — nezpracovává se žádný provoz, dokud ji uživatel
  explicitně nezapne (KI operace `enable`).
- **Fuzz testy parseru** (host + runtime) s malformovanými pakety jako vstupy.
- **Residuální riziko se přijímá:** i při disciplíně může latentní bug v parseru
  způsobit halt (DoS). Pro hobby rozsah je to akceptované; dlouhodobé řešení je přesun
  parseru mimo fault-kritickou cestu s Ring 3 (ADR-018) — `net.*` zůstane KI modul,
  změní se jen transport.

Alternativa (odložit síť až po Ring 3) je bezpečnější, ale blokuje nejužitečnější
rozšíření na roky; disciplína + gate + fuzz je rozumný kompromis pro M9.

## Důsledky

- Nový KI modul `api/net.zig`; `Syscall` enum dostane novou položku na konec,
  sub-op čísla zmrazená (pravidlo §4/2 v `kernel-interface.md`).
- Driver **virtio-net** (standard QEMU) — analogie virtio-blk (M6); bez závislosti na
  MADT/ACPI nad rámec stávajícího stavu.
- Roadmapa M9: síť přechází z „vyžaduje ADR" na plánovanou položku.
- `non-goals.md`: síť se mění z „❌ Ne" na „M9 dle ADR-022" — non-goal se mění
  explicitně tímto ADR (pravidlo „ne je výchozí, změna = nový ADR").
- WASI síťové syscally jdou přes `net.*` (ADR-020, `runtime.md` §7.1).
- **Žádný POSIX:** v kernelu neexistuje BSD-socket API; `net.*` je vlastní KI.

## Související

- ADR-020 (rozšiřitelnost — nový KI modul), ADR-018 (Ring 3 transport), ADR-012 (Limine)
- `spec/non-goals.md`, `spec/roadmap.md` (M9), `spec/runtime.md` (§7.1), `spec/kernel-interface.md`
