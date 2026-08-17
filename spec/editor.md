# Editor — textový editor okno (M7.1)

**Status:** V1 (draft). **Implementace:** `src/kernel/lua/ui/editor.lua` (buffer,
render, save/save-as), vstup `src/kernel/lua/ui/input.lua` (klávesnice i myš).
Dříve součást `spec/lua-wm.md` §7a.4 — editor má vlastní spec, protože přibývají
konvence (myš, plánovaný zoom) a další nástroje (files, calculator, browser)
dostanou po vzoru téhle stránky svoje.

---

## 1. Otevření a buffer

**Editor (`editor.lua`):** Super+T (i položka `editor` v launcheru) otevře
**prázdný buffer** (bez cesty);
čistý buffer se dalším Super+T resetuje na nový prázdný dokument, neuložený
(dirty) se zachová, takže se změny nikdy neztratí.
Konfigurace (`/wm/theme.lua`) se
otevírá přes **Super+Z** (settings);
uložení configu spouští auto-reload (`spec/runtime.md` §5a, trigger 2).

## 2. Klávesové konvence

Šipky Nahoru/Dolů = řádek, Levá/Pravá = kurzor,
Home/End = začátek/konec řádku, Enter = nový řádek, Backspace/Delete = mazat,
**Ctrl+S** = uložit (`file.write`). Nový buffer (bez cesty) přepne Ctrl+S na
prompt **„save as:"** v titulkové liště: píše se cesta, **Enter** uloží —
neexistující soubor se vytvoří (`file.create`, ext2 create), **Esc** zruší
(prompt neobsahuje žádné hinty — jak uložit je v help popupu, F1). Uložení
pod novým jménem **ihned osvěží files browser** (`files_refresh`), pokud
zrovna ukazuje tu složku — nový soubor se objeví bez další navigace. Dirty
marker se maže i tehdy, když uživatel
všechny změny vrátí zpět — buffer se porovnává s posledním uloženým stavem
(`ed_saved`), takže Ctrl+S se nabízí jen pro skutečně jiný obsah.
**Esc Esc** (jen u čistého bufferu bez neuložených změn) zavře editor jako
prohlížení; s neuloženými změnami je Esc blokován, takže se změny nemůžou
ztratit. Hlavička ukazuje cestu (klávesové hinty jsou v help popupu,
`Help F1` je v bar liště); dirty marker **`*`** za cestou značí neuložené změny.

**Read-only soubory** — každý soubor končící `.bak` (např. `/wm/.theme.bak`)
a `/.repl_history` — editor odmítne načíst (`editor_load`), prohlíží se jen
Spacem ve files browseru a kreslí se červeně. Binární `.wasm` soubory se
neotevírají jako text: files browser je blokuje (extension-based `is_read_only`
mechanismus), takže se k `editor_load` vůbec nedostanou. Důvod je u obou jiný: `.bak`
zálohy jsou **ruční záchrana posledního Ctrl+S** — kdyby je editor mohl
Ctrl+S přepsat, přestaly by být zálohou; obnovení předchozí verze = přejmenovat
`.bak` zpět na working copy. `/.repl_history` je **runtime stav vlastněný
shellem** — REPL ho po každém Enter truncate+kompletně přepíše z paměťové
historie, takže ruční editace by příští Enter tiše smazal (editace by byla
iluzí); zdroj pravdy pro běžící session je paměťová `history` tabulka.
Žádné vlastnictví ani práva souborů zatím neexistují — read-only je
**hardcoded pravidlo**, ne atribut souboru. `.bak` zálohy vznikají **jen
ručním Ctrl+S**, nikdy při startu ani z testů.

## 3. Myšové konvence

Editor se řídí konvencí GUI editorů (VS Code, gedit, mousepad — nikoli
terminálových vi/nano/emacs):

- **Kolečko myši = scroll viewportu.** Textový kurzor kolečko **nesleduje**
  (zůstává na své pozici, i když odscrolluje mimo zobrazenou oblast) — je to
  stejné jako u ostatních GUI editorů. Viewport je nezávislý na kurzoru
  (`ed_view_top`); kolečko ho posouvá a u prvního/posledního řádku se zastaví.
  **Směr je standardní (Windows/Linux), ne macOS natural:** kolečko dolů =
  viewport se posouvá ke konci dokumentu, kolečko nahoru = na začátek
  (QEMU ps2 myš posílá kolečko-dolů jako kladný Z bajt; interpretace směru je
  v `editor_wheel`).
- **Klik do textu = umístění kurzoru** na kliknutý řádek/sloupec
  (`editor_click_at`). Klik za konec řádku clampne na konec řádku, za
  viditelnou šířku na pravý okraj; sloupec se počítá po code pointech, takže se
  nikdy neotevře uprostřed UTF-8 sekvence. Klik na hlavičku/okraj tělo neovlivní.
- **Klávesová navigace a psaní drží kurzor viditelný** (`editor_reveal_caret`),
  takže uživatel, který odscrolloval kolečkem, se vždy najde.
- Kolečko i klik fungují **jen v zaostřeném editoru** (focused okno), ne
  v jiných oknech (files/REPL).
- Implementace: geometrie textu sdílí `editor_text_geometry(w)` (render i
  hit-testy), aby nakreslený glyf a kliknuté místo vždy souhlasily.

### 3.1 View mód (Space v files browseru)

Stejné myšové konvence platí i v **read-only view módu** — náhled souboru
otevřený Spacem ve files browseru (`fs_viewing`, hollow kurzor):

- **Kolečko myši = scroll viewportu** (`files_view_wheel`), hollow kurzor ho
  nesleduje; směr standardní jako v editoru (dolů = ke konci).
- **Klik do textu = umístění hollow kurzoru** (`files_view_click_at`), stejná
  codepoint-aware pravidla jako v editoru.
- **Klávesová navigace drží kurzor viditelný** (`files_view_reveal`).
- Důvod: view mód je základ budoucí **selekce a schránky** (§4) — kurzor tu
  neslouží jen ke čtení, ale bude označovat výběr textu.

## 4. Plánované konvence

- **Selekce textu + globální schránka:** v editoru i view módu se má dát text
  **označit a zkopírovat** — **`Ctrl+C`** = kopírovat výběr do globální
  schránky, **`Ctrl+V`** = vložit ze schránky (v editoru), případně `Ctrl+A` =
  označit vše. **Rezervace, neimplementováno** — schránka je služba, která
  zatím neexistuje. Selekce myší (táhni = označ, klik = umísti kurzor) vychází
  z konvencí §3/§3.1 a je předpokladem pro `Ctrl+C`.
- **Text zoom editoru:** `Ctrl+kolečko` a `Ctrl+(-/+)` (zvětšení/zmenšení textu
  v editoru). **Rezervace, neimplementováno.** Je to app-scoped (editor), proto
  `Ctrl` bez Super.
- **Globální zoom oken:** `Ctrl+Super+(-/+)`. Super = modifikátor WM (stejný
  vzor jako `Super+F1` = globální help vs `F1` = help aplikace), takže globální
  zoom oken nikdy nekoliduje s `Ctrl+(-/+)` v otevřeném editoru. Rezervace,
  neimplementováno.
- **Cursor zoom (compositor, celá obrazovka):** zůstává rezervovaný jako
  `Super+-/=` (`spec/lua-wm.md` §7a.1). Tři úrovně zoomu (text editoru /
  okna / obrazovka) se liší modifikátorem a nesmějí se plést.
