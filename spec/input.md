# Input — Vstupní model

**Status:** V1 (draft). **Rozhodnutí:** ADR-003, ADR-008.

---

## 1. Princip

Vstup je **fronta událostí**, kterou plní IRQ handler (PS/2 klávesnice) a konzumuje hlavní
událostní smyčka (event loop). Není povoleno volat Lua přímo z IRQ kontextu — IRQ handler
jen atomicky vloží událost do fronty.

```
PS/2 IRQ → irq handler → atomický push → [fronta událostí] → event loop → dispatch → Lua
```

**Proč:** determinismus, žádná alokace v IRQ (invariant Safety), oddělení kontextu přerušení
od kontextu běžícího kódu.

---

## 2. Události (Event)

```zig
pub const Event = union(enum) {
    key_down: KeyEvent,
    key_up: KeyEvent,
    timer_tick: u64,     // číslo ticku (M2+)
};

pub const KeyEvent = struct {
    scancode: u8,
    codepoint: ?u21,     // vyplněno po dekódování (layout ASCII; layouty později)
    modifiers: Modifiers,
};
```

> **Typ `?u21` je záměrně širší než dnešní runtime:** je to Unicode scalar, stabilní
> wire formát KI (zmrazuje se dnes, `spec/kernel-interface.md` §4). Font je bitmapový
> 8×16 s pokrytím ASCII/Latin-1 — codepointy mimo rozsah fontu mapuje renderer na
> replacement znak (`spec/graphics.md` §5). Typ slibuje Unicode i pro budoucí layouty;
> runtime v M3 pokrývá podmnožinu.

pub const Modifiers = packed struct(u8) {
    shift: bool,
    ctrl: bool,
    alt: bool,
    // rezervováno
};
```

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

- **Driver:** `src/kernel/drivers/ps2.zig` — obsluha IRQ1, scancode → dekódování.
- **M2 cíl:** scancody na serial pro ladění.
- **M3 cíl:** scancode → codepoint (ASCII sady), modifikátory (Shift/Ctrl/Alt).
- **Odloženo:** USB HID, klávesnice layouty, myš (myš je samostatná událost — viz §7).

---

## 6. Mapování na Lua

Lua vidí frontu přes `api/input.zig` jako funkce:

- `input.nextEvent()` → `Event | nil`
- `input.flush()`

Události se do Lua předávají jako tabulky (`{ type = "key_down", scancode = ..., char = ... }`).
Detailní marshalování je definováno v `spec/runtime.md` §4 (Lua bindings konvence).

---

## 7. Myš (výhledově)

Není součástí M0–M4. Až přijde, platí stejný model: IRQ → atomický push → event loop.
Relativní souřadnice; absolutní pozici počítá shell/UI, ne driver.

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
