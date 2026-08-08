# Aster — Specifikace

**Aster** je experimentální desktopový operační systém napsaný v Zigu. Tento soubor je
úvodem do kompletní architektonické dokumentace projektu.

> První implementace záměrně upřednostňuje jednoduchost před izolací: desktop, skriptovací
> engine i runtime sdílejí jediný adresní prostor. Veřejná rozhraní jsou stabilní abstrakce,
> takže jednotlivé subsystémy lze později přestěhovat do izolovaných procesů **bez změny
> aplikačních API**.

## Dokumenty

| # | Dokument | Obsah |
|---|----------|-------|
| 1 | [architecture-overview.md](architecture-overview.md) | **Hlavní dokument.** Filozofie, architektura, přehled rozhodnutí, známá rizika, terminologie, struktura repozitáře. |
| 2 | [manifest.md](manifest.md) | Manifest projektu — jednoduchost před izolací, evolvabilní rozhraní. |
| 3 | [non-goals.md](non-goals.md) | Co systém vědomě nedělá (POSIX, SMP, USB, networking, ...). |
| 4 | [coding-style.md](coding-style.md) | Filozofie a pravidla kódu — struktura modulů, kontrakty, paměť, review checklist. |
| 5 | [adr/](adr/README.md) | Architektonická rozhodnutí (ADR-001..021), každé v samostatném souboru. |
| 6 | [kernel-interface.md](kernel-interface.md) | **Kernel Interface (KI):** `sys.dispatch`, syscall čísla, moduly rozhraní, pravidla. |
| 7 | [graphics.md](graphics.md) | Grafická podvrstva: Graphics API → Renderer → Framebuffer. |
| 8 | [desktop.md](desktop.md) | Desktop UI — atomický port cachyos-hypr-noctalia (bar, launcher, okna, widgety). |
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

## Jak konzultovat návrh

1. **Chceš přehled a proč:** čti `architecture-overview.md` celý.
2. **Chceš důvod konkrétního rozhodnutí:** `adr/` — každé rozhodnutí je samostatný soubor.
3. **Chceš vědět, co se nedělá:** `non-goals.md`.
4. **Chceš kontrolní seznam pro review:** `coding-style.md` + `invariants.md`.
5. **Chceš vědět, co se kdy dělá:** `roadmap.md`.
6. **Chceš vědět, jak má vypadat desktop UI:** `desktop.md`.

## Stav

- **Verze specifikace:** 1.0 (draft)
- **Schváleno k implementaci:** Milníky M0–M4; M5 (UI) rozpracovaný
- **Aktualizace:** nová architektonická rozhodnutí se zapisují do `spec/adr/` (každé
  samostatný soubor); přehled se udržuje v `architecture-overview.md`. Rozhodnutí se nemění
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
- **Přechod na angličtinu u `spec/*.md` je vědomý, jednorázový krok** — nastane ve chvíli,
  kdy systém funguje a je stabilizovaný (přibližně **M8**, po stabilizačním milníku) a
  projekt hledá kontributory. Tehdy se interní dokumentace přeloží jako jeden ucelený
  celek, ne postupně za běhu. Posunuto z M4 na M8 (2026-08-08): M4/M5 se soustředí na
  implementaci a měření, ne na překlad.

> **Odchylka od původního plánu (zapsáno při M0):** původní záměr byl anglické dokumentace
> od M4+ včetně README. Protože je repo public už od M0, README se přeložilo hned;
> specifikace zůstává česky dle výše.

To se týká **dokumentace**. **Kód, komentáře a commit messages zůstávají anglicky vždy**
(`spec/coding-style.md` §0).
