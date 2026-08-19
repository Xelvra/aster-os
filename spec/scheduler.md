# Scheduler a SMP — Concurrency model (M7)

**Status:** V1 (draft). **Navazuje na ADR:** 008 (kooperativní smyčka, superseded pro M7), 017 (concurrency model M7), 002 (single address space).
**Kód:** `src/kernel/sched/task.zig`, `sched/sync.zig`, `cpu/isr.s` (asm bridge), `src/kernel/cpu/{smp,apic,acpi}.zig`, `smp_tramp.s`.

---

## 1. Princip

M7 zavádí **preemptivní round-robin scheduler** pro nativní kernel tasky (ADR-017),
navazující na kooperativní event loop M0–M6 jako rozšíření, ne přepis. Základní fakt,
na kterém celý model stojí: **single-core, sdílený adresní prostor.** Preempce probíhá
jen v přerušení od časovače (jediný bod přepnutí), ne paralelně na více jádrech — proto
sdílený stav chrání **zakázání preempce** (IRQ maska) v krátkých kritických sekcích,
**nikoli locky** (spinlocky/CAS by v single-core byly režie a deadlock riziko).

**Vztah k programům (Lua/Wasm):** scheduler přepíná **nativní kernel tasky**. Lua
programy se tickují přes `lua.tickPrograms()` (per-program `lua_State`, `spec/runtime.md`
§5) a wasm programy přes `wasm.tickPrograms()` (`spec/runtime.md` §7.2) — obojí z
`update()` fáze kernel event loopu (task 0). Scheduler samotný žádný runtime nezná.

```
APIC timer IRQ (vektor 0x20)
   ↓  interrupt gate (IF masked)
isr.s asm bridge → sched_pick_next (task.zig)
   ↓  uloží current task (saved_sp), vybere next, vrátí jeho saved_sp
iretq → obnoví registrace → task běží další kvantum
```

---

## 2. Task model

### 2.1 TCB tabulka a stacky

- **Task 0** = kernel main kontext (event loop / runtime testy). Založen v `sched.init`
  před zapnutím přerušení, takže první timer IRQ už vidí konzistentní tabulku.
- **`spawnTask(entry)`** přidá nativní kernel task; `max_tasks = 10` (1 main + 9
  spawnable) — runtime testy drží všechny task-spawning testy najednou; tasky se
  **nikdy netear-downují**.
- **Žádná dynamická alokace:** TCB tabulka i stacky jsou statické (`.bss`). Task stacky
  se **nikdy nealokují z PFA** (kernel image není v PFA bitmapě rezervovaný) — porušení
  by mohl PFA přidělit paměť kernelu. `task_stack_size = 32 KiB` (deepest path: volání
  uvolnění triple-indirect ext2 souboru ~12 KiB + block driver frame).
- **Stack overflow kanárky** (brief Task 7a): každý stack má magic slovo na dně,
  kontrolované při každém přepnutí; porušený kanárek → halt s diagnostikou na serial
  (stejná politika jako heap `checkBlock()`, `spec/invariants.md` §1). Software check s
  detekčním zpožděním — hlásí až při příštím přepnutí.

### 2.2 Stavy

`TaskState = unused | ready | running | blocked`. `.blocked` = task čeká na wake
deadline (`sleepMs`) nebo na signál synchronizačního primitiva; probouzí se jen
z `pickNext` (wake check při každém picku, nemůže se minout).

### 2.3 Přepnutí (context switch)

- **Preempce:** APIC timer IRQ → interrupt gate (IF masked) → asm bridge `sched_switch`
  zavolá `sched_pick_next(current_rsp)`. Vracející `saved_sp` je adresa return-address
  slotu na suspendovaném stacku — `movq saved_sp, %rsp; ret` lands na restore sekvenci.
- **Dobrovolné blokování (`sleepMs`):** `sched_sleep_switch` (asm) uloží callee-saved
  registry a resume point do malé save area, předá wake deadline
  `schedSleepPickNext` a přepne; probuzení je `sched_sleep_restore`. Smyčka v `sleepMs`
  re-checkuje deadline, protože fallback self-switch (žádný jiný runnable task) se vrátí
  okamžitě.
- **Round-robin:** `pickNext()` probudí blocked tasky s prošlým deadline, pak vybere
  příští ready task v pořadí tabulky. Na ISR cestě je přepnutý task vždy ready (fallback
  self-switch jen na volní cestě).
- **Kritická sekce bez locku:** interrupt gate maskuje IF v ISR → manipulace s TCB v
  `schedPickNext` běží v nepřerušitelném kontextu. `spawnTask`/primitiva běží v normálním
  kontextu pod RFLAGS-based interrupt guardem (`irq.begin`/`end`).

### 2.4 Initial frame

Nový task dostane ručně sestavený interrupt frame (SS, RSP, RFLAGS, CS, RIP + 256B XMM
area + return slot na restore sekvenci) — resume běží přesně stejnou cestou jako resume
preemptovaného tasku. `rflags` má IF set, takže timer může nový task preemptovat.

---

## 3. Blokující synchronizační primitiva (sched/sync.zig)

ADR-017: čekající úkol se odebere z ready fronty (neblokuje jádro), scheduler přepne na
jiný úkol; probuzení obstará manipulace s primitivem v kritické sekci. **Jen spawned
nativní tasky mohou čekat** — blokování tasku 0 (event loop/desktop) by zamrazilo shell.

| Primitivum | Sémantika |
|---|---|
| **Semaphore** | `wait`: decrement, nebo registrace do FIFO waiters + blockUntilWoken; `signal`: increment, nebo handoff slotu nejstaršímu waiteru (FIFO) + wake. Wait registrace a blokující switch pod jedním interrupt guardem — signal se nemůže mezi ně vklinit a ztratit se. |
| **Mutex** | binární semafor se stejným mechanismem (bez priority inheritance, YAGNI). |
| **Event group** | sada bitů; wait na vybrané bity, set vybudí čekající. |
| **Message queue** | FIFO zpráv; čtení blokuje, zápis budí. |
| **Error handler tasku** | `spawnTaskChecked(entry, on_error)`: task vrací `anyerror!void`; při chybě běží `on_error` (např. zaznamená selhání), task pak idluje navždy. Chyba jednoho úkolu nikdy neshodí jiný úkol ani kernel. |

Všechna primitiva stojí na stejném základu: **waiters list guarded interrupt maskou** —
žádný lock, žádný CAS (`spec/invariants.md` Architecture).

---

## 4. SMP — stav a role

**SMP bring-up je hotový, scheduler zůstává BSP-only** (ADR-017 status update,
`spec/non-goals.md`):

- **`cpu/smp.zig`:** MADT (ACPI) → LAPIC ID list → trampolína zkopírovaná do low
  memory (<1 MiB, PFA ji implicitně rezervuje, BSP ji identity-mapuje) → INIT → SIPI →
  SIPI → AP reportne ready přes `ap_ready` (spin poll s timeoutem — zaseknuté AP se
  přeskočí, boot pokračuje single-core).
- **AP entry (`apEntry`)**: načte sdílenou IDT, zapne per-CPU Local APIC, reportne ready
  a **idluje** (`sti; hlt`). Scheduler je BSP-only: jen BSP programuje LAPIC timer a
  preemptuje, APy běží **žádnou kernel práci** a nesdílí žádný scheduler stav.
- **Původní premisa ADR-017 drží:** jediný bod přepnutí je BSP timer IRQ; kritické sekce
  bez locků platí, dokud se AP práce nezačne dělat. Další AP práce je výhled
  (`spec/roadmap.md`), řeší se, až to metriky vyžadují (ADR-015).
- **Známá lekce:** trampolína H5 (`getip` trik, `spec/troubleshooting.md` H5) — AP
  fault `#PF(RSVD)` při zapnutí pagingu.

---

## 5. Vztah k event loopu a invariantům

- **Kernel event loop zůstává task 0.** `poll() → update() → render()` běží jako task 0;
  preemptivní tasky poběží mezitím. IRQ → atomická fronta → smyčka (bez locků v IRQ)
  zůstává beze změny.
- **Alokátor je od M7 chráněn zakázáním preempce** v krátké kritické sekci (`irq`
  guard) — žádný concurrency refaktor alokátoru.
- **Žádné alokace v IRQ** — tick handler je krátký, bez alokace, jen atomický signál
  scheduleru; plánovací logika běží mimo ISR (`spec/invariants.md` Performance).
- **Tasky nikdy nesmí zablokovat jádro**: jen spawned tasky čekají; task 0 nikdy.

---

## 6. Invarianty

- **Kritická sekce bez locků** — IRQ maska / interrupt gate (Architecture, ADR-017).
- **Scheduler BSP-only** — APy idlují, nesdílí scheduler stav (Architecture).
- **Žádná alokace v IRQ / na tick path** (Performance).
- **Žádná alokace pro tasky** — statické TCB + stacky, task stacky nikdy z PFA
  (Performance).
- **Jediný kontext přepnutí je timer IRQ** (Architecture, ADR-008 → ADR-017).