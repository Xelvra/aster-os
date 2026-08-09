# Input — Vstupní model

**Status:** V1 (draft). **Rozhodnutí:** ADR-003, ADR-008.

---

## 1. Princip

Vstup je **fronta událostí**, kterou plní IRQ handler (PS/2 klávesnice) a konzumuje hlavní
událostní smyčka (event loop). Není povoleno volat Lua přímo z IRQ kontextu — IRQ handler
jen atomicky vloží událost do fronty.

```
PS/2 IRQ → driver (scancode → KeyCode) → subsystem (KeyEvent) → fronta → event loop → dispatch → Lua
```

**Proč:** determinismus, žádná alokace v IRQ (invariant Safety), oddělení kontextu přerušení
od kontextu běžícího kódu.

---

## 2. Architektura: driver / subsystem / KI

Tři oddělené vrstvy (viz také `spec/adr/020-future-extensibility.md`):

| Vrstva | Odpovědnost | Příklad |
|---|---|---|
| **Driver** | "Jak mluvím s hardwarem" | `drivers/ps2.zig` — IRQ1, i8042, scancode set-1 → `KeyCode` |
| **Subsystem** | "Jak z různých hardware udělám jednotné zařízení" | `input/service.zig` — jediná hranice subsystemu: fronta, mouse state, layout, mapování |
| **KI** | "Jak to zařízení zpřístupním zbytku systému" | `api/input.zig` (dispatch vrstva, M2+) |

**Hraniční invariant:** za hranicí driveru nikdo nevidí konkrétní hardware. PS/2 i budoucí
USB HID produkují **stejný** `KeyEvent` — aplikace nikdy nezjistí, jaké zařízení je dole.

```
PS/2  ── scancode set-1 ──┐
                         ├─→ service.zig (KeyEvent) → fronta → KI
USB HID ── HID usage ────┘
```

> **Hranice subsystemu:** `input_queue.zig` je **interní implementační detail** Input
> subsystemu. Kernel event loop (main) i KI (`api/input`) k frontě, mouse stavu i layoutu
> přistupují **výhradně přes `input/service.zig`**. Producenti v IRQ kontextu (PS/2, APIC
> timer) pushují přes `service.pushKeyEvent/pushMouseEvent/pushTimerTick`. Service neurčuje
> grafické chování mouse eventů — předává je event loopu, který je aplikuje na cursor
> overlay (cursor žije v graphics vrstvě, ne v input subsystemu). Porušení tohoto pravidla
> je regrese architektonické hranice (`kernel-interface.md` §4.7).

---

## 2.1 Události (Event)

```zig
// subsystem, ne KI — driver produkuje, KI konzumuje
pub const KeyCode = enum(u8) {
    a, b, c, enter, escape, space,
    left, right, up, down, shift_left, shift_right, ctrl_left, alt_left,
    // ... viz src/kernel/input/input.zig
};

pub const KeyEvent = struct {
    code: KeyCode,
    pressed: bool,   // true = key_down, false = key_up
};
```

```zig
pub const Event = union(enum) {
    timer_tick: u64,     // číslo ticku (M2+)
    key: KeyEvent,
    mouse: MouseEvent,   // konzumuje kernel overlay; KI next_event ji filtruje, Lua ji nikdy nevidí
};
```

> **KeyCode je wire formát KI** (zmrazuje se dnes, `spec/kernel-interface.md` §4): je
> stabilní a hardware-neutrální. Scancode (set-1) je jen detaily driveru PS/2; USB HID
> mapuje usage → stejný `KeyCode`. Modifikátory jsou samostatné `KeyCode` (shift/ctrl/alt
> left+right), ne flagy — odpovídá M3 cíli (modifikátory → codepoint).

Sub-op čísla pro `Input` v KI: `0=next_event`, `1=peek_event`, `2=flush`, `3=mouse_x`,
`4=mouse_y`, `5=mouse_left`, `6=mouse_right`, `7=mouse_middle`, `8=set_layout`,
`9=layout_name` (myš se čte jako stav, ne event — §6; layout viz §5, ADR-024).
Implementace: `api/input.zig` (`sys.dispatch(.Input, ...)`).

---

## 3. Fronta

Fronta je interní detail subsystemu, přístupná jen přes `service.zig` (§2).

- **Typ:** kruhový buffer (ring buffer) fixní velikosti.
- **Velikost:** dostatečná (např. 256 záznamů), aby se nikdy nezaplnila za normálních
  podmínek; při přetečení se události zahazují (nejstarší) a inkrementuje čítač `dropped`.
- **Vláknová bezpečnost:** IRQ kontext vs. event loop — atomické indexy (`read`/`write`
  posuny). Žádné locky v IRQ (deadlock riziko, invariant Safety).
- **Producenti i konzumenti jdou přes service:** IRQ pushuje
  (`pushKeyEvent`/`pushMouseEvent`/`pushTimerTick`), event loop čte kernel eventy
  (`peekKernelEvent`/`popKernelEvent` + mouse `peek`/`pop`), KI čte aplikáční eventy
  (`nextEvent`/`peekEvent`/`flush`). Dva konzumující mechanismy (kernel orchestrace
  v `main`, KI `next_event`) sdílejí jeden execution context (event loop) — žádný
  paralelní konzument.

---

## 4. Event loop

Jediná smyčka systému (ADR-008):

```zig
while (true) {
    poll();   // vyprázdni IRQ frontu do událostí, aktualizuj stav klávesnice
    update(); // odešli události Lua, aktualizuj stav UI
    render(); // Graphics API → Renderer → Framebuffer
}
```

---

## 5. Klávesnice (PS/2)

- **Driver:** `src/kernel/drivers/ps2.zig` — obsluha IRQ1, i8042 init, scancode set-1
  → `KeyCode` (mapovací tabulka), push `KeyEvent` do fronty.
- **M2 stav:** `KeyEvent` (code + pressed) na serial pro ladění — ověřeno v QEMU
  (`key a down`, `key enter up`, ...).
- **M3 stav:** `KeyCode` → ASCII codepoint s modifikátorem shift (`keyToCodepoint`),
  konzole vypisuje znaky na obrazovku (psaní viditelné v QEMU).
- **M4 stav:** klávesy jdou do Lua shellu přes `input.next_event()`; kernel v `poll()`
  zpracovává jen timer ticky a klávesy nechává ve frontě (F5 vyhraděno pro hot reload).
- **M5 stav:** super klávesa (Win): `KeyCode.super_left/right` z PS/2 extended scancodů
  `0x5B`/`0x5C`; Lua vidí stav přes `ev.super` (modifikátor jako shift/ctrl/alt).
- **Layout infrastruktura:** `src/kernel/input/layout.zig` je jediné místo, které zná
  rozložení klávesnice (`KeyCode × shift/ctrl → char`, US 105+). KI binding
  `input.next_event()` posílá Lua **připravený `char`** — Lua nic nemapuje. Přidání
  jiného layoutu (národní znaková sada) = nová datová tabulka v `layout.zig`, bez
  změny logiky. Host testy: `tests/input/layout_test.zig`.
- **Multi-layout (ADR-024, M6):** aktivní layout se přepíná za běhu přes KI
  `input.set_layout(name)` / `input.layout_name()`; Lua bindingy `input.set_layout()`
  a `input.layout_name()` existují (ověřeno runtime testem přes celou cestu
  Lua → binding → KI → service → registry). CZ je QWERTZ (Y↔Z prohozené) s ASCII
  fallbackem (8x16 font neumí diakritiku). Layout registry čte/píše jen
  `service.zig` — nikdo jiný.
- **Budoucí:** USB HID (mapuje usage → stejný `KeyCode`) — potvrzený cíl (rozhodnutí 2026-08-09, viz `roadmap.md` Fáze 2), zatím PS/2.

---

## 6. Mapování na Lua

Lua vidí frontu přes `api/input.zig` (`sys.dispatch(.Input, ...)`) jako funkce:

- `input.next_event()` → `Event | nil` (myší pakety filtruje KI — kernel overlay je
  konzumuje v `poll()`, busy myš nemůže zaplavit Lua event stream)
- `input.mouse_x()`, `input.mouse_y()`, `input.mouse_left()`, `input.mouse_right()`,
  `input.mouse_middle()` — stav myši

`peek_event` a `flush` jsou KI sub-opy (zmrazené), Lua binding zatím neexponují.
Události se do Lua předávají jako tabulky (`{ type = "key", code = "enter", pressed = true }`).
Detailní marshalování je definováno v `spec/runtime.md` §4 (Lua bindings konvence).

**Stav myši (M5):** Lua nečte myš z event streamu (pakety konzumuje kernel overlay
kvůli hladkosti kurzoru), ale dotazuje se sdíleného stavu přes bindings:

- `input.mouse_x()` / `input.mouse_y()` — pozice kurzoru ve framebuffer pixelech
- `input.mouse_left()` / `input.mouse_right()` / `input.mouse_middle()` — stav tlačítek

Kernel (`main.zig` `poll()`) čte myš z event loopu přes `service.popMouseEvent()`,
aplikuje paket na cursor overlay (`mouse_cursor.move`) a výslednou pozici/tlačítka
uloží do `service.setMouseState(...)`; overlay i shell čtou stejné hodnoty (přes
`service`), takže kliknutí a drag souhlasí s vykresleným kurzorem.

---

## 7. Myš (PS/2, M5)

PS/2 myš (IRQ12, druhý port i8042) — hotovo v M5. Model odpovídá klávesnici:
IRQ → atomický push do vlastní fronty (nezávislá na klávesnici, aby aktivní myš
nevyhladověla klávesy/Lua) → event loop. Producenti i konzumenti jdou přes
`service.zig` (§2), nikdo nepíše do myší fronty napřímo.

- **Paket:** standardní 3-byte PS/2 (b0 = tlačítka + sign/overflow flagy, b1/b2 = delta).
- **Decode:** `input.decodeMousePacket` — čistá funkce, host-testovaná
  (`tests/input/mouse_test.zig`): resync na paket-start bitu 3 (0x08), odmítnutí
  přetečených delt (bity 6/7), `dy = -dy` (PS/2 +dy = nahoru, obrazovka y roste dolů).
- **Driver:** `src/kernel/drivers/ps2.zig` — sdílený i8042 s klávesnicí; každý IRQ
  konzumuje jen bajty, které status bit 5 označí jako jeho zařízení. Detailní ladění
  viz `spec/troubleshooting.md` sekce 8 (C18–C26).
- **Kurzor:** kernel overlay (`render/mouse_cursor.zig`) — ukládá/obnovuje pixely pod
  kurzorem, pohyb vykreslí jen 12×19 px místo celé obrazovky. Kurzor je privilegovaná
  graphics overlay vrstva (mimo Renderer), ne součást input subsystemu — `service.zig`
  o framebufferu neví (`spec/graphics.md` §7).
- **Absolutní souřadnice:** počítá kernel (clamp na framebuffer); shell čte přes §6.

---

## 8. Budoucí cesta: IRQ routing (Ring 3 fáze)

Až se ovladače přesunou mimo jádro (fáze oddělování, viz ADR-018), zůstane pipeline
`IRQ → krátký handler → fronta`, ale cílová strana se stane **službou přihlášenou o
konkrétní IRQ**; kernel jí doručí notifikaci jako zprávu do mailboxu. Event loop
zůstává jediným konzumentem událostí — jen konzumuje z mailboxu služby místo přímo
z kernel fronty. Do M7 platí model z §1–§5 beze změny.

---

## 9. Invarianty

- **Žádná alokace v IRQ** (Safety).
- **Žádné volání Lua z IRQ** (Safety, Architecture).
- **Fronta se nikdy nepřeteče při běžné práci**; `dropped` je sledovaná metrika.
- **Event loop je jediný execution context, který frontu konzumuje** (Architecture).
  Spotřeba je rozdělená mezi kernel orchestraci (`main.poll`) a KI (`input.next_event`),
  oba přes `service.zig` — nikdy paralelně.
- **Přístup k frontě, mouse stavu a layoutu jen přes `input/service.zig`** (Architecture).
  `api/input`, `main`, IRQ producenti ani testy neimportují `queue.zig`/`layout.zig`
  napřímo (regresní ochrana hranice, `kernel-interface.md` §4.7).
- **Service neví nic o framebufferu ani cursoru** (Architecture) — mouse events předává
  event loopu, který je aplikuje na cursor overlay (graphics vrstva).
