# Debugging Survival Guide

**Status:** V1 (draft). **Rozhodnutí:** ADR-016, ADR-017.
**Účel:** jak diagnostikovat, když Aster spadne, zamrzne nebo se chová divně.

---

## 0. Co se kdy debuguje (rozhodovací strom)

Debug ovlivňuje, **v jaké vrstvě** se problém nachází — podle toho se vybere nástroj.
Nejdřív se určí vrstva, pak se ladí.

| Vrstva | Projev | Nástroj |
|---|---|---|
| **Boot / kernel start** | serial němý, Limine menu, hang před `ASTER KERNEL ENTRY` | GDB + QEMU (§2) |
| **Kernel kód (Zig)** | fault dump, divný stav, RIP v kernelu | GDB + QEMU (§2), serial dump (§3) |
| **Event loop / IRQ** | render/input pád, zacyklení | GDB (§2), IRQ pravidla (§4) |
| **Lua shell** | Lua chyba, `attempt to index a nil`, špatné UI chování | `debug` KI modul + `traceback` (§5) |
| **Build / toolchain** | kompilace, Limine, determinismus | `troubleshooting.md` (build-time) |

Pravidlo prvního kroku: **urči vrstvu z projevu, ne hádej.** Boot marker
(`ASTER BOOT OK`) řekne, zda kernel dojel; fault dump řekne, kde spadl; Lua chyba
říká, že problém je ve skriptu. Teprve pak se sáhne po GDB.

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

## 2. GDB + QEMU (kernel)

### Kdy

Když je problém v kernel kódu (Zig): fault, hang, divný stav, kdy serial dump
nestačí a je potřeba krokovat nebo prohlížet paměť/registry živě.

### Co je potřeba vědět předem

- Kernel bootuje **z ISO přes Limine** — QEMU se spouští s `-cdrom <iso>`, **ne**
  s `-kernel <elf>`. Kernel binárka pro gdb je `zig-out/bin/aster`.
- **Symboly jsou jen v Debug buildu** (`build.zig`: `strip = optimize != .Debug`).
  Default je `ReleaseSafe` → stripped. Pro gdb stav `-Doptimize=Debug`.
- Debug build dnes **buildí a bootuje** (C27/C28 workaroundy), ale je pomalejší a
  nepředpovídá chování ReleaseSafe (L2, D1). Ladí se v Debug, **verifikuje** v
  ReleaseSafe.

### Postup

```bash
# 1. sestav debug ISO (symboly v binárce)
zig build iso -Doptimize=Debug

# 2. QEMU: -s = gdb stub na :1234, -S = počká na připojení
ISO=$(find .zig-cache -name aster.iso -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
qemu-system-x86_64 -s -S -M q35 -m 512M -cdrom "$ISO" \
    -serial stdio -no-reboot -no-shutdown

# 3. v jiném terminálu
# Breakpoint se musí dát na higher-half adresu (base 0xffffffff80000000),
# viz poznámka níže.
gdb zig-out/bin/aster \
    -ex "target remote :1234" \
    -ex "b *0xffffffff801031c0" \
    -ex "continue"
```

> **Proč adresa, ne jméno funkce:** gdb symboly mangluje na offset bez higher-half
> base (např. `main.kernelMain` = `0x1031c0`), ale kernel běží na
> `0xffffffff80000000 + offset`. Breakpoint `b main.kernelMain` by nikdy nezastavil.
> Adresu zjistíš takto:
> ```bash
> nm zig-out/bin/aster | grep main.kernelMain   # -> 0x1031c0
> # breakpoint: 0xffffffff80000000 + 0x1031c0 = 0xffffffff801031c0
> ```
>
> Pozor: bez `-S` QEMU naběhne a kernel může fault dřív, než se gdb připojí.
> `-s` bez `-S` je pro "připoj se k běžícímu" scénáři — pak breakpointy můžeš
> nastavit jen na kód, který ještě neproběhl.

Užitečné příkazy:
- `info registers` — stav registrů.
- `bt` — backtrace (funguje, pokud máme symboly = Debug build).
- `b *<higher-half adresa>` — breakpoint (viz poznámka o adresách).
- `x/20i $rip` — instrukce kolem crashu.
- `p/x *(u64*)0xffff800000000000` — čtení paměti (kernel je na vyšší polovičce).

> Poznámka k adresám: kernel běží na `0xffffffff80000000+` (HHDM na
> `0xffff800000000000+`). gdb `bt` a breakpointy fungují přes symboly; adresy pro
> `x/` se berou z dumpu/registrů, ne z fyzických adres.

### CodeLLDB (VS Code) — attach, ne launch

Kernel není hostitelský proces — LLDB ho **nelze spustit** (`launch` selže).
Správně je **attach** na gdb stub přes custom request:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "lldb",
      "request": "custom",
      "name": "Attach to QEMU kernel",
      "targetCreateCommands": ["target create ${workspaceFolder}/zig-out/bin/aster"],
      "processCreateCommands": ["gdb-remote 1234"]
    }
  ]
}
```

Postup: sestav `-Doptimize=Debug`, spusť QEMU s `-s -S`, ve VS Code F5 (attach).
Stejný workflow jako gdb v terminálu, jen s klikacím UI.

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
2. **`rip`** — kde přesně došlo k chybě. Přelož na funkci: **odečti higher-half base**
   (`0xffffffff80000000`) a dej výsledek do addr2line:
   ```bash
   addr2line -e zig-out/bin/aster -f 0x0000000000001234
   ```
   (z `0xffffffff80001234` − `0xffffffff80000000` = `0x1234`). Pozor: bez Debug
   buildu jsou symboly stripped — addr2line pak nedá funkci. binutils může hlásit
   `DWARF error` u Zig debug info a zobrazit funkci bez řádku — to je omezení
   nástroje, funkce je důvěryhodná.
3. **`cr2`** — adresa, která fault způsobila (jen page fault).
4. **`backtrace`** — řetězec návratových adres; každou odečti base a dej přes
   `addr2line`.

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

## 5. Lua shell (embedded) — jak debugovat

### Co NEfunguje (a proč)

- **Hostitelské Lua debugery** (tomblind, VS Code Local Lua Debugger) **neplatí** —
  spouští samostatný `lua5.4` proces. Aster běží vlastní embedded Lua uvnitř kernelu;
  debugger se k ní z hostitele nepřipojí.
- **`debug.traceback()` neexistuje** — jméno `debug` je obsazené KI bindingem
  (`debug.write`); Lua debug knihovna je proto otevřená **pod jménem `dbg`**
  (M6.1.9): v Lua je k dispozici **`dbg.traceback()`**. (Stock `luaopen_debug` se
  neotevírá — její `debug.debug` by četlo ze stdin, které kernel nemá; `dbg` je
  vlastní lib s `traceback`.)

### Co funguje dnes

1. **`debug.write(str)`** — výpis z Lua na serial (KI modul, `runtime.md` §5).
   `debug.write("x=" .. tostring(x))` — ekvivalent printu pro embedded shell.
2. **Lua chyba se píše na serial** — `runtime.md` §5 obsah chyby (spouštěč 2).
   Chybová zpráva Lua (`attempt to index a nil value`, stack trace, ...) jde na
   serial, ať víš, kde skript spadl.
3. **Rozděl problém na malé kroky** — podezřelou funkci zavolej samostatně
   (např. z REPL) a sleduj, co vrací.
4. **`dbg.traceback([msg], [level])`** — stack trace aktuálního Lua stavu na
   serial (M6.1.9; jméno `dbg`, protože `debug` drží KI modul).

### Budoucí cesta (vyžaduje implementaci)

- **`lua_sethook` → serial** — hook (line/call/return události) by posílal na COM1
  číslo řádku + funkci. To je cesta pro krokování embedded Lua z kernelu (přes
  `debug.write` na serial), ne z hostitele.

---

## 6. Nástroje

| Nástroj | Použití |
|---|---|
| `addr2line` (binutils) | překlad adresy z dumpu na funkci/řádek |
| `gdb` + QEMU `-s -S` | interaktivní ladění kernelu (Debug build) |
| `objdump -d` | disassembl pro kontrolu generovaného kódu |
| `tools/qemu-smoke.sh` | automatický boot test |
| `tools/bench.sh` | metriky (ADR-015) |
| `tools/verify-reproducible.sh` | deterministický build (ADR-014) |

> Tento dokument řeší **runtime** ladění (pád, zamrzlý systém, IRQ). Build-time pasti —
> Zig 0.16 API, Limine protokol, determinismus — jsou v
> [`troubleshooting.md`](troubleshooting.md).
>
> Problém, který se nedaří vyřešit v rozumném čase, se předává přes formální postup
> [`handoff.md`](handoff.md) — šablona a seznam otevřených handoffů, ne improvizace.

