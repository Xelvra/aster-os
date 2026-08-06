# Styl kódu — Filozofie a pravidla kódu

**Status:** Current design
**Účel:** pravidla pro strukturu kódu a návrh modulů. Nemají nahrazovat jmenné konvence
Zigu, ale doplňují je o projektovou disciplínu.

> Cíl: kód, který se dá číst za půl roku bez kontextu. Explicitnost a malé moduly víc než
> chytrost.

---

## 0. Jazyk (kód vs. dokumentace)

- **Kód, komentáře, anotace, docstringy, identifikátory a commit messages: v angličtině.**
  Code je veřejně sdílený artefakt a angličtina je jeho výchozí jazyk.
- **Dokumentace pro veřejnost (`README.md`): v angličtině** (repo je public od M0).
- **Interní specifikace (`spec/*.md`): v češtině** (druhý mozek autora). Výjimkou
  jsou zavedené konvence — názvy souborů, adresářů, služeb, technické termíny
  (framebuffer, syscall, Renderer, Runtime, ADR statusy apod.).
- Komentář v kódu, který vysvětluje "proč", je v angličtině. Český text do kódu nepatří.

---

## 1. Návrhové principy

- **Preferuj explicitnost před implicitním.** Žádná magie: žádné metamodely, generování
  kódu na pozadí, implicitní konverze nebo skryté vedlejší efekty.
- **Malé moduly, jedna zodpovědnost.** Soubor dělá jednu jasně pojmenovatelnou věc. Pokud
  popis modulu potřebuje "a", rozděl ho.
- **Žádné singletony.** Stav se předává explicitně (struct instance), nesdílí se globálně.
- **Žádné globální mutable stavy, pokud to není HW.** Výjimka: registry zařízení,
  framebuffer paměť, atomická fronta událostí — to je hardware/kontext přerušení, ne
  programová globální proměnná.
- **KISS + YAGNI.** Nejednodušší řešení, které funguje. Nepřidává se abstrakce "pro
  budoucí použití" — viz `spec/non-goals.md`.
- **DRY s rozumem.** Opakující se logika se extrahuje; dvě věci, které se budou vyvíjet
  nezávisle, se uměle nespojují.

---

## 2. Kontrakty a viditelnost

- **Každá veřejná funkce má kontrakt.** Docstring (nebo výmluvné jméno + dokumentace)
  říká: vstup, výstup, chyby, co je povoleno volat. Viz `spec/kernel-interface.md` pro KI.
- **Veřejné je jen to, co má být veřejné.** Interní pomocné funkce jsou `pub` jen tehdy,
  když je volá jiný modul; jinak soukromé. KI moduly v `api/` jsou jediný veřejný povrch.
- **Žádné tiché selhání.** Funkce, která může selhat, vrací `KiStatus` / chybovou hodnotu.
  Žádný prázdný `catch` bez zdůvodnění.

---

## 3. Paměť

- **Alokace/free musí být dohledatelné.** Alokátor se předává explicitně; ownership
  (kdo alokoval, kdo uvolňuje) je vidět z podpisu. Žádné skryté alokace v čistých
  funkcích.
- **Žádná alokace na kritických cestách** (IRQ, rendering, event loop render) — invariant
  Performance, `spec/invariants.md`.
- **Preferuj stack a statické buffery** v jádře a rendereru.
- **Immutable, kde to dává smysl** — `const`, neměnitelná data jako výchozí.

---

## 4. Struktura a pojmenování

- `snake_case` pro funkce a proměnné, `PascalCase` pro typy, `UPPER_SNAKE_CASE` pro
  konstanty (Zig konvence).
- Žádné stínování vestavěných jmen (`list`, `id`, ...).
- Moduly řazené podle závislostí: `api/*` nahoře (veřejné), interní vrstvy pod nimi.
- Komentáře vysvětlují "proč", ne "co". Co kód dělá má být čitelné ze samotného kódu.

---

## 5. Vlákna, IRQ, sdílený stav

- IRQ handler: atomické operace na předem alokovaných strukturách. Žádné locky, žádné
  alokace, žádná rekurze (invariant Safety).
- Sdílený stav mezi IRQ a event loop jen přes dokumentovaný mechanismus (kruhová fronta).

---

## 6. Kontrolní seznam pro review (code review)

Před schválením jakékoli změny:

- [ ] Kód a komentáře jsou v angličtině (dokumentace v češtině — viz §0).
- [ ] Název souboru/funkce odpovídá jedné zodpovědnosti.
- [ ] Žádný singleton / nový globální mutable stav (kromě HW).
- [ ] Veřejné funkce mají kontrakt.
- [ ] Alokace/free jsou dohledatelné z podpisu.
- [ ] Žádná alokace v IRQ / renderu / event loop render.
- [ ] Žádné tiché selhání.
- [ ] Žádná magie, žádná implicitní konverze.
- [ ] Prošel `zig fmt --check` a `zig build test` (`spec/verification.md`).
