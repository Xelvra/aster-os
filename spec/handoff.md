# Handoff nevyřešeného problému

**Status:** V1 (draft).
**Účel:** formální postup, když se problém nedaří vyřešit v rozumném čase. Cílem je
zachovat veškeré poznatky ve strukturované, předatelné podobě — ať se k problému vrací
kdokoli, kdekoliv, kdykoliv, bez ztráty kontextu.

Tento proces **nenahrazuje** ladění (`debugging.md`) ani zápis vyřešené lekce
(`troubleshooting.md`). Používá se ve chvíli, kdy standardní postupy selhaly a problém
zůstává otevřený.

---

## 1. Kdy spustit handoff

Problém se označí za **nevyřešený** a zahájí se handoff, když platí alespoň jedna podmínka:

1. **Časový limit:** samostatné ladění přesáhlo zvolený limit (default 60 minut) bez
   nalezení příčiny.
2. **Podezřelá cizí závislost:** chování vypadá jako bug nástroje/knihovny mimo naši
   kontrolu (build systém, bootloader, emulátor, kompilátor).
3. **Nereprodukovatelnost:** problém nelze spolehlivě reprodukovat, i když se vyskytuje.
4. **Blokování:** problém blokuje práci a není v dohledu jednoduché řešení.

Dokud žádná podmínka neplatí, pokračuje se standardním laděním — handoff není zkratka
k tomu, jak se vyhnout hledání.

---

## 2. Povinné kroky před handoffem

Než se cokoli zapíše, musí platit **všechno**:

- [ ] Problém je reprodukovaný minimálně 2× (determinismus ADR-014).
- [ ] Je zaznamenán přesný příkaz (celý, kopírovatelný) a jeho výstup.
- [ ] Je otestovaná nejjednodušší hypotéza (logický první podezřelý).
- [ ] Je prohledán `troubleshooting.md` (známé pasti) a `debugging.md`.
- [ ] Existuje záznam „co jsem zkusil a co z toho bylo" — bez něj se handoff nevypisuje.
- [ ] Pracovní strom je čistý / změny jsou v commitu (nevydává se nekonzistentní stav).

---

## 3. Šablona handoff dokumentu

Každý handoff je **jeden soubor** v `spec/handoffs/<id>-<kratky-nazev>.md`, kde `<id>` je
pořadové číslo. Šablona:

```markdown
# Handoff <id>: <název problému>

**Datum:** RRRR-MM-DD
**Autor:** <kdo problém předává>
**Status:** open / in_progress / closed

---

## 1. Symptom

Přesný, pozorovatelný projev. Žádné interpretace — jen to, co je vidět.

> Reprodukce: `<celý příkaz, kopírovatelný>`
> Očekávaný výstup: ...
> Skutečný výstup: ...

## 2. Prostředí

| Vrstva | Hodnota |
|---|---|
| Build | `zig build ...` (mód, verze) |
| Toolchain | Zig verze, OS |
| Runtime | QEMU verze, parametry |
| Vlastní kód | commit hash / větev |

## 3. Co bylo vyzkoušeno

| # | Pokus | Výsledek | Závěr |
|---|-------|----------|-------|
| 1 | ... | ... | vyloučeno / potvrzeno / neprůkazné |
| 2 | ... | ... | ... |

## 4. Hypotézy

Seřazené od nejpravděpodobnější. Ke každé: co by ji potvrdilo/vyvrátilo.

1. **Hypotéza A:** ...
   - Potvrzení: ...
   - Vyvrácení: ...

## 5. Reprodukce

Krok za krokem, od čistého stavu. Musí ji zvládnout někdo jiný bez dalšího vysvětlení.

## 6. Důležité artefakty

Odkazy na výstupy (logy, screendumpy, gdb session), pokud jsou velké, ukládané mimo repozitář.

## 7. Omezení a podezřelé okolnosti

Věci, které neplatí / nebylo možné otestovat / které se chovají nekonzistentně.

## 8. Ideální výsledek

Co přesně považujeme za vyřešení (definice „hotovo" pro tento problém).
```

---

## 4. Co se stane s handoffem

1. **Otevřený handoff** se zapíše do souboru a `Status: open`.
2. **Další řešení** pokračuje na základě `§3` (co už padlo) — zbytečné opakování
   vyzkoušených pokusů je zakázáno.
3. **Při vyřešení:** zapsat příčinu a řešení do `troubleshooting.md` (pokud to je
   ne-obvious lekce), handoff označit `Status: closed` a do `§3` doplnit finální řádek.
4. **Blokující handoff** (podmínka 4) může ospravedlnit dočasné řešení (workaround),
   ale workaround se píše do kódu **explicitně** — viz `spec/coding-style.md` a
   `spec/troubleshooting.md` pravidla, nikdy tiše.

---

## 5. Seznam otevřených handoffů

| ID | Název | Datum | Status |
|----|-------|-------|--------|
| H1 | `zig build` hlásí falešné `failed command: xorriso` při prvním buildu | 2026-08-07 | open |

---

## 6. Jak handoff nepoužívat

- **Ne pro běžné ladění** — to je `debugging.md`.
- **Ne pro vyřešené lekce** — to je `troubleshooting.md`.
- **Ne jako omluva pro nedodělky** — handoff nezbavuje povinnosti zapsat reprodukci
  a dosavadní pokusy.
- **Ne k nekonečnému předávání** — kdo problém převezme, je zodpovědný za jeho posun
  (zavřít, vyloučit hypotézu, nebo vrátit zpět s novými poznatky), ne za další opisování.
