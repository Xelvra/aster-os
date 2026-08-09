# Aster OS — Specifikace

**Aster** je experimentální desktopový operační systém napsaný v Zigu. Tento soubor je
úvodem do kompletní architektonické dokumentace projektu.

> První implementace záměrně upřednostňuje jednoduchost před izolací: desktop, skriptovací
> engine i runtime sdílejí jediný adresní prostor. Veřejná rozhraní jsou stabilní abstrakce,
> takže jednotlivé subsystémy lze později přestěhovat do izolovaných procesů **bez změny
> aplikačních API**.

## Dokumenty

| # | Dokument | Obsah |
|---|----------|-------|
| 1 | [architecture.md](architecture.md) | **Hlavní dokument.** Filozofie, architektura, přehled rozhodnutí, známá rizika, terminologie, struktura repozitáře. |
| 2 | [manifest.md](manifest.md) | Manifest projektu — jednoduchost před izolací, evolvabilní rozhraní. |
| 3 | [non-goals.md](non-goals.md) | Co systém vědomě nedělá (POSIX, SMP, USB, networking, ...). |
| 4 | [code-style.md](code-style.md) | Filozofie a pravidla kódu — struktura modulů, kontrakty, paměť, review checklist. |
| 5 | [adr/](adr/README.md) | Architektonická rozhodnutí (ADR-001..022), každé v samostatném souboru. |
| 6 | [kernel-interface.md](kernel-interface.md) | **Kernel Interface (KI):** `sys.dispatch`, syscall čísla, moduly rozhraní, pravidla. |
| 7 | [graphics.md](graphics.md) | Grafická podvrstva: Graphics API → Renderer → Framebuffer. |
| 8 | [desktop-ui.md](desktop-ui.md) | Desktop UI — port vzhledu/chování z cachyos-hypr-noctalia, reimplementováno (bar, launcher, okna, widgety). |
| 9 | [input.md](input.md) | Vstupní model: PS/2 klávesnice + myš, fronta událostí, mapování na Lua. |
| 10 | [runtime.md](runtime.md) | Runtime API: `Runtime.spawn`, `RuntimeKind`, vazba Runtime → Program. |
| 11 | [timer.md](timer.md) | Čas: tick zdroj (M2), KI `timer`, kooperativní sleep. |
| 12 | [memory.md](memory.md) | Paměť: PFA, obecný heap alokátor, `lua_Alloc`, cache atributy. |
| 13 | [invariants.md](invariants.md) | Invarianty rozdělené na Safety / Performance / Architecture. |
| 14 | [roadmap.md](roadmap.md) | Milníky M0–M8 s kritérii "hotovo" a tabulkou kvalitních metrik. |
| 15 | [verification.md](verification.md) | Verifikační pipeline, deterministický build, pravidlo bootovatelného commitu. |
| 16 | [debugging.md](debugging.md) | Debugging Survival Guide — GDB+QEMU, čtení serial dumpu, pravidla pro IRQ. |
| 17 | [troubleshooting.md](troubleshooting.md) | Známé pasti a lekce — build API, protokoly, determinismus, tooling. |
| 18 | [handoff.md](handoff.md) | Formální postup pro nevyřešené problémy — šablona, kdy ji spustit, jak ji zavřít. |
| 19 | [`CHANGELOG.md`](../CHANGELOG.md) | Agregovaný changelog (anglicky) — co systém umí, jedna verze na milník. |

## Jak konzultovat návrh

1. **Chceš přehled a proč:** čti `architecture.md` celý.
2. **Chceš důvod konkrétního rozhodnutí:** `adr/` — každé rozhodnutí je samostatný soubor.
3. **Chceš vědět, co se nedělá:** `non-goals.md`.
4. **Chceš kontrolní seznam pro review:** `code-style.md` + `invariants.md`.
5. **Chceš vědět, co se kdy dělá:** `roadmap.md`.
6. **Chceš vědět, jak má vypadat desktop UI:** `desktop-ui.md`.

## Stav

- **Verze specifikace:** 1.0 (draft)
- **Schváleno k implementaci:** Milníky M0–M5; M6 (Storage) v plánu
- **Aktualizace:** nová architektonická rozhodnutí se zapisují do `spec/adr/` (každé
  samostatný soubor); přehled se udržuje v `architecture.md`. Rozhodnutí se nemění
  dodatečně — doplňují se nová.

## Jazykové fáze dokumentace

Dokumentace pro **veřejné publikum** (README.md) je **anglicky** — repo je public od M0
a README je vstupní brána pro návštěvníky. Interní specifikace (`spec/*.md`) zůstává
**záměrně česky** — je to „druhý mozek" autora, ne marketing. Důvody:

- Před milníkem M0 by anglická dokumentace byla komunitní marketing, který hobby projekty
  nejčastěji zabíjí: zpomalí iteraci, odvede od kódu a soustředí se na publikum, které
  zatím neexistuje.
- Psát pro sebe = rychlost, konzistence a soustředění na kód; čeština je pro autora
  nejrychlejší médium přesného vyjádření.
- **Anglická verze specifikace nevzniká hromadným překladem, ale postupně** — jako
  anglická vrstva v `docs/` (web, viz „Strategie dvou vrstev" níže). `spec/*.md` zůstává
  český zdroj pravdy; anglický ekvivalent se vytváří průběžně při práci, ne jako
  jednorázový krok (původní plán „hromadný překlad v M8" nahrazen 2026-08-08). Nejde
  tedy o podmínku žádného milníku.

> **Odchylka od původního plánu (zapsáno při M0):** původní záměr byl anglické dokumentace
> od M4+ včetně README. Protože je repo public už od M0, README se přeložilo hned;
> specifikace zůstává česky dle výše.

To se týká **dokumentace**. **Kód, komentáře a commit messages zůstávají anglicky vždy**
(`spec/code-style.md` §0).

## Strategie dvou vrstev (web)

Veřejný web (`docs/`, GitHub Pages) je **překladová vrstva** nad interní specifikací.
Princip: **čeština = mozek, angličtina = tvář.** Jeden směr toku, žádná duplicita.

- `spec/` (česky) = **kanonický zdroj pravdy** — upravuje se volně, vždy aktuální.
- `docs/` (anglicky) = **překlad veřejné vrstvy** — publikuje se z `main` přes
  GitHub Pages (native Jekyll, theme just-the-docs; konfigurace `docs/_config.yml`).
  Každá anglická stránka je **věrný překlad** svého českého zdroje (stejné sekce, stejná
  fakta, stejná struktura) — ne zkratka.
- **Překlady jsou strojové** — anglické stránky vznikají strojovým překladem českých
  zdrojů a procházejí lidskou kontrolou autora při synchronizaci (`synced:`). Nejedná se
  o ručně psaný marketingový text; případné nuance originálu je nutné ověřit v českém
  zdroji (který je vždy kanonický).
- **Jednosměrný tok:** spec → docs. Nikdy zpětně (anglická stránka se nepromítá
  do českého spec).
- **Odkazy jdou jen jedním směrem:** web (`docs/`) odkazuje na repo (`spec/`, README,
  ...) — nikdy naopak. Repo dokumenty (README, CONTRIBUTING, `spec/*`) **neodkazují**
  na `docs/` ani na webové stránky (`xelvra.github.io/...`); jediný zdroj pravdy žije
  v repu. Zpětný odkaz by vytvořil druhou, rovnocennou „tvář" a rozbil by jednozdrojový
  princip.
- Nové věci se píší česky do `spec/`, anglicky na web ve volných chvílích.
- `CHANGELOG.md` a `README.md` zůstávají anglicky (veřejné rozhraní projektu).

### Pravidlo synchronizace (gitové, ne datové)

Každá anglická stránka v `docs/*.md` nese v **YAML front matter** `source:`:

```yaml
---
layout: default
title: Status
nav_order: 2
source: spec/roadmap.md
---
```

- `source:` — relativní cesta ke zdroji (zdrojům, čárkami) v repu, ze kterého se
  stránka překládá. U `milestones.md` `spec/roadmap.md`; u `development.md`
  `spec/verification.md, spec/code-style.md`.
- **Výjimka — `docs/index.md`:** úvodní stránka, která vysvětluje anglickému čtenáři
  strategii dvou vrstev a zrcadlí `README.md`. **Nemá `source:`** — není překladem
  českého zdroje, a proto ji `tools/sync-docs.sh` nekontroluje (jediný odchylkový
  dokument).
- `synced:` — datum poslední synchronizace. Stránka na konci ukazuje viditelnou
  patičku „Last synced from … on …", aby čtenář webu vždy viděl, od kdy stránka
  odráží zdroj.
- **Kontrola je založená na git historii, ne na datovém tagu.** Stránka je v sync, když
  je její anglický překlad commitnut **v době posledního commitu českého zdroje nebo
  později**. Ruční změna `synced:` data v souboru nemá váhu pro hlavní (gitový) check —
  ten čte jen `git log`, takže check nejde ošidit. `synced:` datum je sekundární
  konzistence pro čtenáře (patička).
- **Pravidlo 14 dnů:** po změně `spec/<soubor>.md` se anglický ekvivalent v `docs/`
  zsynchronizuje a commitne **do 14 dnů**. Do té doby skript **varuje**; po 14 dnech
  **failuje** a blokuje push (pre-push hook) a CI. Stránka, jejíž zdroj se změnil bez
  odpovídajícího commitu překladu, neprojde.
- **Patička nelže:** `tools/sync-docs.sh --check` kontroluje i to, že `synced:` datum
  není starší než poslední změna zdroje (stejné 14denní okno) — pokud vývojář zapomene
  syncnout, čtenář vidí zastaralé datum a CI po 14 dnech push zablokuje.
