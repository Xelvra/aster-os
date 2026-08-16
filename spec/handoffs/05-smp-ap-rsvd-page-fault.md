# Handoff H5: SMP — AP jádro dostane #PF(RSVD) po zapnutí pagingu a firmware bootuje OS na AP

**Datum:** 2026-08-16
**Status:** closed (root cause = `call 1f; pop %ebx` „getip" trik v 32-bit trampolině před nastavením zásobníku — AP má po INIT-SIPI `ESP` nedefinované (v QEMU 0), `pop` načetl odpadky místo adresy bloku, CR3 se přečetl z náhodné fyzické adresy → AP stránkoval přes odpadkovou tabulku → `#PF(RSVD)` ihned po `PG=1`; fix = přímé `tramp_base + (symbol - smp_trampoline_start)` adresování, viz C48. Kromě toho opraven CR4 mirror (`0x640` = MCE, ne PGE → `0x620`) a doplněn chybějící `ljmp` do 64-bit long mode — `smp_lm64` byl předtím mrtvý kód)

---

## 1. Symptom

Zapnutí AP jader (M2/M7 dluh) přes vlastní trampolinu + INIT-SIPI-SIPI. BSP probudí
AP, ale **jakmile AP zapne stránkování (`CR0.PG`)**, dostane `#PF(RSVD)` na fetch
instrukce z vlastní trampoliny, poté double fault, **triple fault → CPU reset**. Po
resetu firmware (SeaBIOS) **re-bootuje celý OS na AP** (sdílí RAM s BSP), což
zahlcuje COM1 a **BSP visí na serialu** (busy-wait na transmit-hold register).
Hang je nestabilní co do místa (občas i dříve v bootu), v TCG lépe reprodukovatelné.

> Reprodukce (rozpracovaný working tree, HEAD `0037c5f`):
> ```bash
> zig build iso
> timeout 15 qemu-system-x86_64 -M q35 -m 512M -smp 2 -rtc base=localtime \
>   -cdrom zig-out/aster.iso -serial stdio -boot order=d -no-reboot -display none
> ```
> Očekávaný výstup: boot log `[ OK ] cpu ... smp: 1 ap`, `ASTER BOOT OK`,
> `ASTER FIRST FRAME`, runtime testy PASS.
> Skutečný výstup: hang po probuzení AP (BSP visí na COM1).

Diagnostika (`-d int,cpu_reset`):

```
CPU Reset (CPU 0)          <- BSP? (z Limine/firmware)
CPU Reset (CPU 1)
... 6× CPU Reset za běh
check_exception old: 0xffffffff new 0xe
     0: v=0e e=0018 i=0 cpl=0 IP=0008:000000000000807f pc=000000000000807f SP=0010:0000000000000000 CR2=000000000000807f
check_exception old: 0xe new 0xe
     1: v=08 e=0000 i=0 cpl=0 IP=0008:000000000000807f ...   (double fault)
```

- `v=0e` = #PF, error code `0x18` (bit 4 I/D + **bit 3 RSVD**), fetch z trampoliny
  (~`0x807f`), `SP=0` (AP ještě nemá stack). `CS=0008` = trampoline 32-bit selector.
- `v=08` = #DF, pak triple fault → reset.

## 2. Prostředí

| Vrstva | Hodnota |
|---|---|
| Build | `zig build iso` (ReleaseSafe), `zig build -Doptimize=Debug` pro symboly |
| Toolchain | Zig 0.16.0, x86_64-freestanding |
| Runtime | QEMU 11.0.3, KVM i TCG, `-M q35 -m 512M -smp 2 -rtc base=localtime` |
| Vlastní kód | working tree nad `0037c5f` (rozpracované SMP, necommitováno) |

## 3. Co bylo vyzkoušeno

| # | Pokus | Výsledek | Závěr |
|---|-------|----------|-------|
| 1 | INIT IPI bez deassertu | `waitForIcrIdle` visí navěky | **FIX:** INIT je level-triggered → assert + ~10 ms + deassert (`apic.sendInitIpi`) |
| 2 | AP s vlastním COM1 debug makrem v trampolině | BSP visí na COM1, znaky se prolínají (`sAipi` = BSP "s" + AP "A" + BSP "ipi") | AP nesmí psát na COM1; debug nahrazen paměťovými značkami (`smp_marks`) |
| 3 | marks: AP v 16-bit real mode | BSP v pořádku | 16-bit část trampoliny OK |
| 4 | marks: AP v 32-bit protected mode (bez pagingu) | BSP v pořádku | 32-bit část OK |
| 5 | marks: AP + `mov cr3` (BSP CR3, bez pagingu) | BSP v pořádku | načtení CR3 OK |
| 6 | marks: AP + `cr4.PAE` (bez pagingu) | BSP v pořádku | PAE sám o sobě OK |
| 7 | marks: AP + `cr0.PG` (**paging**) | **BSP hang (COM1)** | spouštěč je zapnutí stránkování |
| 8 | QEMU `-d int,cpu_reset` | `#PF(RSVD)` e=0x18 na fetch ~`0x807f`, #DF, **6× CPU Reset** | AP triple-faultuje → firmware reboot → OS na AP → COM1 spam → BSP visí |
| 9 | AP bez `EFER.NXE` (jen `LME`) | RSVD | Limine PTE mají **NX (bit 63)**; AP po resetu má `NXE=0` → bit 63 je reserved → **FIX:** `LME\|NXE` (`0x900`) |
| 10 | AP s `LME\|NXE` | **stále #PF(RSVD) e=0x18** na fetch z trampoliny | root cause NENÍ chybějící NXE |
| 11 | CR4 mirror BSP (`PGE\|PAE\|OSFXSR\|OSXMMEXCPT`) | stále RSVD | není CR4 |
| 12 | Dump BSP page tables | `CR3=0x1ff84000`, `pml4[0]=0x10a023`, `pdpt[0]=0x10b023`, `pd[0]=0x10c023`, `pt[8]=0x8063`; BSP `CR4=0x620` (bez LA57) | tabulky vypadají validní, root cause neznámý |
| 13 | `pd[0]` → 2 MiB huge page (base 0, `0x83`) | stále RSVD | není PT úroveň |
| 14 | **Nahrazení Limine `PML4[0]` vlastní identity mapou** | **zastaveno** — odvážný zásah do stabilního bootloaderu, vráceno zpět | NEPOUŽÍVAT; hledat kořenovou příčinu |
| 15 | **FIX (root cause):** v `smp_pm32` nahrazen `call 1f; pop %ebx` (getip) za přímé `movl (tramp_base + smp_cr3 - smp_trampoline_start), %eax`; dále CR4 `0x640` → `0x620` (MCE → OSFXSR/OSXMMEXCPT mirror BSP, PAE zvlášť) a doplněn `ljmp $0x18` do `smp_lm64` (předtím mrtvý kód) | **RSVD fault i triple fault pryč** — boot do `ASTER BOOT OK` / `ASTER FIRST FRAME`, boot log `smp: 1 ap`; `qemu-test` s diskem **PASS (exit 99, 3×)**; `ap_ready == ap_count` v `runtime_test.zig` prošlo → AP doběhlo přes `idt.load()` a `apic.enableLocal()` | potvrzeno (C48, §4) |

Závěr z pokusů: 16/32-bit i CR3/PAE bez pagingu fungují; **paging je spouštěč RSVD
faultu**, a to i s `LME|NXE`, s BSP CR4 i s vlastní huge page mapou.

## 4. Hypotézy

1. **Limine page tables obsahují bit, který AP interpretuje v 32-bit compatibility
   módu jako reserved.** AP dosud vždy parkoval v 32-bit (CS=0x8/0x10); **64-bit
   long mode přechod (`ljmp 0x18`) nikdy nebyl vyzkoušen**.
   - Potvrzení: nechat AP projít `ljmp` do 64-bit a fetchnout `lm64`/higher-half
     kernel (CS=0x18/0x28).
   - Vyvrácení: RSVD i na 64-bit fetch ze stejné stránky.
2. **Error code `0x18` (P=0 + RSVD=1) je neobvyklá kombinace** — buď QEMU hlásí
   reserved bit na jiné úrovni walku, nebo to není čistý page-walk fault (interakce
   s IDT lookup: AP běží **bez naší IDT**, IDTR zděděné z firmware).
   - Potvrzení: nahrát na AP jednoduchou IDT před pagingem a sledovat změnu faultu.
   - Vyvrácení: fault beze změny.
3. **BSP EFER obsahuje další bity (SC apod.), které Limine page tables předpokládají.**
   - Potvrzení: porovnat EFER BSP vs AP; dumpnout BSP EFER.
4. **Bezpečnější cesta: Limine SMP request (`LIMINE_SMP_REQUEST`)** — bootloader sám
   probudí AP a dodá per-CPU info + trampolinu; žádné vlastní low-memory/SIPI hacky.
   - Potvrzení: implementace a boot s `-smp 2`; žádný vlastní `PML4[0]` zásah.

## 5. Reprodukce

Od aktuálního rozpracovaného stavu (necommitováno; HEAD `0037c5f`):

```bash
zig build iso
# hang (bez diagnózy):
timeout 15 qemu-system-x86_64 -M q35 -m 512M -smp 2 -rtc base=localtime \
  -cdrom zig-out/aster.iso -serial stdio -boot order=d -no-reboot -display none
# diagnóza (RSVD fault + resety):
timeout 8 qemu-system-x86_64 -M q35 -m 512M -smp 2 -rtc base=localtime \
  -cdrom zig-out/aster.iso -serial file:/tmp/q.log -boot order=d -no-reboot \
  -display none -d int,cpu_reset -D /tmp/int.log
grep -E "v=0e|v=08|CPU Reset" /tmp/int.log
```

Nejlepší bod pro hraní si s trampolinou: `smp.init` (kopie + data) a `smp.bringUp`
(INIT/SIPI) v `src/kernel/cpu/smp.zig`, vlastní přechod v `src/kernel/cpu/smp_tramp.s`
(dosud parkuje v 32-bit smyčce na konci `smp_pm32`).

## 6. Důležité artefakty

- `src/kernel/cpu/smp_tramp.s` — trampolina (16/32-bit hotová; paging v ní spouští
  RSVD; **`lm64`/`ljmp` dosud nedořešené**).
- `src/kernel/cpu/smp.zig` — `init`/`bringUp`/`apEntry`, `ap_ready` atomika,
  `ap_stacks` (16 KiB/AP), marks v bloku trampoliny.
- `src/kernel/cpu/apic.zig` — IPI (`sendInitIpi` s deassertem, `sendSipi`),
  `enableLocal`, `readLocalApicId`; `io.writeMsr` v `src/kernel/cpu/io.zig`.
- `src/kernel/cpu/acpi.zig` — sběr AP LAPIC ID (`ap_ids`, `ap_count`).
- `src/kernel/cpu/idt.zig` — `pub fn load()` (per-CPU IDTR), voláno z `apEntry`.
- QEMU `-d int` výstup (viz §1 a §3#8): `#PF(RSVD)` na fetch z trampoliny + CPU resety.
- `build.zig` / `tools/*.sh` — `-smp 2` na všech QEMU voláních.

## 7. Omezení a podezřelé okolnosti

- Testováno **jen v QEMU** (KVM i TCG), ne na reálném hardwaru.
- **64-bit long mode přechod nikdy nebyl dosažen** — AP vždy parkoval v 32-bit
  compatibility módu (CS=0x8/0x10); hypotéza §4.1 není otestovaná.
- **Nahrazení Limine `PML4[0]` bylo odvoláno** (uživatel: příliš odvážné) — vrátit
  se k tomuto řešení jen jako poslední možnost a po dohodě.
- AP COM1 interference je **druhotný efekt** reset smyčky (firmware re-bootuje OS na
  AP), ne kořenová příčina; samotný BSP hang na serialu zmizí, jakmile AP přestane
  triple-faultovat.
- Scheduler zůstává BSP-only: AP má jen `fetchAdd(ap_ready)` + idle (`sti; hlt`),
  žádné sdílené scheduler stavy.
- `build.zig` byl při ladění přepnut `single_threaded` → `false` a zpět na `true`
  (atomics na AP by při `true` mohly být optimalizované na plain — aktuálně irelevantní,
  AP se neprobudí).

## 8. Ideální výsledek

- `zig build iso` + QEMU `-smp 2` → boot log `[ OK ] cpu ... smp: 1 ap`,
  `ASTER BOOT OK`, `ASTER FIRST FRAME`, deterministicky v KVM i TCG.
- Runtime test „SMP AP bring-up (INIT-SIPI-SIPI)" v `src/kernel/runtime_test.zig`
  PASS (exit 99): `ap_count >= 1` a `ap_ready == ap_count`.
- AP běží v long mode s naší IDT a LAPIC enabled, idle; BSP scheduler beze změny.
- Kořenovou příčinu RSVD zapsat do `spec/troubleshooting.md` (nová C-lekce), handoff
  uzavřít; `-smp 2` zůstává ve všech QEMU skriptech a CI.
