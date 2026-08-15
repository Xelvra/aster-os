# Timer — Čas a plánování ticků

**Status:** V1 (draft). **Rozhodnutí:** ADR-008, ADR-017.
**Rozsah:** časový zdroj (M2), KI modul `timer`, kooperativní sleep a vazba na Lua.

---

## 1. Časový zdroj (M2)

### 1.1 Rozhodnutí: Local APIC timer + I/O APIC pro ISA IRQ

- **Tick zdroj:** **Local APIC timer** — periodické přerušení pro ticky a měření.
  Local APIC se objeví bez ACPI přes MSR `IA32_APIC_BASE`; nastavení ticku proběhne
  přes LVT (`APIC_TIMER`). SVR se inicializuje explicitně (APIC enable + spurious
  vektor 0xFF); spurious se ignoruje bez EOI (`src/kernel/cpu/idt.zig`).
- **Vstup (klávesnice):** IRQ1 (PS/2). V APIC režimu jdou ISA IRQ přes **I/O APIC
  redirection table**, ne přes PIC — `apic.init` programuje entry IRQ1 → vektor 0x21
  (BSP, edge, unmasked). Adresa I/O APIC se čte z **MADT** (`src/kernel/cpu/acpi.zig`),
  `0xFEC00000` je fallback default.
- **Legacy PIC:** remapuje se (nové vektory 0x20–0x2F) a plně maskuje jako fallback,
  aby nevznikaly spurious IRQ na špatných vektorech — standardní 8259 remap
  (`ICW1..ICW4`), ještě před prvním tickem.
- **EOI:** jde do **LAPIC** (offset 0xB0), ne do PIC — IRQ se doručuje přes IOAPIC→LAPIC.

> **Dluh do M7 (SMP):** MADT se už parsuje (RSDP → RSDT/XSDT → MADT, viz `acpi.zig`),
> ale chybí využití skutečného LAPIC ID, ISA IRQ→GSI overrides a detekce NMI. Viz
> `roadmap.md` M2 a `non-goals.md`.

### 1.2 Tick frekvence

- Default: **1000 Hz** (1 ms) — dost na měření frame latency i na plánování M7.
- Frekvence je konstantní po bootu; žádné dynamické měnění (determinismus).

---

## 2. KI modul `timer`

`timer` je **plnohodnotný KI modul** (viz `spec/kernel-interface.md` §2): Lua na něj
má přístup přes `api/timer.zig`, nikdy přímo k hardwaru.

### 2.1 Sub-op čísla

| # | Operace | Signatura | Poznámka |
|---|---|-----------|----------|
| 0 | `ticks` | `() → u64` | počet ticků od bootu |
| 1 | `sleepMs` | `(ms: u64) → ()` | kooperativní čekání, viz §3 |

### 2.2 API (Zig)

```zig
pub const TimerApi = struct {
    pub fn ticks() u64;           // monotónní, bez přetečení rozlišením u64
    pub fn sleepMs(ms: u64) void; // kooperativní, viz §3
};
```

- `ticks` je **monotónní** (nikdy se nevrací) a sdílí ji kernel, timer a Lua.
- Žádný real-time / wall clock před M6 (perzistence není; viz `non-goals.md`).

> **Tick zdroj:** monotónní čítač vlastní `src/kernel/time.zig` (middle layer,
> `time.tick()` / `time.ticks()`). APIC timer IRQ volá `time.tick()`; `api/timer`
> a runtime testy čtou `time.ticks()`. `cpu/idt.zig` tick čítač nevlastní ani
> nevystavuje (viz `kernel-interface.md` §4.7 — API nesmí importovat nízké internals).

---

## 3. Kooperativní sleep (M0–M6)

V kooperativním modelu (ADR-008) **nesmí `sleepMs` blokovat event loop** — blokující
wait by zastavil celý systém (klávesnice, rendering). Proto:

- `sleepMs(ms)` nebusy-waituje. Nastaví si **deadline** = `ticks() + ms` a **vrátí se
  okamžitě**; volající (Lua skript / úkol) pokračuje, až event loop zpracuje ticky za
  deadline.
- Implementace: event loop v každém `update()` kontroluje frontu spících úkolů
  (deadline ≤ `ticks()`); spíchnutý úkol se probudí a dostane `timer_tick`/resume.
- **IRQ handler nedělá nic jiného** než atomicky inkrementuje tick a plní frontu
  událostí (invariant Safety, `spec/input.md`).

> Toto je důsledek, který se píše **dnes**, aby se první Lua skript v M4 nechoval
> jako "UI zamrzlo na sleep".

---

## 4. Event `timer_tick`

- Fronta událostí (`spec/input.md`) nese `timer_tick: u64` — číslo ticku.
- Lua vidí `time.ticks()` (binding `TimeFuncs.ticks`); `sleep_ms` je deklarované,
  ale **Lua binding zatím neexistuje** (viz `spec/runtime.md` §4) — sleep se
  implementuje nad ticks, nikoli přes `timer_tick` eventy.

---

## 5. Timer a M7 preempce

- Od M7 (ADR-017) slouží timer zároveň jako **preempční zdroj** (přerušení pro
  přepnutí úkolu).
- Tick handler zůstává **krátký a alokačně čistý**: jen atomická aktualizace + signál
  scheduleru. Veškerá plánovací logika běží mimo IRQ kontext.
- Kooperativní `sleepMs` z §3 se v M7 transformuje na blokující sleep **úkolu**
  (jádro přepne na jiný úkol do deadline) — volající sémantika se nemění
  (`time.sleep_ms(ms)` z Lua funguje stejně).

### 5.1 Implementovaný stav (2026-08-12)

- **Preemptivní RR scheduler pro nativní kernel tasky** (`src/kernel/sched/task.zig`):
  APIC timer IRQ (vektor 0x20) je interrupt gate (IRQ maskované v ISR), takže `schedPickNext`
  manipuluje TCB tabulku v nepřerušitelném kontextu — kritická sekce bez locku (ADR-017).
- **Žádná alokace:** TCB tabulka i task stacky jsou statické v `.bss`; task stacky NIKDY
  nepřijdou z PFA (`allocPages`) — kernel image není rezervovaný v PFA bitmapě.
- **Switch:** asm bridge v `cpu/isr.s` (`sched_switch`/`sched_restore`) volá `sched_pick_next`,
  vrací saved stack pointer nového tasku; spawn znovupoužívá Reserve stejný layout jako
  preemptovaný task (fake InterruptFrame vč. `rsp`/`ss` — CPU 64-bit pushuje 5-prvkový
  frame a `iretq` popne všech 5; viz `spec/troubleshooting.md` C38).
- **Ověření:** `testPreemptiveScheduler` v runtime testech — dva tasky na sdíleném adresním
  prostoru cyklí preempcí a oba inkrementují atomické počítadlo (`RUNTIME TESTS PASS`).
- **Blokující `sleepMs` úkolu** (spec §5): `sched.sleepMs(ms)` — task si v TCB označí
  `.blocked` s wake deadline a dobrovolně předá řízení přes `sched_sleep_switch`/`sched_sleep_restore`
  v `cpu/isr.s` (save area s callee-saved regs + RFLAGS + resume adresou; žádný fake
  InterruptFrame — sleep nemá interrupt frame). Probouzení: `pickNext` na každém switchi
  probudí prošlé deadline; když není jiný úkol ready, `sleepMs` se self-switchuje a
  re-checkuje deadline. Ověřeno `testBlockingTaskSleep` v runtime testech — úkol se
  nespouští během spánku a probudí se po deadline.

**Zbývá do plné M7:** napojení na `Runtime.spawn` (wasm3 / per-program instance).

---

## 6. Invarianty

- **Timer je jediný časový zdroj**; žádné busy-wait smyčky pro čekání (Performance).
- **Žádná alokace v tick handleru** (Safety).
- **`sleepMs` nikdy neblokuje event loop v M0–M6** (Performance, Architecture).
- **Monotónní čas** — žádné nastavování času (Safety, determinismus).
