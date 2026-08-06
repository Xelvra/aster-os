# ADR-018 — Transport KI v Ring 3: mailbox IPC, comptime dispatch, IRQ routing

**Status:** Accepted (rozhodnutí o budoucí fázi)
**Datum:** 2026-08-06

## Rozhodnutí
Ve fázi oddělování (Ring 3, výhledově od M8+) se přechod KI z přímých volání na
skutečný transport provede tímto jednotným návrhem:

1. **IPC = mailbox zprávy.** Zpráva nese identifikátor cíle (port), odesílatele a
   payload s argumenty operace. Odeslání je asynchronní (neblokující), přijetí
   blokující s čekací frontou; mailbox drží frontu zpráv i frontu čekajících vláken.
2. **Comptime generovaný dispatch.** Handlery KI zůstávají obyčejné typované Zig
   funkce. Obal, který vyzvedne argumenty z transportu (dnes registry, zítra payload
   zprávy) a vrátí výsledek, se generuje comptime z podpisu funkce. `dispatch` je jen
   směrovač bez ruční registrace argumentů.
3. **IRQ routing do služeb.** Driver/služba se přihlásí o konkrétní IRQ; kernel jí
   doručí notifikaci jako zprávu do mailboxu. IRQ handler zůstává krátký a bez
   alokace (jen atomický signál); veškerá logika běží v kontextu služby.

## Odůvodnění
- KI je stabilní šev (ADR-003, ADR-004): volající kód se nesmí změnit, ať je pod ním
  volání funkce nebo IPC. Definovaný tvar zprávy zaručí, že evoluce nevyžaduje přepis.
- Comptime dispatch drží KI čitelné a typově bezpečné; přidání operace nevyžaduje
  ruční registraci a chyba typu se chytí v compile-time.
- IRQ routing přes mailbox umožní vyjmout ovladače (PS/2) z jádra beze změny modelu
  vstupu — jediný konzument fronty zůstává, jen se za něj dosadí služba.

## Důsledky
- **Neimplementuje se před Ring-3 fází.** Toto je rozhodnutí o budoucím transportu;
  v M0–M6 (kooperativní smyčka, Ring 0) nic nemění (`spec/non-goals.md`, YAGNI,
  `spec/roadmap.md` M8).
- Wire formát budoucího IPC se odvodí z tvaru zprávy zde; KI čísla operací (§3.1 v
  `spec/kernel-interface.md`) se stávají identifikátory operací ve zprávách beze změny.
- Kód psaný dnes (typované KI funkce) je přímo použitelný pro comptime dispatch zítra —
  žádná dodatečná konverze.
- **Sémantika zůstává synchronní request/reply** (`kernel-interface.md` §6.1): asynchronie
  mailboxu (async send, blocking receive) je interní transportní detail, nikdy neuniká
  z `api/*` do Lua/UI. Latence a nová třída selhání (server nedostupný) se mapují na
  `KiStatus`; žádný fire-and-forget.
- Změna tohoto návrhu = nový ADR odkazující na tento.

## Související
- ADR-001 (evoluce SASOS → mikrojádro), ADR-003, ADR-004, ADR-017
- `spec/kernel-interface.md` §6, `spec/input.md`, `spec/roadmap.md` (M8)
