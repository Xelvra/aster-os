# ADR-017 — Concurrency model M7 (preemptivní scheduler)

**Status:** Accepted
**Datum:** 2026-08-06

> **Status update (2026-08-17):** implementováno v M7 — `sched/task.zig`, blokující
> primitiva `sched/sync.zig` (semafor, mutex, event group, message queue), error
> handler tasků. **SMP:** bring-up AP jader je hotový (MADT, `cpu/smp.zig`), ale
> **scheduler zůstává BSP-only** — APy po bring-up idlují (`sti; hlt`) a neběží žádnou
> kernel práci. Původní premisa „single-core, jediný bod přepnutí" tedy drží pro
> scheduler; další AP práce je výhled (viz `spec/roadmap.md`).

## Rozhodnutí
Od M7 běží na jednom jádře **preemptivní round-robin scheduler pro více úkolů**
(výhledově Lua státy, Wasm instance, nativní tasky) ve sdíleném adresním prostoru.
Mezi M0–M6 zůstává **jediná kooperativní event loop** beze změn; M7 na ni navazuje
jako rozšíření, ne přepis.

## Odůvodnění
M0–M6 mají bezpečnostní argument založený na kooperativní smyčce: nikdy neběží dva
kontexty zároveň, IRQ jen atomicky plní frontu, locky nejsou potřeba
(`spec/invariants.md`). ADR-008 plánoval preempci až s reálnými wasm/nativními tasky
(M7). Je potřeba **rozhodnout dnes**, jak se invariant "žádné locky" vyřeší v M7,
aby M0–M6 mohly stavět na kooperativním modelu, aniž by se později předělávaly.

Klíčový fakt: **single-core, sdílený adresní prostor.** Preempce probíhá jen
v přerušení od časovače (jediný bod přepnutí), ne paralelně na více jádrech.
To znamená, že sdílený stav chrání **zakázání preempce** (IRQ maska) v krátkých
kritických sekcích — nikoli klasické locky (spinlocky/mutexy), které by v single-core
designu znamenaly zbytečnou režii a deadlock riziko.

## Důsledky
- **M0–M6:** kooperativní smyčka, "žádné locky" zůstává v plné platnosti. Kód psaný
  teď se nepřepisuje.
- **M7+:** sdílený stav mezi úkoly chrání **kritické sekce se zakázanou preempcí**
  (IRQ maska na časování ticku scheduleru). Žádné spinlocky, mutexy ani atomické
  CAS smyčky v běžném toku.
- **Blokující synchronizační primitiva (M7, task-task):** kritická sekce chrání jen
  krátký sdílený stav. Pro čekání úkolu na zdroj/synchronizaci se v M7 přidají
  **blokující primitiva**: semafor, mutex (volitelně s priority inheritance), event
  group, message queue. Čekající úkol se odebere z ready fronty (neblokuje jádro),
  scheduler přepne na jiný úkol; probuzení obstará manipulace s primitivem v kritické
  sekci. Odklad na M7 je záměrný (YAGNI) — v M0–M6 neexistují.
- **Error handler úkolu (M7):** task vrací `anyerror!void`; při chybě se zavolá jeho
  error handler a úkol se ukončí nebo obnoví podle politiky. **Chyba jednoho úkolu
  nikdy neshodí jiný úkol ani kernel** (obdoba error containmentu Lua, `spec/runtime.md` §5).
- **Jediný kontext přepnutí je IRQ od timeru** (ADR-008 → tento). Tick handler je
  krátký, bez alokace, jen atomický signál scheduleru; plánovací logika běží mimo IRQ.
- **Synchronizace IRQ ↔ task** zůstává jako dnes: atomická fronta událostí
  (`spec/input.md`), žádné locky v IRQ.
- **Alokátor (spec/memory.md)** je od M7 chráněn zakázáním preempce v krátké
  kritické sekci — žádný concurrency refaktor alokátoru.
- **Isolace zůstává jazyková** (Lua managed, Wasm lineární paměť, native = náš kód
  s plnou důvěrou). Žádná MMU izolace (ADR-002) se nepřidává.
- Počet úkolů a velikost kvanta se nastaví z měření (ADR-015), ne z předpovědi.

## Související
- ADR-002 (single address space), ADR-008 (event loop, superseded for M7 scheduler)
- `spec/invariants.md` (Performance/Architecture), `spec/roadmap.md` (M7),
  `spec/timer.md`, `spec/memory.md`, `spec/runtime.md` (§5)
