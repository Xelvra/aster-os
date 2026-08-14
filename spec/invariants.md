# Invarianty Aster OS

**Status:** V1 (draft). **Rozhodnutí:** ADR-002, ADR-003, ADR-008, ADR-009, ADR-017.
**Účel:** kontrolní seznam při každém code review. Kód, který porušuje invariant, **není
hotový**, i kdyby build a testy prošly.

Invarianty jsou rozdělené na tři skupiny: **Safety**, **Performance**, **Architecture**.

---

## 1. Safety (bezpečnost kódu)

Invarianty proti UB, memory chybám a nedefinovanému chování.

- [ ] **Žádný undefined behavior.** Žádné out-of-bounds, signed overflow, přetečení
      bufferu, dangling pointer. `-DReleaseSafe` a `-DReleaseFast` chování musí být
      konzistentní v kritických cestách; **jádro se buildí v `ReleaseSafe`**.
- [ ] **Fault policy (neopravitelná chyba):** bezpečnostní chyba zachycená
      `ReleaseSafe` (panic ze safety checku) ani HW fault (double fault, GPF, page
      fault na špatné adrese) se **neopravuje a nepokračuje**. Cíl je **halt s výpisem
      na serial** (stav registrů, typ faultu, částečný backtrace), žádný reset, žádné
      tiché pokračování. Pravidlo „nepanic v Release buildu" (z pravidel projektu) se
      vykládá jako: **nevoláme `panic` jako chybový mechanismus** (chyby se řeší error
      union / `KiStatus`); safety panic z `ReleaseSafe` je **záměrné, konečné chování** —
      halt handler, ne bug.
      Definice chování je v `roadmap.md` M2 (IDT handlers).
      **Backtrace v kernelu:** částečný stack trace se tiskne **freestanding přístupem**
      (žádný hostitelský debugger) — chůze po frame pointerech / vyčtení návratových
      adres ze stacku, přes `@returnAddress()`/`@frameAddress()` v panic handleru.
- [ ] **Žádný use-after-free.** Každá alokace má jasného vlastníka a životní cyklus.
- [ ] **Žádná alokace v IRQ kontextu.** IRQ handler jen atomicky manipuluje s předem
      alokovanými strukturami (fronta událostí). Žádný `allocator.alloc` v přerušení,
      žádné locky v přerušení (deadlock riziko).
- [ ] **ISR zachovává kompletní stav CPU vč. XMM.** Kernel běží se SSE povoleným a
      kompilátor generuje `movdqu`/`movups` pro kopie structů i v nefloatovacím kódu.
      Přerušení může dorazit mezi load a store takového páru, takže ISR musí uložit a
      obnovit **všechny** scratch registry (GPR i XMM0–XMM15, `isr.s`) — zapomenutí
      kteréhokoli vede k poškození hodnoty v přerušeném kódu (C35, handoff H4). Pokud
      se `isr_common` mění, save/restore se musí rozšířit o totéž. Vektory v `frame`
      jsou maskované na 8 bitů v `isr_common` (C35; hlídá `assert(frame.vector <= 0xFF)`
      na vstupu `handleIsrImpl`).
- [ ] **Žádná rekurze v kritických cestách** (kernel, IRQ, rendering).
- [ ] **Žádné tiché selhání.** Každá funkce, která může selhat, vrací `KiStatus` /
      explicitní chybovou hodnotu. Žádný prázdný `catch {}` bez zdůvodnění.
- [ ] **Interrupt-friendly matematika:** indexy front jako atomické `usize`, nikdy
      ne-konzistentní čtení dvou souvisejících proměnných bez zámku/atomiky.
- [ ] **Task/kernel zásobníky mají overflow kanárek kontrolovaný při přepnutí kontextu**
      (ADR-017, `sched/task.zig`, `main.zig`): každý `task_stacks[i]` i `kernel_stack`
      nese magic slovo na nejnižší adrese; přetečení zásobníku (rekurze, velký frame)
      by jinak potichu přepsalo sousední stack v kontinuálním poli. Porušení kanárku =
      halt s výpisem na serial (fault policy výše), ne pokračování. Jedná se o
      softwarovou kontrolu se zpožděním (detekce až při dalším přepnutí) — plnohodnotná
      MMU guard page v SASOS/Ring 0 bez per-task page tables neexistuje
      (`spec/non-goals.md`). Analogie: heap `block_magic` v `mem/heap.zig`.

## 2. Performance (výkon)

Invarianty proti plýtvání v kritických cestách. Měří se po každém milníku (roadmapa).

- [ ] **Žádná kopie celého framebufferu.** Renderer píše přímo do GOP paměti. Prezentace =
      přímý zápis. Výjimka: kurzor myši ukládá/obnovuje 12×19 px pod kurzorem
      (`render/mouse_cursor.zig`) — dílčí save/restore, ne kopie bufferu.
- [ ] **Žádný heap allocation při renderingu.** Renderovací primitiva používají stack /
      statické buffery.
- [ ] **Žádná dynamická alokace v běžném frame.** Event loop nesmí v `render()` ani v
      běžné `update()` alokovat (mimo boot a ojedinělé eventy jako spawn).
- [ ] **Frame latency (p99) je primární metrika**, ne FPS (viz `roadmap.md`).
- [ ] **PFA alokace jsou hint-optimalizované bez lineárních průchodů na hot pathu.**
      `findFirstFree`/`findFirstFreeRun` startují od `next_free_hint` (wrap-around)
      a `totalFreePages()` vrací inkrementálně udržovanou cache — žádný plný scan
      bitmapy při každém volání (viz `spec/memory.md` §3).
- [ ] **UI kreslení = 0 syscallů a 0 ring přechodů** (SASOS). Pokud se v budoucnu objeví
      ring přechod v kritické cestě, musí být zdokumentovaný a odůvodněný.

## 3. Architecture (architektura)

Invarianty proti rozlezení vrstev. Nejvíce pomáhají při review, protože odhalují
neviditelné závislosti.

- [ ] **Runtime nesmí záviset na kernel internals.** Runtime volá jen KI. Kernel nezná
      jméno žádného runtime (Lua/Wasm/Native je za `Runtime.spawn`).
- [ ] **Lua nesmí zapisovat do kernelových struktur.** Veškerý přístup z Lua jde přes
      `api/*` moduly. Žádný přímý import `fb`, `pfa`, `idt` apod. z bindings.
- [ ] **Renderer nesmí znát Lua VM.** Rendering je čistě Zig; žádná zpětná vazba na
      skriptový stav.
- [ ] **Framebuffer nesmí uniknout za Renderer.** Jediný, kdo píše do framebufferu, je
      Renderer.
- [ ] **Event loop je jediný konzument vstupní fronty.** IRQ jen plní.
- [ ] **Concurrency (M0–M6):** single-thread, kooperativní smyčka — **žádné locky
      nejsou potřeba**, protože neběží dva kontexty najednou. Sdílený stav IRQ ↔ loop
      jde jen přes dokumentovaný mechanismus (atomická fronta událostí, `spec/input.md`).
- [ ] **Concurrency (M7+):** preemptivní RR scheduler na jednom jádře (ADR-017).
      „Žádné locky“ se transformuje na: **kritické sekce se zakázanou preempcí**
      (IRQ maska), žádné spinlocky/mutexy/atomy v běžném toku. Single-core — preempce
      jen v IRQ od timeru, jediný kontext přepnutí. **Kritické sekce pokrývají i sdílené
      struktury alokátorů** (PFA bitmapa + hinty, heap free-list) — ne jen TCB tabulku
      scheduleru (`mem/pfa.zig`, `mem/heap.zig`, `cpu/irq.zig`).
- [ ] **Žádný cross-layer import napřímo:** `shell → api/* → (renderer, runtime, ...) →
      (fb, pfa, ...)`. Jakákoli odchylka = porušení KI (viz `kernel-interface.md` §4).

---

## Jak se invarianty vynucují

1. **Kódem:** `zig build test` (host testy) + QEMU smoke test — verifikace je povinná,
   viz `spec/verification.md`.
2. **Nástroji:** `zig fmt --check`, lint/analyze.
3. **Lidsky:** každý PR/commit review prochází tento checklist (Safety → Performance →
   Architecture). Nedostatečné zdůvodnění porušení = blokace.
4. **Konvencí:** kontrakty psané v `kernel-interface.md` jsou závazné; porušení = nový ADR.

---

## Známá rizika (vědomě přijatá)

- SASOS znamená: bug v nativním Zig kódu může zkorumpovat cokoli. Zmírnění: Lua skripty a
  Wasm moduly běží v managed runtime (nižší riziko paměťové korupce), nativní kód je námi
  psaný a prochází tímto checklistem. Viz `spec/non-goals.md` a ADR-002.
- Ring 0 = jakýkoli bug má plný hardware přístup. Testy + QEMU smoke jsou proto součást
  Definition of Done.
