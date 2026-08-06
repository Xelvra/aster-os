# Aster Manifest

**Status:** Current design (aktuální stav)

> **Aster je experimentální desktopový operační systém napsaný v Zigu.**
>
> První implementace záměrně upřednostňuje jednoduchost před izolací: desktop, skriptovací
> engine i runtime sdílejí jediný adresní prostor, aby se minimalizovala složitost a
> maximalizovala rychlost iterace. Veřejná rozhraní jsou navržena jako stabilní abstrakce,
> takže jednotlivé subsystémy lze později přestěhovat do izolovaných procesů **bez změny
> aplikačních API**.

## Dekódování manifestu (co to znamená v praxi)

| Fráze | Význam |
|---|---|
| *experimentální desktopový systém* | Nejde o produkční systém, ale o laboratoř pro UI architekturu. |
| *jednoduchost před izolací* | Bezpečnostní model = izolace na úrovni jazyka: Lua skripty a Wasm moduly běží uvnitř managed runtime, což snižuje riziko libovolné paměťové korupce oproti nativnímu Zig kódu. Plnou moc má jen námi psaný Zig kód. |
| *jediný adresní prostor* | Žádné ring přechody, žádné TLB flushe, žádné přepínání CR3. UI kreslí přímo do paměti. |
| *stabilní abstrakce* | Rozhraní (KI) se navrhují tak, jako by už dnes byla ABI. |
| *přestěhování do izolovaných procesů bez změny API* | Z dnešních přímých volání se zítra stanou IPC zprávy — volající kód se nemění. |

## Co Aster NENÍ

- **Není mikrojádro** (zatím). Je to evoluční SASOS, který se k mikrojádru může vyvíjet.
- **Není POSIX-klon.** Žádná POSIX API, žádný historický balast.
- **Není Linux-killer.** Je to hobby/experimentální systém.
- **Není bezpečnostní systém** v tradičním smyslu (MMU izolace mezi procesy zatím neexistuje).

Kompletní vymezení rozsahu (co děláme / neděláme) je v [`non-goals.md`](non-goals.md).

## Historický kontext (lineage)

Aster navazuje na tradici **živých systémů**, kde je prostředí kód a kód prostředí —
koncept, který moderní OS převálcovaly POSIX filozofií:

- **Lisp Machines a Smalltalk (70.–80. léta):** živý obraz (image); změnil jsi kód
  vykreslení okna a okno se okamžitě překreslilo za běhu. Žádné oddělení jádra od
  prostředí.
- **Emacs:** malé C jádro + masivní, za běhu modifikovatelné Lisp prostředí.
- **AwesomeWM / Arcan (Linux svět):** Lua řídí window manager / display server.

Aster tuto filozofii přináší s moderními nástroji: kernel v Zigu (paměťová bezpečnost,
žádný skrytý control flow), UI v Luay (embedovatelná, měnitelná za běhu). Wow efekt —
uložím soubor a UI se živě překreslí bez ztráty stavu — je dědictví Smalltalku
přenesené do 21. století.

## Kompromisy (přijaté vědomě)

1. **Izolace obětovaná za rychlost a jednoduchost.** Riziko: bug v nativním Zig kódu může
   zkorumpovat cokoli. Zmírnění: Lua skripty a Wasm moduly běží v managed runtime, takže
   riziko libovolné paměťové korupce je oproti nativnímu kódu nižší.
2. **Boot z Limine, ne vlastní bootloader.** Obětovaná kontrola nad bootem za čas k vývoji.
3. **Lua 5.4 místo LuaJIT.** Obětovaný výkon interpreteru za jednoduchost a stabilitu na Ring 0.
4. **Žádný FS do M6.** Obětovaná persistence za menší kód; assety jsou embedded.

## Rozhodovací pravidla pro budoucnost

Při každé budoucí volbě se ptát:

1. Zjednodušuje to systém, nebo jen snižuje okamžitou nepohodlí?
2. Je to měřitelné (viz kvalitní metriky v `roadmap.md`)? Bez měření se neoptimalizuje.
3. Zachovává to stabilní rozhraní? Žádná změna, která rozbije KI, bez nového ADR.
4. Zůstane systém po tomto commitu bootovatelný?

## Sémantický slib: synchronní call → IPC bez refaktoru

Manifest slibuje, že z dnešních přímých volání se zítra stanou IPC zprávy **bez změny
aplikačních API**. Nejdůležitější otázka, která k tomu patří: *jak skrýt latenci,
selhání a asynchronii IPC za API, které dnes vypadá jako lokální volání?*

Odpověď: **neskrýváme je — držíme sémantiku synchronního request/reply.**

- KI volání je **dnes i zítra synchronní**: `drawRect(...)` se vrátí, až je nakresleno —
  dnes přímým voláním, zítra zprávou + blokováním na odpovědi.
- Asynchronie (mailboxy, IPC) je **interní detail transportu**, nikdy neuniká do Lua/UI.
- Latence se **přijímá** (UI operace jsou nízkofrekvenční), neukrývá se umělou async hranou.
- Nové chyby („server nedostupný") se **mapují na `KiStatus`** — volající už dnes chyby
  zpracovává; žádný fire-and-forget, žádné tiché selhání.

Detail: `spec/kernel-interface.md` §6.1, ADR-018. Tohle je odpověď, proč slib
„evoluce do mikrojádra bez přepisu aplikací" není marketing — je to vynucený kontrakt.
