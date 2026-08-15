# Verifikace — Pipeline, Deterministický Build, Bootable Commit

**Status:** V1 (draft). **Rozhodnutí:** ADR-013, ADR-014, ADR-016.
**Účel:** projektová verifikace pro Zig — fail fast, dokázané hotovo, ochrana proti
regresi, deterministický build.

---

## 1. Verifikační pipeline (Fail Fast)

Kroky běží v přesném pořadí. Při první chybě se zastaví, opraví a celá sekvence běží znovu
od kroku 1.

### Krok 0 — Baseline (před první změnou)

```bash
zig build test
```

Pokud baseline selže ještě před jakoukoli změnou, nepokračujeme — stav se hlásí.

### Krok 1 — Formátování

```bash
zig fmt --check .
```

Žádné neformátované soubory.

### Krok 2 — Kompilace (release + debug)

```bash
zig build
```

Build musí projít pro defaultní konfiguraci.

### Krok 3 — Host unit testy

```bash
zig build test
```

Všechny host unit testy (`tests/`) musí být zelené. Host testy pokrývají čistou logiku,
kterou jde spustit mimo cílový hardware:
- PFA (alokace/uvolnění/fragmentace),
- heap alokátor (coalescing, out-of-memory),
- framebuffer: `fillRect`/`blit`/`fillScreen` s clippingem (hrany, negativní počátky,
  plně mimo), `pixelColor` encodování,
- renderer: `drawGlyph` (pixel-přesně vůči fontu), `drawText`,
  `roundRect` (střed vyplněný, roh oříznutý), `rectBorder` (obrys bez výplně),
  `gradientBorder` (interpolace po obvodu, monotonie),
- font: fallback glyf, prázdný `space`,
- console: psaní, wrap, backspace, scroll, clear,
- input: `KeyCode` → ASCII (lower/upper, číslice, symboly, control → null),
- binding marshalling,
- kruhová fronta událostí.

**Marshalling jako bezpečnostní hranice** (spec `runtime.md` §5): binding testy
zahrnují **negativní/adversarial vstupy** — špatné typy, záporné souřadnice,
přeplněné buffer délky, codepointy mimo font — ne jen příkladové happy path.
Od M4 se uvažuje fuzz harness na vstupy z Lua strany (jádro běží v Ring 0,
špatná konverze je stejně nebezpečná jako bug v jádře). Lua binding marshalling se
od M4 testuje v QEMU runtime testech (reálný `lua_State` + volání bindingů), protože
hostitelský build Lua by duplikoval kernel konfiguraci.

### Krok 4 — QEMU smoke test

```bash
./tools/qemu-smoke.sh
```

Boot v QEMU s `-display none` + serial. Skript:
1. spustí QEMU s timeoutem,
2. čeká na serial marker `ASTER BOOT OK` (případně rozšířené markery),
3. vrátí 0 při nalezení markeru, nenulový kód při timeoutu/chybě.

**Toto je strojový doklad "systém bootuje".** Bez zeleného smoke testu není úkol hotový.

### Krok 4b — Runtime testy v QEMU (M2+)

Smoke test dokazuje jen "bootuje". Od M2 (IRQ/timer/PS2, kde logika závisí na hardwaru)
se přidávají **runtime testy** — hostitelské testy už na ně nestačí:

- Kernel se bootne v QEMU s **`isa-debug-exit`** zařízením; testy běží **uvnitř kernelu**
  a při úspěchu/neúspěchu **ukončí QEMU definovaným exit kódem**.
  QEMU `debugexit` vrací `(val << 1) | 1` — konvence: **pass = 99** (kernel zapíše `0x31`),
  **fail = 97** (kernel zapíše `0x30`). Build step `expectExitCode(99)`; skript
  `tools/qemu-test.sh` kontroluje 99.
- Spouští se přes `zig build runtime-test -Druntime-tests=true` nebo `tools/qemu-test.sh`.
- Framework: minimalistický runtime test modul s `expect` — bez závislosti
  na hostitelském test runneru. Chyba → výpis na serial + ukončení s fail kódem (97).
- Testy se registrují za normální kód; v produkčním buildu se stripují
  (compile-time flag `-Druntime-tests`, `comptime runtime_test.enabled`).
- **Idle watchdog:** pokud se test zacyklí (nekonečná smyčka, deadlock), QEMU by jinak
  běžel věčně a skončil jen timeoutem skriptu (`QEMU_TEST_TIMEOUT`, default 30s).
  Oddělí „test selhal" (97) od „test se zasekl" (timeout).
- **Rozsah:** věci nehostovatelné host unit testy — PFA na reálné paměti, IDT/fault
  policy, tick/časovač, vstupní fronta, později Lua bindings a renderer (M4+).
- DoD milníku zahrnuje zelený runtime test kromě host testů a smoke testu.

> Rozhodnutí pro budoucí fázi: mechanismus se implementuje od M2, ne dřív (M0–M1
> stačí smoke test). Forma je pevná už teď, aby se `tools/` nepsalo dvakrát.

---

## 2. Definition of Done (DoD)

Úkol je hotový, teprve když platí **všechno** a v hlášení je doložen reálný výstup:

- [ ] Krok 0 (baseline) proběhl před změnami.
- [ ] `zig fmt --check .` — žádné změny.
- [ ] `zig build` — projde.
- [ ] `zig build test` — 100 % zelené.
- [ ] `./tools/qemu-smoke.sh` — systém bootuje (serial marker).
- [ ] Ke každé nové logice existuje test (host unit test) nebo zdůvodnění, proč ne.
- [ ] Invarianty (`spec/invariants.md`) zkontrolovány bod po bodu.
- [ ] Kvalitní metrika zapsaná do `spec/roadmap.md`, pokud milník ovlivňuje boot/RAM/velikost.
- [ ] Na konci každého milníku proběhl optimalizační průchod (roadmapa §4, pravidlo 5):
      metriky proti cílům, benchmark před/po (`tools/bench.sh`, render throughput),
      výsledky zapsané do tabulky v `spec/roadmap.md`.
- [ ] **Dokumentace aktualizovaná** — změněné specifikace, ADR nebo roadmapa jsou součástí
      stejné změny; žádná feature bez zapsané dokumentace není hotová.
- [ ] V kódu není `TODO`, `FIXME` ani zakomentovaný blok.
- [ ] Žádný `#noqa`/obcházení formátovače bez zdůvodnění.
- [ ] Žádný existující test nebyl upraven/přeskočen bez schválení.
- [ ] Ne-obvious chyba vyřešená během vývoje je zapsaná v `spec/troubleshooting.md`
      (symptom → příčina → řešení → ověření).
- [ ] **Systém je bootovatelný** (ADR-016).

---

## 3. Deterministický (reprodukovatelný) build — ADR-014

**Cíl:** stejný commit + stejná verze Zigu = stejný výstupní hash binárky.

### Mechanismus

1. **Pinning verze:** soubor `.zig-version` v kořeni obsahuje exaktní verzi (nyní `0.16.0`).
   `build.zig` ověří, že běžící Zig odpovídá (případně varuje/ukončí).
2. **Pinning toolchainu:** doporučuje se oficiální tarball v `/opt/zig`, ne distro balíček
   (pacman může mít zpoždění a jinou verzi).
3. **Bez timestampů:** build nevkládá aktuální čas do binárky (žádný `__DATE__`/`__TIME__`,
   žádné generované timestampy). Verzování jde přes git hash (pokud je potřeba).
4. **Žádná generovaná data měnící se napříč běhy:** fonty a assety jsou `@embedFile`
   ze statických zdrojů.
5. **Vendoring:** Limine, Lua, wasm3 — fixní revize vendored v `libs/`, ne pull z netu při
   buildu.

### Ověření

```bash
./tools/verify-reproducible.sh   # build dvakrát, porovnání hashe
```

Ověření je **závazné** (součást DoD) — ne-obvious porušení determinismu (např. absolutní
cache cesta v `.debug_str`, viz `spec/troubleshooting.md` D1) se bez něj tiše vrátí.
Kontroluje se na produkčním optimize (`ReleaseSafe`).

---

## 3a. Test čistého klonu (repo je kompletně klonovatelné)

Záruka, že repozitář obsahuje **všechno** potřebné pro build z nuly (vendored `libs/`,
`.zig-version`, `hooks/`, `.github/`, `boot-log.md`, `tools/test-disk-root/`) — nic se
nečerpá z lokálních souborů mimo git.

### Postup

```bash
git clone <repo> ~/tmp/aster-clone
cd ~/tmp/aster-clone
./tools/install-hooks.sh
zig fmt --check .
zig build
zig build test
./tools/qemu-smoke.sh
./tools/capture-boot.sh --check
./tools/sync-docs.sh --check
./tools/verify-reproducible.sh
```

Klon se dělá z pracovní kopie na disku, ne přes síť — testuje se, že repozitář sám je
úplný (smazat a naklonovat znovu), ne síťová dostupnost GitHubu.

### Ověřeno (2026-08-15)

| Kontrola | Výsledek |
|---|---|
| `zig fmt --check .` | ✅ OK |
| `zig build` | ✅ OK |
| `zig build test` | ✅ 123/123 |
| `./tools/qemu-smoke.sh` | ✅ PASS |
| `./tools/capture-boot.sh --check` | ✅ OK |
| `./tools/sync-docs.sh --check` | ✅ OK |
| Runtime test s diskem (`make-test-disk.sh` + `qemu-test.sh`) | ✅ PASS (exit 99) |
| `./tools/verify-reproducible.sh` | ✅ hash shodný s originálem |
| `./tools/bench.sh` | ✅ funguje |

Hash z `verify-reproducible.sh` je v klonu **identický s originálem** — silný důkaz, že
klon je úplný.

---

## 4. Bootovatelný commit — ADR-016

Pravidlo: **každý commit musí zanechat systém spustitelný v QEMU.**

- Před každým commitem se spustí `./tools/qemu-smoke.sh` — minimálně na hlavní sestavě.
- Rozbitý boot se opravuje okamžitě, nikdy "za pár commitů".
- Výjimky (dokumentace, čistě host code mimo boot cestu) se označí explicitně.
- **Nikdy `git reset --hard` (ani destruktivní `--force`/`checkout`) bez výslovného
  svolení vývojáře.** Vrací se vždy jen jeden soubor přes `git checkout -- <soubor>`;
  destruktivní příkaz smaže nepokomentované změny i commity.

> **Git hooks:** `./tools/install-hooks.sh` nainstaluje pre-push hook, který před pushem
> spustí `./tools/capture-boot.sh --check` — boot log v dokumentaci
> (`boot-log.md`) nesmí zastarat vůči kódu. Instalaci hooků doporučujeme po klonu;
> CI to ověřuje taky.
>
> **Známé riziko (zapsáno 2026-08-08):** boot log jako CI gate je **záměrná funkce**
> (Boot proof of work), ne bug. Je nepohodlný jen při obcházení hooku (např. stash)
> nebo změně prostředí/akcelerace — hook se nemá obcházet; boot log se regeneruje
> přes `./tools/capture-boot.sh`. Pokud hook padá bez obcházení, je to chyba a hlásí se.

---

## 5. Nástroje

| Nástroj | Účel |
|---|---|
| `zig` | build, test, fmt (verze v `.zig-version`) |
| `qemu-system-x86_64` | emulace cíle (BIOS + UEFI); akcelerace KVM, když je k dispozici |
| `xorriso` / `mtools` | tvorba bootovatelného ISO / FAT image pro Limine |
| `tools/qemu-accel.sh` | vyecho `-enable-kvm`, pokud je `/dev/kvm` přístupný (jinak TCG) |
| `tools/qemu-smoke.sh` | automatický boot test (serial marker + timeout; auto KVM) |
| `tools/qemu-test.sh` | in-QEMU runtime testy (isa-debug-exit; auto KVM) |
| `tools/bench.sh` | měření metrik z `roadmap.md` |

---

## 6. Závislosti (nástroje) — stav k datu konsolidace specifikace

| Nástroj | Stav | Poznámka |
|---|---|---|
| `qemu-system-x86_64` | ✅ nainstalováno | |
| `clang`, `lld`, `gcc` | ✅ nainstalováno | |
| `zig` | ✅ nainstalováno (0.16.0) | instalace: oficiální tarball / distro, viz `.zig-version` |
| `xorriso` / `mtools` | ✅ nainstalováno | ISO build ověřen v M0 |
| `limine` | ✅ vendor | `libs/limine/` (12.5.2) |
| `lua 5.4.8` | ✅ vendor | `libs/lua-5.4/` |
