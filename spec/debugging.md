# Debugging Survival Guide

**Status:** V1 (draft). **Rozhodnutí:** ADR-016, ADR-017.
**Účel:** jak diagnostikovat, když Aster spadne, zamrzne nebo se chová divně.

---

## 1. Rychlý triage

| Symptom | První krok |
|---|---|
| System nereaguje, serial tichý | je kernel vůbec bootnul? (marker `ASTER BOOT OK`) |
| Serial vypsal fault / panic | viz §3 (čtení dumpu) |
| Test zacyklil v QEMU | runtime test — idle watchdog (spec `verification.md` Krok 4b) |
| Chová se deterministicky špatně | build twice + porovnej hash (ADR-014) |

Pravidlo: **systém je deterministický** (ADR-014, ADR-016). Stejný commit + stejné
vstupy = stejné chování. „Náhodný" pád je podezřelé — obvykle to znamená nenačtený
nedefinovaný stav, ne race.

---

## 2. GDB + QEMU

Kernel se dá ladit z hostitele přes GDB:

```bash
# 1. QEMU čeká na GDB (-S), poslouchá na :1234
qemu-system-x86_64 -s -S <ostatní parametry>

# 2. v jiném terminálu
gdb zig-out/bin/aster.elf
(gdb) target remote :1234
(gdb) continue
```

Užitečné příkazy:
- `info registers` — stav registrů.
- `bt` — backtrace z aktuálního rámce (funguje, pokud máme symboly).
- `b kernel_main` / `b <fn>` — breakpoint; Zig funghuje s `-g`.
- `x/20i $rip` — rozebírané instrukce kolem crashu.

> Poznámka: kernel se buildí `ReleaseSafe` (spec `invariants.md`). Debug build dává
> plné symboly; `ReleaseSafe` zachová safety checky, ale optimalizuje — některé
> proměnné nemusí být viditelné. Pro těžké ladění použij `Debug`.

---

## 3. Čtení serial dumpu

Fault policy (spec `invariants.md` §1): na neopravitelnou chybu kernel **haltne a
vypíše na serial**. Očekávaný tvar výpisu:

```text
ASTER FAULT: page fault
  error:      write, non-present
  rip:        0xffffffff80001234
  cr2:        0x0000000000000000
  registers:  rax=0 rbx=1 ...
  backtrace:  0xffffffff8000abcd <- 0xffffffff8000cdef ...
```

Jak číst:
1. **`error`** — typ faultu (page fault / GPF / double fault) a operace (read/write).
2. **`rip`** — kde přesně došlo k chybě. Přelož na funkci:
   ```bash
   addr2line -e zig-out/bin/aster.elf -f 0xffffffff80001234
   ```
3. **`cr2`** — adresa, která fault způsobila (jen page fault).
4. **`backtrace`** — řetězec návratových adres; každou nech přes `addr2line`.

> **Double fault / triple fault:** je-li dump trojitý (QEMU se restartuje), může být
> samotný fault handler rozbitý — podezřívej IDT entry, stack switch (TSS), nebo
> rekurzi v handleru. Tripple fault se testuje v QEMU přes `isa-debug-exit`
> (spec `verification.md` Krok 4b).

---

## 4. Pravidla pro IRQ (častý zdroj pádů)

Uvnitř IRQ handleru je **zakázáno** (invariant Safety, spec `invariants.md` §1):

- **Alokace** (allocator.alloc) — heap nemusí být konzistentní.
- **Zamykání** — deadlock riziko.
- **Volání Lua** — VM není reentrantní.
- **Rekurze / dlouhá práce** — prodlužuje latenci, riskuje překrytí IRQ.

IRQ handler **jen atomicky** manipuluje s předem alokovanými strukturami (fronta
událostí, tick čítač) a vrací se. Veškerá logika patří do event loopu
(spec `input.md`).

Při podezření na pád v IRQ:
1. Vypni podezřelé IRQ (maska PIC/APIC), jinak to spadne znovu.
2. Serial dump ukáže `rip` uvnitř handleru — ověř, že je v `drivers/`/`cpu/`, ne v
   alokátoru.
3. Zkontroluj atomické indexy fronty (spec `input.md` §3) — nekonzistentní read/write
   pozice jsou klasika.

---

## 5. Nástroje

| Nástroj | Použití |
|---|---|
| `addr2line` (binutils) | překlad adresy z dumpu na funkci/řádek |
| `gdb` + QEMU `-s -S` | interaktivní ladění |
| `objdump -d` | disassembl pro kontrolu generovaného kódu |
| `tools/qemu-smoke.sh` | automatický boot test |
| `tools/bench.sh` | metriky (ADR-015) |
| `tools/verify-reproducible.sh` | deterministický build (ADR-014) |

> Tento dokument řeší **runtime** ladění (pád, zamrzlý systém, IRQ). Build-time pasti —
> Zig 0.16 API, Limine protokol, determinismus — jsou v
> [`troubleshooting.md`](troubleshooting.md).
