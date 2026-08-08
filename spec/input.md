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
| **Subsystem** | "Jak z různých hardware udělám jednotné zařízení" | `input.zig` — `KeyCode`/`KeyEvent`, fronta `input_queue.zig` |
| **KI** | "Jak to zařízení zpřístupním zbytku systému" | `api/input.zig` (dispatch vrstva, M2+) |

**Hraniční invariant:** za hranicí driveru nikdo nevidí konkrétní hardware. PS/2 i budoucí
USB HID produkují **stejný** `KeyEvent` — aplikace nikdy nezjistí, jaké zařízení je dole.

```
PS/2  ── scancode set-1 ──┐
                         ├─→ input.zig (KeyEvent) → fronta → KI
USB HID ── HID usage ────┘
```

---

## 2.1 Události (Event)

```zig
// subsystem, ne KI — driver produkuje, KI konzumuje
pub const KeyCode = enum(u8) {
    a, b, c, enter, escape, space,
    left, right, up, down, shift_left, shift_right, ctrl_left, alt_left,
    // ... viz src/kernel/input.zig
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
};
```

> **KeyCode je wire formát KI** (zmrazuje se dnes, `spec/kernel-interface.md` §4): je
> stabilní a hardware-neutrální. Scancode (set-1) je jen detaily driveru PS/2; USB HID
> mapuje usage → stejný `KeyCode`. Modifikátory jsou samostatné `KeyCode` (shift/ctrl/alt
> left+right), ne flagy — odpovídá M3 cíli (modifikátory → codepoint).

Sub-op čísla pro `Input` v KI: `0=nextEvent`, `1=peekEvent`, `2=flush`.

---

## 3. Fronta

- **Typ:** kruhový buffer (ring buffer) fixní velikosti.
- **Velikost:** dostatečná (např. 256 záznamů), aby se nikdy nezaplnila za normálních
  podmínek; při přetečení se události zahazují (nejstarší) a inkrementuje čítač `dropped`.
- **Vláknová bezpečnost:** IRQ kontext vs. event loop — atomické indexy (`read`/`write`
  posuny). Žádné locky v IRQ (deadlock riziko, invariant Safety).

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
- **Odloženo:** USB HID (mapuje usage → stejný `KeyCode`).

---

## 6. Mapování na Lua

Lua vidí frontu přes `api/input.zig` jako funkce:

- `input.nextEvent()` → `Event | nil`
- `input.flush()`

Události se do Lua předávají jako tabulky (`{ type = "key", code = "enter", pressed = true }`).
Detailní marshalování je definováno v `spec/runtime.md` §4 (Lua bindings konvence).

**Stav myši (M5):** Lua nečte myš z event streamu (pakety konzumuje kernel overlay
kvůli hladkosti kurzoru), ale dotazuje se sdíleného stavu přes bindings:

- `input.mouse_x()` / `input.mouse_y()` — pozice kurzoru ve framebuffer pixelech
- `input.mouse_left()` / `input.mouse_right()` / `input.mouse_middle()` — stav tlačítek

Kernel (`main.zig` `poll()`) aktualizuje `input.mouse_state` z každého paketu; overlay
a shell čtou stejné hodnoty, takže kliknutí a drag souhlasí s vykresleným kurzorem.

---

## 7. Myš (PS/2, M5)

PS/2 myš (IRQ12, druhý port i8042) — hotovo v M5. Model odpovídá klávesnici:
IRQ → atomický push do vlastní fronty (`input_queue.mouse`, nezávislá na klávesnici,
aby aktivní myš nevyhladověla klávesy/Lua) → event loop.

- **Paket:** standardní 3-byte PS/2 (b0 = tlačítka + sign/overflow flagy, b1/b2 = delta).
- **Decode:** `input.decodeMousePacket` — čistá funkce, host-testovaná
  (`tests/input/mouse_test.zig`): resync na paket-start bitu 3 (0x08), odmítnutí
  přetečených delt (bity 6/7), `dy = -dy` (PS/2 +dy = nahoru, obrazovka y roste dolů).
- **Driver:** `src/kernel/drivers/ps2.zig` — sdílený i8042 s klávesnicí; každý IRQ
  konzumuje jen bajty, které status bit 5 označí jako jeho zařízení. Detailní ladění
  viz `spec/troubleshooting.md` sekce 8 (C18–C26).
- **Kurzor:** kernel overlay (`render/mouse_cursor.zig`) — ukládá/obnovuje pixely pod
  kurzorem, pohyb vykreslí jen 12×19 px místo celé obrazovky.
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
- **Event loop je jediný konzument** (Architecture).
