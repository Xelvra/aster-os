# Memory — Správa paměti a alokátory

**Status:** V1 (draft). **Rozhodnutí:** ADR-002, ADR-010, ADR-017.
**Rozsah:** fyzická správa paměti (PFA), obecný alokátor nad ní a vazba na `lua_Alloc`.

---

## 1. Principy

- Paměť je spravovaná **dvěma vrstvami**: PFA (stránky) → obecný alokátor (bloky).
  PFA je fyzický správce stránek; obecný alokátor dělí stránky na libovolně velké bloky.
- **`mem.Memory` je zapouzdřující střední vrstva** — vlastní `pfa`, heap alokátor
  a bitmapu. Veřejná rozhraní navenek: `allocator()` (Zig `Allocator`) a `stats()`
  → `MemStats{total_bytes, free_bytes}` (pro Sysmon KI). PFA zůstává schovaná za
  `Memory`; `api/*` nikdy neimportuje `pfa` napřímo (`kernel-interface.md` §4.7).
- Žádný skrytý ani globální alokátor. Každá alokace má **jasného vlastníka a právě jedno
  místo uvolnění**; alokátor se předává explicitně (`spec/code-style.md` §3).
- **Žádná alokace na kritických cestách** (IRQ, render, event loop render) — invariant
  Performance (`spec/invariants.md`).
- Heap alokace jen když je nutná; preferuje se stack a statické buffery.
- Paměť se nealokuje v IRQ kontextu; IRQ handler používá předem alokované struktury.
- Kernel je jednojadrový do M7; od M7 je alokátor chráněn vypnutím preempce
  (ADR-017), žádné locky. Konkrétně: manipulace se sdílenými strukturami alokátoru
  (PFA bitmapa + `next_free_hint`/`free_pages`, heap `free_list`) běží v kritické sekci
  s maskovanými IRQ — `cpu/irq.zig` (`InterruptGuard`, RFLAGS-based, vnořitelné: restore
  jen když guard sám IRQ zrušil). Preemptivní scheduler (M7+) by jinak nechal druhou
  úlohu alokovat na nekonzistentní bitmapě/free-listu.

---

## 2. Paměťová mapa (fyzická RAM)

Vstupem je **Limine memory map** (ADR-012). Kernel čte rozsahy `usable` a `reserved`
z Limine handoff a postaví z nich statickou mapu:

| Oblast | Obsah | Správce |
|---|---|---|
| Kernel image | načtený Liminem (kernel + sekce) | statický, nikdy se neuvolňuje |
| Limine handoff data | struct handoff, memory map, GOP info | statický, rezervováno |
| Framebuffer | GOP framebuffer (Limine) | mimo PFA — nikdy se nealokuje |
| Stohy | kernel stack + task stacky | staticky alokované |
| **PFA bitmapa** | bitmapa volných obsazených stránek | PFA, alokuje se z první volné paměti |
| **Heap region** | stránky PFA → obecný alokátor | obecný alokátor, roste z PFA |
| Zbytek RAM | volné stránky | PFA |

Mapa je **statická po bootu**: rozsahy se nedynamicky mění, žádné přemapování, žádný VMM
do fáze oddělování (Ring 3). Paging zůstává ploché mapování z Limine (ADR-002, `roadmap.md` M1).

---

## 3. PFA — Page Frame Allocator

Soubor: `src/kernel/mem/pfa.zig`.

- **Granularita:** 4 KiB stránky.
- **Struktura:** bitmapa — 1 bit na stránku. Bitmapa žije ve vlastní, předem rezervované
  oblasti paměti (alokuje se při initu z prvních volných stránek).
- **API:**
  ```zig
  pub const PageFrameAllocator = struct {
      pub fn init(memory_map: LimineMemoryMap, bitmap_budget: usize) PfaError!Pfa;
      pub fn allocPage(self: *Pfa, zero: bool) PfaError!u64;   // fyzická adresa
      pub fn freePage(self: *Pfa, addr: u64) PfaError!void;
      pub fn allocPages(self: *Pfa, count: usize, zero: bool) PfaError![]u64;
      pub fn freePages(self: *Pfa, addrs: []const u64) void;
  };
  ```
- **Chování:** `allocPage` najde první volný bit od `next_free_hint` (s wrap-around),
  označí ho a vrátí fyzickou adresu. Hint je optimalizace „kde zkoušet nejdřív", ne
  garance: `freePage` ho snižuje pod nově uvolněnou stránku, takže se uvolněné stránky
  znovu použijí první, ale korektnost na přesnosti hintu nezávisí.
  `zero: true` vynuluje stránku před vrácením (bezpečnostní default — žádné uvolnění
  původního obsahu do rukou nového vlastníka). `freePage` maže bit; **nikdy nepřiděluje
  stejnou stránku dvakrát bez mezilehlého free**.
- **Cache volných stránek:** `free_pages` se udržuje inkrementálně (počítáno v `init`,
  `±1`/`±count` na alokacích/uvolněních) a `totalFreePages()` vrací cache místo
  lineárního průchodu bitmapy — ten zůstal jen jako boot-time inicializace.
- **Chyby:** out-of-memory se vrací jako `PfaError.OutOfMemory`, nikdy `panic` —
  volající se rozhodne (typicky = neopravitelný stav → fault policy, `spec/invariants.md`).
- **Determinismus:** alokace první volné stránky → stejný běh = stejné adresy
  (nezbytnost pro reprodukovatelný build, ADR-014).

> PFA je záměrně **pouze stránkový**. Nepoužívá se přímo pro Lua ani pro malé objekty —
> hrubozrnné (stránky) by plýtvalo pamětí. Slouží jako základ obecnému alokátoru (§4).

---

## 4. Obecný alokátor (heap)

Soubor: `src/kernel/mem/heap.zig`.

### 4.1 Proč

`lua_Alloc` a běžné kernelové alokace (stringy, tabulky, handly) potřebují libovolnou
velikost s `realloc`/`free`. PFA stránky jsou příliš hrubé. Mezi PFA a spotřebiteli je
proto **jeden obecný alokátor**.

### 4.2 Návrh

- **Algoritmus:** first-fit free list s hranicemi (boundary tags). Header i footer
  každého bloku nesou velikost + flag `free`. Sousední volné bloky se při free
  coalescují. (Nejjednodušší správné řešení pro obecné malloc/realloc/free;
  žádný complex allocator.)
- **Zdroj stránek:** při vyčerpání volných bloků alokátor požádá PFA o **další stránku**
  a rozdělí ji na bloky. Heap tak roste dynamicky.
- **Zarovnání:** minimálně `alignof(max_align)` (16 B); velikosti zaokrouhlené na
  blok hlavičku.
- **API (vyhovuje Zig `std.mem.Allocator` rozhraní):**
  ```zig
  pub const HeapAllocator = struct {
      pub fn init(pfa: *Pfa) HeapAllocator;
      pub fn allocator(self: *HeapAllocator) std.mem.Allocator;
  };
  ```
  Všichni konzumenti dostávají `std.mem.Allocator` **explicitně parametrem** — žádný
  globální `allocator` symbol.
- **Zeroing:** nově rozdělené stránky z PFA jsou vynulované (viz §3); nové bloky tak
  začínají na nule. `realloc`/`free` nepřepisují data za hranicí bloku.

### 4.3 Vlastnictví

- Heap region vytváří a uvolňuje **jen memory subsystém**.
- Každá alokace má právě jednoho vlastníka; vlastník ji i uvolňuje (`defer`/`errdefer`).
- Kernel po bootu nemá žádnou "součástkovou" alokaci — kdo alokuje, viditelně drží
  alokátor v podpisu.

---

## 5. `lua_Alloc` — vazba Lua na obecný alokátor

Lua volá paměť přes `lua_Alloc` (`void* (*)(void* ud, void* ptr, size_t osize, size_t nsize)`).

- `ud` = ukazatel na instanci `HeapAllocator` (explicitně předaný při `lua_newstate`).
- Sémantika `lua_Alloc` se mapuje 1:1 na heap:
  - `nsize == 0` → `free(ptr)` a návrat `null`,
  - `ptr == null` → `alloc(nsize)`,
  - jinak → `realloc(ptr, nsize)`.
- Žádná samostatná Lua alokace — Lua používá **stejný** alokátor jako kernel, jeden
  zdroj pravdy pro paměť.
- `lua_Alloc` se **nikdy nevolá v IRQ ani v render** (invariant Performance platí i pro VM).

---

## 6. Framebuffer cache atributy (UC vs WC)

- GOP framebuffer od Limine je zmapovaný **ploše**; cache atribut závisí na tom, jak
  Limine stránky nasetoval.
- **Měření z M1:** Limine 12.5.2 v QEMU mapuje framebuffer jako **WC** (Write-Combining)
  — ověřeno `src/kernel/mem/cache_attr.zig` (page table walk + PAT MSR), výpis na serial
  `framebuffer cache: wc`.
- Zápis do UC paměti je řádově pomalejší než WC; protože je framebuffer **již WC**, riziko
  pro frame latency (`roadmap.md`, KPI) v M3 nehrozí z cache atributu.
- Pokud by jiná platforma/firmware mapovala framebuffer jako UC a měření v M3 ukáže, že to
  táhne frame latency nad cíl, přepneme se na WC **pouze pro framebuffer region** — minimální
  zásah do stránkování, ne VMM.

---

## 7. Invarianty

- **Žádná alokace v IRQ / render / event loop render** (Safety, Performance).
- **Každá alokace má jasného vlastníka a právě jedno místo uvolnění** (Safety).
- **Alokátor se předává explicitně; žádný globální alokátor** (Architecture).
- **Lua a UI nikdy nealokují přímo přes PFA** — jen přes KI a přes běžný allocator
  (Architecture, `spec/kernel-interface.md` §4).
- **PFA nikdy nepřidělí stejnou stránku dvakrát bez mezilehlého free** (Safety).
