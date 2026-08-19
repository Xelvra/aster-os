# Aster OS — Specifikace

**Aster OS** je experimentální desktopový operační systém napsaný v Zigu. Tento soubor je
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
| 5 | [adr/](adr/README.md) | Architektonická rozhodnutí (ADR-001..027), každé v samostatném souboru. |
| 6 | [kernel-interface.md](kernel-interface.md) | **Kernel Interface (KI):** `sys.dispatch`, syscall čísla, moduly rozhraní, pravidla. |
| 7 | [graphics.md](graphics.md) | Grafická podvrstva: Graphics API → Renderer → Framebuffer. |
| 8 | [desktop-ui.md](desktop-ui.md) | Desktop UI — port vzhledu/chování z cachyos-hypr-noctalia, reimplementováno (bar, launcher, okna, widgety). |
| 9 | [input.md](input.md) | Vstupní model: PS/2 klávesnice + myš, fronta událostí, mapování na Lua. |
| 10 | [runtime.md](runtime.md) | Runtime API: `Runtime.spawn`, `RuntimeKind`, vazba Runtime → Program. |
| 11 | [timer.md](timer.md) | Čas: tick zdroj (M2), KI `timer`, kooperativní sleep. |
| 12 | [memory.md](memory.md) | Paměť: PFA, obecný heap alokátor, `lua_Alloc`, cache atributy. |
| 13 | [invariants.md](invariants.md) | Invarianty rozdělené na Safety / Performance / Architecture. |
| 14 | [storage.md](storage.md) | Storage: vrstvy (KI → file → ext2 → gpt → block), handle model, non-POSIX sémantika, chování bez disku, initfs vs disk, testovací obrazy. |
| 15 | [roadmap.md](roadmap.md) | Milníky M0–M10 s kritérii "hotovo" a tabulkou kvalitních metrik. |
| 16 | [verification.md](verification.md) | Verifikační pipeline, deterministický build, pravidlo bootovatelného commitu. |
| 17 | [debugging.md](debugging.md) | Debugging Survival Guide — GDB+QEMU, čtení serial dumpu, pravidla pro IRQ. |
| 18 | [troubleshooting.md](troubleshooting.md) | Známé pasti a lekce — build API, protokoly, determinismus, tooling. |
| 19 | [handoff.md](handoff.md) | Formální postup pro nevyřešené problémy — šablona, kdy ji spustit, jak ji zavřít. |
| 20 | [`CHANGELOG.md`](../CHANGELOG.md) | Agregovaný changelog (anglicky) — co systém umí, jedna verze na milník. |
| 21 | [lua-wm.md](lua-wm.md) | **Lua WM blueprint** — architektura, moduly, tiling engine, grafická pipeline, bindings, design rationale (RFC). |
| 22 | [editor.md](editor.md) | **Editor okno** — otevření, klávesové a myšové konvence (kolečko = scroll, klik = kurzor), plánovaný zoom. |
| 23 | [2026-08-15-self-audit.md](2026-08-15-self-audit.md) | **Self-Audit (2026-08-15)** — formální repo audit (kód, bezpečnost, build, CI); nálezy opravené, audit reálně řídí práci. |
| 24 | [2026-08-16-re-audit.md](2026-08-16-re-audit.md) | **Re-Audit (po M7)** — kontrola, že self-audit nálezy zůstaly opravené, + nová funkcionalita (wasm, SMP, storage) novýma očima. |

> **Auditovací postup:** projekt dělá **pravidelné audity po etapách** — po
> každém milníku **Self-Audit** (nová funkcionalita + opravy) a před uzavřením
> milníku **Re-Audit** (kontrola, že předchozí nálezy drží a nepřibyly nové
> vstupní vektory). Soubory mají pevný název `YYYY-MM-DD-self-audit.md` resp.
> `YYYY-MM-DD-re-audit.md`; odkazy v kódu/spec na daný audit používají přesně
> tento název souboru.

## Jak konzultovat návrh

1. **Chceš přehled a proč:** čti `architecture.md` celý.
2. **Chceš důvod konkrétního rozhodnutí:** `adr/` — každé rozhodnutí je samostatný soubor.
3. **Chceš vědět, co se nedělá:** `non-goals.md`.
4. **Chceš kontrolní seznam pro review:** `code-style.md` + `invariants.md`.
5. **Chceš vědět, co se kdy dělá:** `roadmap.md`.
6. **Chceš vědět, jak má vypadat desktop UI:** `desktop-ui.md`.

## Stav

- **Verze specifikace:** 1.0 (draft)
- **Schváleno k implementaci:** Milníky M0–M6; M7 (Runtime) Fáze A+B hotové, Fáze C
  (benchmark wasm vs Lua) zbývá jako dluh před uzavřením M7
- **Aktualizace:** nová architektonická rozhodnutí se zapisují do `spec/adr/` (každé
  samostatný soubor); přehled se udržuje v `architecture.md`. Rozhodnutí se nemění
  dodatečně — doplňují se nová.

## Jazykové fáze dokumentace

Dokumentace pro **veřejné publikum** (README.md) je **anglicky** — repo je public od M0 a
README je vstupní brána pro návštěvníky. Interní specifikace (`spec/*.md`) a jeho jazyk
**záměrně** zůstává, je to „druhý mozek" autora, ne marketing.

Důvody:

- Před milníkem M0 by anglická dokumentace byla komunitní marketing, který hobby projekty
  nejčastěji zabíjí: zpomalí iteraci, odvede od kódu a soustředí se na publikum, které neexistuje.
- Psát pro sebe = rychlost, konzistence a soustředění na kód; jazyk je pro autora
  nejrychlejší médium přesného vyjádření.
- **Anglická verze specifikace nevzniká hromadným překladem, ale postupně** — jako
  anglická vrstva v `docs/` (web, viz „Strategie dvou vrstev" níže). `spec/*.md`
  zůstává zdroj pravdy; anglický ekvivalent se vytváří průběžně při práci, ne jako
  jednorázový skok (původní plán „hromadný překlad v M8" nahrazen 2026-08-08). Nejde
  tedy o podmínku žádného milníku.

> **Odchylka od původního plánu (zapsáno při M0):** původní záměr byl anglické dokumentace
> od M4+ včetně README. Protože je repo public už od M0, README se přeložilo hned;
> specifikace zůstává viz výše.

To se týká **dokumentace**. **Kód, komentáře a commit messages jsou anglicky vždy**
(`spec/code-style.md` §0).

## Strategie dvou vrstev (web)

Veřejný web (`docs/`, GitHub Pages) je **kurátorská vrstva** nad interní specifikací.
Princip: **jazyk autora = mozek, překlady = tvář.** Jeden směr toku, žádná duplicita.

- `spec/` (česky) = **kanonický zdroj pravdy** — upravuje se volně, vždy aktuální.
- `docs/` (anglicky) = **kurátorská veřejná vrstva** — publikuje se z `main` přes
  GitHub Pages (native Jekyll, theme just-the-docs; konfigurace `docs/_config.yml`).
- Každá anglická stránka nese `source: spec/<soubor>.md` + datum poslední
  synchronizace (`synced:`).
- **Jednosměrný tok:** spec → docs. Nikdy zpětně (překladová stránka se nepromítá
  do spec).
- **Drift je design, ne bug:** web může zaostávat za spec — veřejná tvář je stabilní,
  mozek je rychlý.
- Nové věci se píší do `spec/`, překlady až na web ve volných chvílích.
- `CHANGELOG.md` a `README.md` zůstávají anglicky (veřejné rozhraní projektu).
