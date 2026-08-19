# Docs-Audit — 2026-08-19

Audit dokumentace repozitáře Aster OS. HEAD `710df51` (před začátkem oprav).

**Verze projektu:** `0.7.0-alpha.2` (milník M7 — Runtime, in progress)
**Rozsah:** 64 markdown souborů mimo `libs/` + build/CI konfigurace + `tools/` skripty, křížově proti 80 `.zig`, 14 `.lua` a 11 `.sh` souborům.
**Metoda:** inventura → mapa závislostí → automatizovaná kontrola odkazů a cest → ruční křížová kontrola dokumentace proti kódu, `build.zig`, CI a boot logu.

---

## 1. SHRNUTÍ (Executive Summary)

### Celkové skóre: **74 / 100**

> Předběžné skóre po Fázi 1 bylo 78. Hloubková kontrola je snížila na 74 — hlavně kvůli nálezu **K1** (dokumentovaný příkaz, který vyrobí obraz disku zavěšující ext2 driver) a **K5** (podle setup instrukcí nelze dokončit dokumentovaný workflow).

| Kritérium | Váha | Skóre | Komentář |
|---|---:|---:|---|
| Přesnost a aktuálnost | 30 % | **58** | Nejslabší místo. Fáze B milníku M7 je hotová, ale čtyři dokumenty tvrdí opak; metriky se rozcházejí s CI-vynuceným boot logem; tabulka Lua bindingů je o tři řádky pozadu za kódem. |
| Úplnost (Coverage) | 25 % | **70** | Chybí `spec/storage.md` (jediný velký subsystém bez specifikace), chybí prerekvizity pro build, chybí Phase B v CHANGELOGu. |
| Srozumitelnost a struktura | 20 % | **92** | Výborná. Konzistentní nadpisy, tabulky, čísla sekcí, normativní vs. informativní pasáže jsou rozlišené. |
| Odkazy a reference | 15 % | **88** | **0 rozbitých relativních odkazů** ze 64 souborů. Sráží to jen 4 neexistující cesty uvedené v inline kódu. |
| Konzistence | 10 % | **72** | Duplikované ručně udržované tabulky (2× ADR index, 2× index specifikací) už reálně driftly; míchá se `Accepted` / `Přijato`. |

**Vzorec:** 58×0,30 + 70×0,25 + 92×0,20 + 88×0,15 + 72×0,10 = **73,9 ≈ 74**

### 3 největší kritické slabiny

1. **Milník M7 Fáze B je hotový v kódu, ale nedokončený ve čtyřech dokumentech.** `spec/roadmap.md` ji k 2026-08-18 označuje za hotovou (ADR-026 + ADR-027, `src/kernel/apps/calculator.zig`, KI operace `surface_render`/`key_input`), ale `README.md`, `CHANGELOG.md` i `THIRD-PARTY-NOTICES.md` stále píší „Next: surface model + calculator (Phase B)". CHANGELOG dokonce **nemá pro Fázi B žádný záznam** — celá etapa se dvěma přijatými ADR v ručně kurátorovaném changelogu chybí. Nový člen týmu si přečte README, začne implementovat kalkulačku a zjistí, že už existuje.

2. **Dokumentace KI není „ABI-pravda", jak sama tvrdí.** `spec/kernel-interface.md` §4 pravidlo 6 stanoví: *„Dokumentace KI je ABI-pravda. Implementace se může měnit; signatury ne."* Přesto `spec/runtime.md` §4 — kanonická tabulka toho, co Lua vidí — neuvádí `input.mouse_wheel()`, `time.ms()`, `time.of_day_ms()`, `runtime.spawn()`, `runtime.surface_render()` ani `runtime.key_input()`, všechny registrované v `src/kernel/lua/bindings.zig`. Sub-op čísla pro `Runtime` jsou dokumentovaná jako `0/1/2`, kód má `0–5`.

3. **Chybí specifikace úložiště.** Storage je jediný velký subsystém bez vlastního dokumentu. `src/kernel/fs/` (ext2, gpt, file, tar, bytes), `src/kernel/drivers/` (virtio-blk, block, pci) a devět KI operací mají jako „detail" odkaz na roadmapu a `lua-wm.md`. Každý jiný subsystém — graphics, input, timer, memory, runtime — svůj `spec/*.md` má. Pro nového člena týmu je disková vrstva jediná, kterou musí rekonstruovat z kódu, ADR a poznámek v jiných dokumentech.

### 3 největší silné stránky

1. **Odkazová integrita je bezchybná.** Automatická kontrola všech relativních odkazů napříč 64 soubory našla **nula rozbitých**. Při této velikosti a hustotě křížových odkazů (spec dokumenty se odkazují navzájem, na ADR, na kód i na handoffy) je to výjimečné.

2. **Dokumentace je vynucená CI, ne dobrou vůlí.** `tools/capture-boot.sh --check` blokuje push, když `boot-log.md` neodpovídá čerstvému bootu; `tools/sync-docs.sh --check` hlídá překladovou vrstvu přes git historii, ne přes ručně psaná data. To je architektura dokumentace, ne jen dokumentace — a je to výrazně nad úrovní běžnou u hobby projektů.

3. **Poctivost o vlastních mezerách.** `spec/non-goals.md` vede SMP správně jako „⚠️ Částečně" s přesným vysvětlením (bring-up hotový, scheduler BSP-only), místo aby to zamlčel. `kernel-interface.md` §3.7 sám označuje nekonzistenci argumentové konvence za „známou a otevřenou" a určuje vlastníka. `spec/handoffs/` obsahuje šest reálných, uzavřených, dohledatelných diagnóz včetně slepých uliček. Dokumentace nelže o stavu — jen na několika místech nestíhá.

---

## 2. KRITICKÉ CHYBY (Okamžitá rizika)

Seřazeno podle dopadu. „Kritické" = způsobí, že čtenář udělá špatnou věc, ne že je text nehezký.

### K1 — `spec/adr/023` dokumentuje příkaz, který vyrobí obraz disku zavěšující OS

**Soubor:** `spec/adr/023-filesystem-ext2-non-posix.md`, sekce „Přesná invokace (testovací obrazy, `tools/make-test-disk.sh`)"

Dokumentovaný příkaz:

```bash
mke2fs -t ext2 -O ^dir_index -d <rootfs_dir> -E offset=$((2048 * 512)) <disk>.img
```

Skutečná invokace v `tools/make-test-disk.sh`:

```bash
mke2fs -q -t ext2 -b 1024 -O ^dir_index -d "$STAGING" -E offset=$OFFSET "$OUT"
```

Skript ve vlastním komentáři říká: *„The exact mke2fs invocation is the ADR-023 contract"* a dále: *„CI picked 4096 B for the same 15 MiB filesystem where local dev machines picked 1024 B, and **4096 B blocks hang the ext2 driver**, spec/troubleshooting.md C54."*

**Riziko:** ADR nadepsaný „Přesná invokace" postrádá právě to `-b 1024`, které bylo přidáno proto, aby se předešlo zaseknutí driveru. Kdo příkaz zkopíruje (a ADR ho k tomu přímo vybízí), dostane podle verze e2fsprogs obraz se 4096B bloky a systém se zasekne — bez chybové hlášky, jen hang, který se na TCG tváří jako pomalost. Zároveň je to porušení vlastního pravidla ADR-014 (determinismus napříč hosty).

**Oprava:** ADR se podle pravidel projektu nepřepisují dodatečně — použij existující precedens (`Status update` blockquote jako v ADR-008/010) a doplň invokaci:

````markdown
> **Status update (2026-08-19):** invokace níže byla neúplná — chyběl explicitní
> `-b 1024`. Bez něj volí `mke2fs` velikost bloku heuristicky podle verze
> e2fsprogs a hosta; 4096B bloky zavěsí ext2 driver (`spec/troubleshooting.md`
> C54) a porušují ADR-014. Závazná invokace je nyní ta v
> `tools/make-test-disk.sh`.

### Přesná invokace (testovací obrazy, `tools/make-test-disk.sh`)

```bash
parted -s <disk>.img mklabel gpt
parted -s <disk>.img mkpart primary ext2 2048s 100%
mke2fs -q -t ext2 -b 1024 -O ^dir_index -d <rootfs_dir> \
       -E offset=$((2048 * 512)) <disk>.img
```

`-b 1024` je součást kontraktu, ne detail: bez něj se velikost bloku liší
host od hosta (ADR-014) a 4096B varianta zavěsí driver (C54).
````

---

### K2 — Čtyři dokumenty tvrdí, že hotová Fáze B teprve přijde

| Soubor | Tvrzení | Realita |
|---|---|---|
| `README.md` (Status) | „Remaining: surface model + calculator (Phase B), benchmark (Phase C)" | Zbývá **jen** Fáze C |
| `README.md` (Roadmap tabulka) | „M7 🔄 Runtime: wasm (Phase A done; Phase B/C pending)" | Fáze B hotová 2026-08-18 |
| `CHANGELOG.md` ř. 46–54 | „Next: surface model + calculator (Phase B), benchmark (Phase C)" | + **chybí celý záznam o Fázi B** |
| `THIRD-PARTY-NOTICES.md` §7 | wasm3 „hosts Aster wasm programs (Phase A test programs `hello`/`fault`)" | Hostí i kalkulačku (ADR-026/027) |

**Důkazy hotové Fáze B:** `spec/roadmap.md` ř. 448 („**Stav (2026-08-18):** wasm Fáze B **hotová** — surface model + kalkulačka"), ř. 525 (`[x] Surface model + kalkulačka — Fáze B (hotovo 2026-08-18, ADR-026 + ADR-027)`), `spec/README.md` („Fáze A+B hotové"), `src/kernel/apps/calculator.zig`, `RuntimeOp.surface_render = 4` a `key_input = 5` v `src/kernel/api/runtime.zig`, `build.zig` ř. 223 instaluje `apps/calculator.wasm`, `tools/make-test-disk.sh` ho stageuje na disk.

**Riziko:** README a CHANGELOG jsou veřejné rozhraní projektu. Podhodnocují hotovou práci a rozporují interní zdroj pravdy o celou etapu. Chybějící záznam v CHANGELOGu navíc znamená, že dvě přijatá ADR (026, 027) nemají ve veřejné historii žádnou stopu.

**Oprava (README.md, sekce Status):**

```markdown
- **M7 (Runtime) — wasm Phase B done:** wasm3 vendored, `Runtime.spawn(.Wasm)`,
  surface model + calculator app loaded from disk (ADR-026, ADR-027).
  Remaining: benchmark wasm vs Lua (Phase C).
  Multi-layout keyboard is done (ADR-024, US/CZ switchable at runtime).
```

**Oprava (README.md, Roadmap tabulka):**

```markdown
| M7 🔄 | Runtime: wasm (Phase A+B done; Phase C benchmark pending), multitasking, app isolation |
```

**Oprava (CHANGELOG.md)** — doplnit za stávající Phase A odstavec nový záznam:

```markdown
* **Wasm (M7) — Phase B surface model and the calculator app:** wasm programs
  render through a fixed 224×160 surface composited by the WM via the new
  `runtime.surface_render` KI op, and receive keystrokes through
  `runtime.key_input` — the WM no longer needs to know which runtime backs a
  window (ADR-026). The calculator (`src/kernel/apps/calculator.zig`, built to
  `wasm32-freestanding`) is the first real wasm application; it is staged onto
  the test disk as `/apps/calculator.wasm` and discovered by the launcher
  scanning `/apps/` at runtime, so applications ship independently of the
  kernel image (ADR-027). Next: benchmark wasm vs Lua (Phase C).
```

A upravit poslední větu Phase A odstavce z `Next: surface model + calculator (Phase B), benchmark (Phase C).` na `Next: Phase B (surface model + calculator).`

---

### K3 — Metriky v README a roadmapě odporují vlastnímu „proof of work"

`README.md` uvádí ve dvou místech kernel **661 KiB** a First Frame **≈ 29 ms**; `spec/roadmap.md` ř. 61 a 138 totéž.

`boot-log.md`, generovaný `tools/capture-boot.sh` z reálného bootu commitu `c74f828`, ukazuje:

```
[ OK ] boot sequence    complete · 578 KiB · 24 ms
```

Tohle není šum: `capture-boot.sh` normalizuje před porovnáním akcelerátor a naměřený čas, ale **velikost kernelu záměrně ponechává** s komentářem *„The kernel size stays (it is deterministic)"*. Číslo 578 KiB je tedy CI-vynucené a pre-push hookem chráněné. Rozdíl 83 KiB (12,6 %) znamená, že metrika v README a roadmapě je zastaralá.

**Riziko:** README má sekci „Boot proof of work", která boot log prezentuje jako důkaz aktuálnosti. Vlastní důkaz usvědčuje sousední tabulku z nepřesnosti. Zároveň je porušené ADR-015 (měření po každém milníku) a DoD bod „Kvalitní metrika zapsaná do `spec/roadmap.md`".

**Oprava:** spustit `tools/bench.sh`, přeměřit a synchronizovat obě čísla. Do doby přeměření aspoň sjednotit na hodnotu z boot logu a v README nahradit větu:

```markdown
Boot times from `tools/bench.sh`: the M0–M3 rows are approximated kernel-only
times (the bootloader is subtracted); M4+ are kernel-only on KVM. The current
kernel is **578 KiB** — the authoritative, CI-verified value is always the one
in [`boot-log.md`](boot-log.md), which the pre-push hook regenerates.
```

---

### K4 — Kanonická tabulka Lua bindingů je neúplná (porušení vlastního normativního pravidla)

**Soubor:** `spec/runtime.md` §4 „Lua bindings konvence"

| Řádek tabulky | Dokumentováno | V `src/kernel/lua/bindings.zig` | Chybí |
|---|---|---|---|
| `input` | 8 funkcí | 9 funkcí | **`input.mouse_wheel()`** (ř. 359) |
| `timer` | `time.ticks()` | `ticks`, `ms`, `of_day_ms` | **`time.ms()`, `time.of_day_ms()`** (ř. 367–368) |
| `runtime` | `runtime.reload()` | `reload`, `spawn`, `surface_render`, `key_input` | **`spawn`, `surface_render`, `key_input`** (ř. 384–386) |

Navíc `spec/runtime.md` ř. 57 tvrdí: *„Sub-op čísla pro `Runtime` v KI: `0=spawn`, `1=kill`, `2=status` (rozšiřitelné)."* — kód má `reload = 3`, `surface_render = 4`, `key_input = 5`. Tři zmrazená čísla KI nejsou nikde v dokumentaci.

Poznámka pod tabulkou navíc nese doslova: *„`spawn` se neexponuje do M7"* — jsme v M7, `spawn` je exponovaný, formulace je dnes matoucí.

**Riziko:** `spec/kernel-interface.md` §4/6 říká „Dokumentace KI je ABI-pravda". Pokud tři zmrazená sub-op čísla existují jen v kódu, pravidlo neplatí a při přechodu na Ring 3 (ADR-018) je zdrojem pravdy kód, ne spec — přesně to, čemu má §4/6 zabránit.

**Oprava (`spec/runtime.md` §4, tři řádky tabulky):**

```markdown
| `input` | `input.next_event()`, `input.mouse_x()`, `input.mouse_y()`, `input.mouse_left()`, `input.mouse_right()`, `input.mouse_middle()`, `input.mouse_wheel()`, `input.set_layout(name)`, `input.layout_name()` |
| `timer` | `time.ticks()`, `time.ms()`, `time.of_day_ms()` |
| `runtime` | `runtime.reload()` (restart shellu, M5), `runtime.spawn(kind, name)` (M7), `runtime.surface_render(...)` a `runtime.key_input(...)` (surface model, M7 Fáze B — ADR-026) |
```

**Oprava (`spec/runtime.md` ř. 57):**

```markdown
Sub-op čísla pro `Runtime` v KI: `0=spawn`, `1=kill`, `2=status`, `3=reload`,
`4=surface_render`, `5=key_input` (rozšiřitelné, čísla zmrazená — `kernel-interface.md` §4/2).
```

A vypustit z odstavce „Neexponované KI operace" doložku o `spawn`.

---

### K5 — Podle setup instrukcí nelze dokončit dokumentovaný workflow

`README.md` §Prerequisites i `CONTRIBUTING.md` §Setting up i `spec/verification.md` §6 uvádějí shodně: Zig, QEMU, xorriso/mtools, a vendored Limine/Lua/wasm3.

Dokumentované příkazy ale potřebují víc:

| Dokumentovaný příkaz | Nedokumentovaná závislost |
|---|---|
| `./tools/make-test-disk.sh disk.img` (README §Quick start) | **`parted`**, **`e2fsprogs`** (`mke2fs`) |
| `zig build shell-test` (CONTRIBUTING §Verify before you finish) | **hostitelský interpret `lua5.4`** — `tools/lua-shell-test.sh` bez něj skončí `'lua' not found` |

Že jde o reálné závislosti, potvrzuje `.github/workflows/ci.yml`, který instaluje `qemu-system-x86 xorriso mtools parted e2fsprogs lua5.4`. CI o nich ví, dokumentace ne. `spec/verification.md` §6 navíc **vůbec neuvádí wasm3**, přestože je vendorovaný od M7 a README i CONTRIBUTING ho zmiňují.

**Riziko:** přímo proti cíli tohoto auditu — nový člen týmu narazí na dvě selhání ve „verify before you finish" pipeline, aniž by dokumentace řekla proč. Zároveň `spec/verification.md` §3a („Test čistého klonu") tvrdí, že repo obsahuje *„všechno potřebné pro build z nuly"* — což platí pro repo, ale ne pro hostitelské nástroje, a text to nerozlišuje.

**Oprava (`README.md` §Prerequisites):**

```markdown
## Prerequisites

- **Zig** — exact version in [`.zig-version`](.zig-version) (0.16.0), not a distro package.
- **QEMU** (`qemu-system-x86_64`) — target emulation.
- **ISO tools:** xorriso, mtools.
- **Test-disk tools:** parted, e2fsprogs (`mke2fs`) — required by `tools/make-test-disk.sh`.
- **Lua 5.4 interpreter** (`lua5.4`) — host-side only, required by `zig build shell-test`.
- Limine, Lua 5.4.8 and wasm3 are vendored in `libs/` — no system packages needed.

Full tool table and dependency status: [`spec/verification.md`](spec/verification.md) §5–6.
```

Do `spec/verification.md` §6 doplnit řádky:

```markdown
| `parted`, `e2fsprogs` (`mke2fs`) | ✅ nainstalováno | `tools/make-test-disk.sh` (ADR-023 invokace, `-b 1024`) |
| `lua5.4` (host interpret) | ✅ nainstalováno | jen pro `zig build shell-test` (`tools/lua-shell-test.sh`); kernel má vlastní vendored Lua |
| `wasm3` | ✅ vendor | `libs/wasm3/` (v0.5.0), M7 |
```

---

### K6 — Status ADR-008 a ADR-010 odporuje oběma indexům i vlastní šabloně

`spec/adr/008-event-loop-not-mlfq.md` a `spec/adr/010-no-filesystem-yet.md` mají v hlavičce `**Status:** Accepted`. Oba indexy (`spec/architecture.md` §4 i `spec/adr/README.md`) je vedou jako **Superseded**. Vlastní šablona v `spec/adr/README.md` přitom předepisuje `**Status:** <Proposed / Accepted / Superseded by ADR-0YY>`.

Supersession je v obou souborech vysvětlená — ale až v `> Status update` blockquotu pod hlavičkou. Kdo čte strojově (grep, budoucí generátor indexu) nebo jen skenuje hlavičky, dostane špatnou odpověď.

**Oprava** — sjednotit strojově čitelné pole a ponechat blockquote jako vysvětlení:

```markdown
**Status:** Superseded by ADR-017 (pro M7; platí pro M0–M6)
**Datum:** 2026-08-06
```

```markdown
**Status:** Superseded by ADR-023
**Datum:** 2026-08-06
```

---

### K7 — Rozpor mezi dokumentovaným a skutečným timeoutem CI

`spec/troubleshooting.md` B4 radí: *„na TCG dát `QEMU_TEST_TIMEOUT` ≥ ~600 s"*, protože pomalost na TCG se tváří jako hang.

`.github/workflows/ci.yml` používá `QEMU_TEST_TIMEOUT=90` — a CI runnery TCG jsou (`Boot smoke test (QEMU, TCG on CI runners)`).

Jedno z toho je špatně: buď je rada v B4 nadsazená a měla by odrážet, že 90 s v CI stačí (po opravě velikosti bloku na 1024 B), nebo je CI křehká a čeká na náhodný flake.

**Oprava:** doplnit do B4 rozlišení a odkázat na reálnou CI hodnotu, např.:

```markdown
… na TCG dát `QEMU_TEST_TIMEOUT` s rezervou; po pinnutí bloku na 1024 B
(C54) stačí v CI **90 s** (`.github/workflows/ci.yml`). Hodnota ≥ ~600 s
platila pro 4096B obrazy před opravou a je dnes potřeba jen při
`diag_verify_reads` (dvojité čtení ≈ 2× doba běhu).
```

---

### K8 — Uživatelská příručka na disku tvrdí „read-only" a mlčí o `/apps/`

**Soubor:** `tools/test-disk-root/README` (v OS se otevírá přes Super+E jako `/README`; `README.md` na něj odkazuje jako na „the shell's user guide")

Dvě chyby:

1. Druhý řádek: *„Deterministic image built by tools/make-test-disk.sh (GPT + ext2 **read-only**, ^dir_index)."* — ext2 je **read-write od M7.1** (ADR-023, `non-goals.md`, README). Zbytek téhož souboru popisuje ukládání (Ctrl+S), mazání do koše, přejmenování (F2) a zakládání souborů (Shift+F4). Dokument si odporuje ve vlastním rozsahu.
2. Popisuje `/wm/`, ale **`/apps/` vůbec nezmiňuje** — přestože `make-test-disk.sh` tam stageuje `calculator.wasm` a launcher `/apps/` skenuje (ADR-026/027). Vlajková funkce Fáze B chybí v jediné uživatelské příručce, kterou uživatel v OS uvidí.

**Oprava (řádek 3):**

```
Deterministic image built by tools/make-test-disk.sh (GPT + ext2 read-write,
^dir_index, 1024 B blocks).
```

**Oprava — nová sekce za blok `/wm/`:**

```
/apps/ directory (applications)
  calculator.wasm   WebAssembly calculator, discovered at boot

  The launcher (Super+Space) scans /apps/ at runtime, so applications ship
  and update independently of the kernel image. Executable .wasm files are
  shown in green in the file browser. A wasm app that traps is dropped
  without taking the desktop down.
```

---

### K9 — Čtyři neexistující cesty uvedené jako kód

Automatická kontrola cest v inline kódu:

| Soubor | Uvedená cesta | Skutečnost |
|---|---|---|
| `spec/lua-wm.md` | `src/kernel/lua/libc.zig` | `src/kernel/libc.zig` — přesunuto v M7 (CHANGELOG to popisuje: *„moved out of `lua/` into `src/kernel/libc.zig`"*) |
| `spec/roadmap.md` | `src/kernel/lua/libc.zig` | totéž |
| `spec/2026-08-15-self-audit.md` | `docs/code-style.md` | `spec/code-style.md` |
| `CONTRIBUTING.md` | `spec/adr/NNN-name.md` | záměrný placeholder — **není chyba**, ponechat |

**Oprava:** `sed -i 's|src/kernel/lua/libc.zig|src/kernel/libc.zig|g' spec/lua-wm.md spec/roadmap.md` a opravit `docs/` → `spec/` v self-auditu (nebo tam nechat, viz P3-3 — audity jsou historické záznamy).

---

## 3. KONTROLA ÚPLNOSTI (Gap Analysis)

Části kódu a témata, která **zcela chybí** v dokumentaci, seřazená podle dopadu na nového člena týmu.

### G1 — `spec/storage.md` (P1)

**Nepokrytý kód:** `src/kernel/fs/ext2.zig`, `gpt.zig`, `file.zig`, `tar.zig`, `bytes.zig`, `src/kernel/drivers/block.zig`, `virtio.zig`, `pci.zig`, `src/kernel/api/storage.zig` (9 sub-op).

Dnes je informace rozptýlená mezi `spec/roadmap.md` (M7.1), `spec/lua-wm.md`, ADR-023 a `troubleshooting.md`. `kernel-interface.md` §2 na to explicitně odkazuje jako na „detail" — ale roadmapa je plán, ne specifikace subsystému.

Chybějící obsah: vrstvy (KI storage → file → ext2 → gpt → block → virtio-blk → PCI), model handlů a jejich životnost, non-POSIX sémantika (co `open` znamená, co ne), podporovaný subset ext2 a co se odmítá, chování bez disku, kooperativní čtení (jak se pomalá operace vejde do synchronního KI kontraktu, `kernel-interface.md` §6.2), initfs vs. disk, a **výjimka návratové hodnoty** (`storage` balí status do horních 32 bitů `u64`, dnes zmíněná jednou větou v `kernel-interface.md` §3.7).

### G2 — Prerekvizity build prostředí (P1)

Viz K5. `parted`, `e2fsprogs`, hostitelský `lua5.4`, wasm3 v tabulce závislostí.

### G3 — Záznam o M7 Fázi B v `CHANGELOG.md` (P1)

Viz K2. Dvě přijatá ADR (026, 027), nový KI povrch a první reálná wasm aplikace nemají ve veřejné historii žádný záznam.

### G4 — Specifikace wasm runtime (P2)

**Nepokrytý kód:** `src/kernel/wasm/wasm.zig`, `cimport.zig`, `src/kernel/apps/*.zig`.

ADR-026 a ADR-027 popisují *rozhodnutí* (import surface, surface model, apps z disku), ale neexistuje dokument popisující *jak to funguje*: import surface, který kernel wasm modulům nabízí, trap containment, jak se kompilují aplikace (`wasm32-freestanding`, `build.zig` ř. 212 řeší strip `export fn` v Zig 0.16), jak se dostanou na disk, jak je launcher objeví. `spec/runtime.md` §7.1 se dotýká WASI výhledu, ne dnešního stavu.

Buď `spec/wasm.md`, nebo rozšíření `spec/runtime.md` o sekci „Wasm runtime (M7)".

### G5 — Specifikace scheduleru / SMP (P2)

**Nepokrytý kód:** `src/kernel/sched/task.zig`, `sync.zig`, `src/kernel/cpu/smp.zig`, `smp_tramp.s`, `apic.zig`, `acpi.zig`.

ADR-017 definuje concurrency model, `non-goals.md` shrnuje stav SMP jednou buňkou tabulky, handoff H5 popisuje jednu konkrétní chybu v trampolíně. Chybí souvislý popis: co je Task, jak funguje preemptivní RR, jak se dělají kritické sekce bez zámků, co dělají AP jádra po bootu, jak vypadá `tickPrograms()` vůči event loopu. Pro nového člena je to nejhůř rekonstruovatelná část systému, protože se tu nejvíc míchá assembly, IRQ a Lua.

### G6 — Index handoffů (P2)

`spec/architecture.md` §8 slibuje u `handoff.md`: *„Formální postup pro nevyřešené problémy **+ seznam handoffů**"*. Seznam v `handoff.md` není. Ani `spec/README.md` (23 položek), ani `architecture.md` §8 adresář `spec/handoffs/` neuvádějí — šest existujících dokumentů H1–H6 není z žádného indexu dosažitelných.

**Oprava — nová sekce na konec `spec/handoff.md`:**

```markdown
## 6. Seznam handoffů

| ID | Problém | Datum | Status |
|---|---|---|---|
| [H1](handoffs/01-xorriso-failed-command.md) | Falešné `failed command: xorriso`, cache neinvaliduje výstup | 2026-08-07 | closed |
| [H2](handoffs/02-debug-invalid-memory-operand.md) | Debug build: `invalid memory operand` u `lidtq`/`invlpg` | 2026-08-08 | closed |
| [H3](handoffs/03-runtime-fs-test-fault.md) | Page fault v reload testu s diskem (low-memory stránky mimo hhdm) | 2026-08-09 | closed |
| [H4](handoffs/04-double-buffering-heap-corruption.md) | Heap corruption při double bufferingu (ISR neukládal XMM) | 2026-08-09 | closed |
| [H5](handoffs/05-smp-ap-rsvd-page-fault.md) | SMP: `#PF(RSVD)` na AP po zapnutí pagingu (`getip` trik v trampolíně) | 2026-08-16 | closed |
| [H6](handoffs/06-c-stdio-storage-regression.md) | `file.open` selhává — artefakt opakovaně použitého test disku | 2026-08-17 | closed (2026-08-18) |

Otevřené handoffy: **žádné.**
```

### G7 — Anglická vrstva `docs/` je prázdná a její brána je fakticky no-op (P2)

`docs/` obsahuje jedinou stránku `index.md`, která sama sebe označuje za výjimku ze sync checku. `tools/sync-docs.sh` iteruje `docs/*.md`, přeskočí stránky bez `source:` — takže dnes projde vždy, bez ohledu na stav. `README.md` přitom odkazuje na „the project's complete English documentation".

Dvě dílčí věci k opravě i před tím, než vznikne první překlad:

- `docs/index.md` končí ručně psaným „Last audited on **2026-08-16**" — přesně ten druh ručního data, který text o pár odstavců výš odmítá jako nespolehlivý (*„Sync is enforced by git, not by hand-edited dates"*).
- Glob `docs/*.md` nezachytí podadresáře. Až vzniknou překlady v `docs/spec/`, brána je tiše přeskočí. Změnit na `find docs -name '*.md'`.

### G8 — Chybí „start here" pro nového člena týmu (P3)

Zadání tohoto auditu zní: *„může okamžitě použít jakýkoliv nový člen týmu."* Dnes vede README k `spec/README.md` (23 dokumentů) a `CONTRIBUTING.md` k dalším čtyřem. Neexistuje jedna stránka „první den": co si přečíst v jakém pořadí, jak dostat systém do bootu, jak si ověřit, že prostředí funguje, kam sáhnout při první chybě. `spec/README.md` §„Jak konzultovat návrh" je k tomu nejblíž, ale je organizovaný podle *otázky*, ne podle *pořadí*.

---

## 4. DETAILNÍ AUDIT PO SOUBORECH

Zahrnuty jen soubory s nálezy. Ostatní (`LICENSE`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, většina ADR, `spec/manifest.md`, `spec/invariants.md`, `spec/code-style.md`, `spec/memory.md`, `spec/desktop-ui.md`, `spec/editor.md`, `spec/debugging.md`, všech 6 handoffů) prošly bez nálezu.

### `README.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | Status i roadmap tabulka tvrdí, že Fáze B zbývá (**K2**) | Přepsat oba bloky — text v K2 |
| 2 | Kernel 661 KiB / ≈29 ms vs. 578 KiB / 24 ms v `boot-log.md` (**K3**) | Přeměřit `tools/bench.sh`, sjednotit; text v K3 |
| 3 | Prerequisites bez `parted`, `e2fsprogs`, hostitelského `lua5.4` (**K5**) | Nová sekce — text v K5 |
| 4 | Odkaz „Full tool table and dependency status: `spec/verification.md` §6" — §6 je jen tabulka závislostí, tabulka nástrojů je §5 | Změnit na `§5–6` |
| 5 | Milestone metrics: řádek M6 „362 KiB" je nižší než M5 „371 KiB" bez vysvětlení v README (roadmapa to vysvětluje poklesem z dead code, README ne) | Doplnit půlvětu: `(M6 dropped below M5 by dead-code removal)` |

### `CHANGELOG.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | Chybí celý záznam o M7 Fázi B (**K2, G3**) | Vložit odstavec z K2 |
| 2 | Phase A odstavec končí „Next: surface model + calculator (Phase B), benchmark (Phase C)" — už neplatí | `Next: Phase B (surface model + calculator).` |

### `CONTRIBUTING.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | §Setting up neuvádí `parted`, `e2fsprogs`, hostitelský `lua5.4` (**K5**) | Doplnit stejný seznam jako v README |
| 2 | §Development workflow uvádí 9-krokovou pipeline, `spec/verification.md` §1 jen 5 kroků (viz níže) — derivovaný dokument je úplnější než kanonický | Sjednotit směrem do spec (P1-6) |

### `THIRD-PARTY-NOTICES.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | §7 wasm3: „Phase A test programs `hello`/`fault`" (**K2**) | `hosts Aster wasm programs (test programs hello/fault, the calculator app) behind the generic Runtime API (ADR-006, ADR-011, ADR-026)` |
| 2 | §7 wasm3 nemá verzi, zatímco Lua má „5.4.8"; CHANGELOG uvádí wasm3 v0.5.0 | `| **What** | wasm3 v0.5.0 (WebAssembly interpreter, C), vendored in `libs/wasm3/` |` |
| 3 | Zdvojený horizontální oddělovač před `## 8. Zig` (`---` + `---` bez prázdného řádku) | Odstranit druhý `---`, přidat prázdný řádek před nadpis |

### `boot-log.md`

Bez nálezu — je generovaný, CI-vynucený a aktuální. **Je to nejspolehlivější dokument v repu**; ostatní by se měly narovnat podle něj, ne naopak.

### `spec/README.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | Tabulka „Dokumenty" (23 položek) neuvádí `handoffs/` (**G6**) | Přidat řádek 24: `| 24 | [handoffs/](handoffs/) | Handoff dokumenty H1–H6 (uzavřené diagnózy nevyřešených problémů). |` |
| 2 | §Stav: „Verze specifikace: 1.0 (draft)" — nikde jinde v repu se toto číslo neobjevuje ani neaktualizuje | Buď zavést a udržovat, nebo nahradit odkazem na `.version` |
| 3 | Je to druhý index specifikací vedle `architecture.md` §8, s odlišným obsahem (**viz níže**) | Jeden zrušit, druhý označit za kanonický |

### `spec/architecture.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | §7 struktura repa: `apps/ (hello, fault)` — chybí `calculator` | `apps/ (hello, fault, calculator)` |
| 2 | §7: `troubleshooting.md # vyřešené pasti a lekce (C1..C51, H1..H7)` — reálně **C1–C54, B1–B4, H1–H6** | `(C1..C54, B1..B4, H1..H6)` |
| 3 | §7 struktura repa vůbec neuvádí `docs/`, `hooks/`, `.github/`, `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, `THIRD-PARTY-NOTICES.md`, `boot-log.md`, `limine.conf`, `.gitattributes`, `.version` | Doplnit — nový člen týmu podle tohoto stromu nenajde ani CI, ani hooky |
| 4 | §7 neuvádí `spec/handoffs/` položkově, jen jako adresář bez obsahu (**G6**) | Doplnit `# H1–H6, viz handoff.md §6` |
| 5 | §8 „Index specifikací" neuvádí `2026-08-15-self-audit.md`, `2026-08-16-re-audit.md`, `handoffs/` — na rozdíl od `spec/README.md`, který audity uvádí | Sjednotit (viz P1-5) |
| 6 | §4 ADR tabulka duplikuje `spec/adr/README.md` a už driftla: ADR-023 a ADR-024 mají v každé tabulce jiný popis; §4 používá `Accepted`, adr/README `Přijato` | Viz P1-5 |

### `spec/adr/README.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | Stav `Přijato` vs. `Accepted` v ADR souborech i v `architecture.md` §4 | Sjednotit na `Accepted` (shodné s `**Status:**` polem v souborech) |
| 2 | Duplikát tabulky z `architecture.md` §4 (**P1-5**) | Ponechat tuto jako kanonickou, v `architecture.md` §4 nahradit odkazem |

### `spec/adr/023-filesystem-ext2-non-posix.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | „Přesná invokace" bez `-b 1024` → obraz zavěsí driver (**K1**) | Status update + opravený blok, text v K1 |

### `spec/adr/008-event-loop-not-mlfq.md`, `spec/adr/010-no-filesystem-yet.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | `**Status:** Accepted` vs. „Superseded" v obou indexech a vs. vlastní šablona (**K6**) | `Superseded by ADR-017` / `Superseded by ADR-023`, text v K6 |

### `spec/runtime.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | §4 tabulka bindingů: chybí `mouse_wheel`, `ms`, `of_day_ms`, `spawn`, `surface_render`, `key_input` (**K4**) | Tři přepsané řádky, text v K4 |
| 2 | ř. 57: sub-op čísla Runtime `0/1/2`, kód má `0–5` (**K4**) | Přepsaná věta, text v K4 |
| 3 | Poznámka „`spawn` se neexponuje do M7" je v M7 matoucí | Vypustit |
| 4 | „Neexponované KI operace: … `timer.sleep_ms` (… kooperativní sleep přijde s M7)" — jsme v M7, `timer.md` §3 sleep popisuje jako existující kooperativní mechanismus, ale bez Lua bindingu | Přeformulovat na `binding zatím nemá (KI sub-op existuje, kooperativní sleep viz timer.md §3)` |

### `spec/kernel-interface.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | §2 tabulka: `storage.zig` má jako „Detail" odkaz na `spec/roadmap.md` M7.1 a `spec/lua-wm.md` — jediný modul bez vlastní specifikace (**G1**) | Po vzniku `spec/storage.md` změnit na `spec/storage.md` |
| 2 | §5 „Verzování KI": definuje MAJOR/MINOR/PATCH a hned přiznává, že se číslo nikde neudržuje | Ponechat, ale doplnit, kdy se aktivuje (`ADR-018 / Ring 3`), ať čtenář neřeší, jestli něco nehledá špatně |

Jinak nejlépe napsaný dokument v repu — §3.7 a §6.1–6.3 jsou příkladné: normativní, s explicitně přiznanou technickou dluhem i vlastníkem.

### `spec/graphics.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | §4 odkazuje „viz `graphics.md` §7 a handoff H4" u dvojitého bufferingu, ale §7 je „Budoucí cesta (bez změny API)" a o `present` nemluví | Opravit na `viz §2 (op 5 `present`) a handoff H4` |
| 2 | Odkaz na „handoff H4" je jen textový, ne odkaz | `[handoff H4](handoffs/04-double-buffering-heap-corruption.md)` |

Tabulka operací §2 (12 sub-op) **přesně odpovídá** `GraphicsOp` v kódu včetně rezervovaného `blit` — vzorové řešení, takhle by měly vypadat i ostatní.

### `spec/timer.md` a `spec/input.md`

Tabulky sub-op **odpovídají kódu** (`TimerOp` 0–3, `InputOp` 0–10) včetně `mouse_wheel = 10`. Bez nálezu. Ironicky právě `input.md` `mouse_wheel` dokumentuje, zatímco `runtime.md` §4 ho ve své tabulce vynechává (**K4**).

### `spec/verification.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | §1 pipeline má kroky 0–4b; **chybí** `zig build shell-test`, `verify-reproducible.sh`, `capture-boot.sh --check`, `sync-docs.sh --check` — všechny čtyři jsou v `CONTRIBUTING.md` i v CI | Doplnit jako Krok 3b, 5, 6, 7 |
| 2 | §2 DoD checklist ze stejného důvodu neúplný | Doplnit čtyři odrážky |
| 3 | §5 tabulka „Nástroje" uvádí 7 z 11 skriptů v `tools/` — chybí `capture-boot.sh`, `sync-docs.sh`, `make-test-disk.sh`, `lua-shell-test.sh`, `verify-reproducible.sh`, `generate-changelog.sh`, `install-hooks.sh` | Doplnit; README na tuto tabulku odkazuje jako na „full tool table" |
| 4 | §6 nadpis „stav k datu konsolidace specifikace" — bez data | Doplnit konkrétní datum |
| 5 | §6 neuvádí wasm3, `parted`, `e2fsprogs`, hostitelský `lua5.4` (**K5**) | Tři řádky z K5 |
| 6 | §3a „Ověřeno (2026-08-16)": `zig build test` → **160/160**; v `tests/` je dnes **164** test bloků | Přeměřit a aktualizovat, nebo nahradit „✅ vše zelené" bez počtu (počty stárnou při každém commitu) |

Poznámka: `shell-test 34/34` **sedí** — `tests/lua/run.lua` obsahuje 35 volání `test(`, z toho 1 je definice funkce, tedy 34 případů.

### `spec/troubleshooting.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | B4 radí `QEMU_TEST_TIMEOUT ≥ ~600 s` na TCG, CI běží na TCG s `90` (**K7**) | Přeformulovat, text v K7 |
| 2 | Soubor je 50 KB / 271 řádků s ~62 záznamy ve třech řadách ID (C, B, H) bez obsahu na začátku | Přidat na začátek krátký index řad: `C = kód/toolchain, B = build/determinismus, H = handoffy` + odkaz na `handoff.md §6` |

### `spec/handoff.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | Chybí seznam handoffů slíbený v `architecture.md` §8 (**G6**) | Nová §6, text v G6 |

### `spec/non-goals.md`

Bez nálezu — nejlépe udržovaný dokument z hlediska aktuálnosti. Řádek SMP („⚠️ Částečně — bring-up hotový, scheduler BSP-only") a Perzistence („✅ Hotovo — od M7.1 read-write") jsou přesné. Doporučení: tenhle styl (stav + kdy by se to změnilo) přenést i do `README.md` §Status.

### `spec/lua-wm.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | Odkazuje na `src/kernel/lua/libc.zig`, který v M7 přesunut na `src/kernel/libc.zig` (**K9**) | `sed` oprava |
| 2 | 70 KB / 1254 řádků, největší dokument v repu, označený jako „(RFC)" — není jasné, které části už jsou implementované a které zůstávají návrhem | Doplnit na začátek stavovou hlavičku ve stylu ostatních spec (`**Status:** …, implementováno: …, návrh: …`) |

### `spec/roadmap.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | Odkazuje na `src/kernel/lua/libc.zig` (**K9**) | `sed` oprava |
| 2 | Metrika M7 661 KiB vs. 578 KiB v boot logu (**K3**) | Přeměřit |
| 3 | Stav M7 je vedený ve dvou blokcích s odlišnými daty (2026-08-17 „zbývá Fáze B a C", 2026-08-18 „Fáze B hotová") — čtenář musí dojít až k druhému, aby zjistil aktuální stav | Konsolidovat do jednoho aktuálního „Stav" bloku, starší přesunout do historie milníku |

### `spec/2026-08-15-self-audit.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | Odkaz na `docs/code-style.md` místo `spec/code-style.md` (**K9**) | Opravit, nebo ponechat jako historický záznam (viz P3-3) |
| 2 | Řádek 88 vyjmenovává 12 tehdejších nálezů zastaralé dokumentace — z nichž **tři typově stejné existují znovu** (README metriky, chybějící KI operace, stale test count) | Viz doporučení pod tabulkou akčního plánu |

### `docs/index.md`

| # | Problém | Oprava |
|---|---|---|
| 1 | „Last audited on **2026-08-16**" — ručně psané datum v dokumentu, který o odstavec výš odmítá ručně psaná data jako nespolehlivá (**G7**) | Odstranit, nebo nahradit odkazem na git historii souboru |
| 2 | Nazývá `docs/` „the project's complete English documentation", přestože je to jedna úvodní stránka (což sama o pár odstavců níž přiznává) | Přeformulovat první odstavec: `This site is the entry point to the project's English documentation layer, which is currently being built up page by page.` |

### `tools/test-disk-root/README`

| # | Problém | Oprava |
|---|---|---|
| 1 | „ext2 read-only" (**K8**) | `ext2 read-write, ^dir_index, 1024 B blocks` |
| 2 | Chybí `/apps/` a wasm aplikace (**K8**) | Nová sekce, text v K8 |

### `.github/workflows/ci.yml`

| # | Problém | Oprava |
|---|---|---|
| 1 | Není zmíněný v `spec/architecture.md` §7 ani nikde ve spec jako součást verifikačního řetězce, přestože je jeho nejsilnějším vynucením | Doplnit do `spec/verification.md` §1 odstavec „Co z pipeline vynucuje CI" |

---

## 5. AKČNÍ PLÁN OPRAV (Action Plan)

### P1 — Kritické (opravit před dalším commitem)

| # | Úkol | Soubory | Odkaz | Odhad |
|---|---|---|---|---|
| P1-1 | Doplnit `-b 1024` do „Přesné invokace" + `Status update` blockquote | `spec/adr/023-…md` | K1 | 10 min |
| P1-2 | Narovnat stav M7 Fáze B ve všech čtyřech dokumentech + doplnit chybějící CHANGELOG záznam | `README.md`, `CHANGELOG.md`, `THIRD-PARTY-NOTICES.md` | K2, G3 | 45 min |
| P1-3 | Přeměřit metriky (`tools/bench.sh`) a sjednotit s `boot-log.md` | `README.md`, `spec/roadmap.md` | K3 | 30 min |
| P1-4 | Doplnit tabulku Lua bindingů a sub-op čísla Runtime `3/4/5` | `spec/runtime.md` | K4 | 20 min |
| P1-5 | Doplnit prerekvizity (`parted`, `e2fsprogs`, `lua5.4`, wasm3) do všech tří setup míst | `README.md`, `CONTRIBUTING.md`, `spec/verification.md` §6 | K5, G2 | 25 min |
| P1-6 | Doplnit `spec/verification.md` §1 a §2 o `shell-test`, `verify-reproducible`, `capture-boot --check`, `sync-docs --check` — kanonický dokument musí být aspoň tak úplný jako `CONTRIBUTING.md` | `spec/verification.md` | §Detail | 30 min |
| P1-7 | Napsat `spec/storage.md` a přepojit na něj `kernel-interface.md` §2 | nový + `spec/kernel-interface.md`, `spec/README.md`, `spec/architecture.md` §7–8 | G1 | 3–4 h |
| P1-8 | Opravit `tools/test-disk-root/README`: read-write + sekce `/apps/` | `tools/test-disk-root/README` | K8 | 15 min |

**Součet P1 (bez P1-7): ~3 hodiny.** P1-7 je samostatný půldenní úkol.

### P2 — Důležité (do uzavření M7)

| # | Úkol | Soubory | Odkaz |
|---|---|---|---|
| P2-1 | Sjednotit `**Status:**` u ADR-008 a ADR-010 na `Superseded by …` | `spec/adr/008-…md`, `010-…md` | K6 |
| P2-2 | **Zrušit duplicitní ADR tabulku** — ponechat `spec/adr/README.md` jako kanonickou, v `architecture.md` §4 nechat jen odkaz + odstavec o pravidlech | `spec/architecture.md`, `spec/adr/README.md` | §Detail |
| P2-3 | **Zrušit duplicitní index specifikací** — ponechat `spec/README.md`, `architecture.md` §8 nahradit odkazem | `spec/architecture.md`, `spec/README.md` | §Detail |
| P2-4 | Doplnit seznam handoffů (`handoff.md` §6) a odkázat z obou indexů | `spec/handoff.md`, `spec/README.md`, `spec/architecture.md` §7 | G6 |
| P2-5 | Aktualizovat `architecture.md` §7: `calculator`, `C1..C54/B1..B4/H1..H6`, chybějící kořenové soubory a adresáře | `spec/architecture.md` | §Detail |
| P2-6 | Sjednotit B4 timeout s realitou CI | `spec/troubleshooting.md` | K7 |
| P2-7 | Opravit 3 neexistující cesty (`libc.zig` ×2, `docs/code-style.md`) | `spec/lua-wm.md`, `spec/roadmap.md`, self-audit | K9 |
| P2-8 | Aktualizovat počet host testů v `verification.md` §3a (160 → 164) nebo počty vypustit | `spec/verification.md` | §Detail |
| P2-9 | Napsat specifikaci wasm runtime (nebo sekci v `runtime.md`) | nový / `spec/runtime.md` | G4 |
| P2-10 | Napsat specifikaci scheduleru + SMP | nový | G5 |
| P2-11 | Změnit `sync-docs.sh` glob `docs/*.md` → rekurzivní `find` | `tools/sync-docs.sh` | G7 |
| P2-12 | Konsolidovat stavové bloky M7 v roadmapě do jednoho aktuálního | `spec/roadmap.md` | §Detail |

### P3 — Kosmetické

| # | Úkol | Soubory | Odkaz |
|---|---|---|---|
| P3-1 | Sjednotit `Přijato` → `Accepted` napříč indexy | `spec/adr/README.md` | §Detail |
| P3-2 | Odstranit zdvojený `---` před `## 8. Zig`; doplnit verzi wasm3 v0.5.0 | `THIRD-PARTY-NOTICES.md` | §Detail |
| P3-3 | **Nechat audity `2026-08-*` jako neměnné historické záznamy** a doplnit jim do hlavičky větu „Historický záznam — neupravovat; nálezy se řeší v aktuálních dokumentech." Dnes není jasné, jestli jsou to živé dokumenty (a proto se v nich opravují odkazy), nebo záznamy k datu. | `spec/2026-08-15-self-audit.md`, `spec/2026-08-16-re-audit.md` | §Detail |
| P3-4 | Opravit křížový odkaz `graphics.md` §4 → §7 a udělat z „handoff H4" odkaz | `spec/graphics.md` | §Detail |
| P3-5 | Doplnit stavovou hlavičku do `lua-wm.md` (co je implementováno vs. RFC) | `spec/lua-wm.md` | §Detail |
| P3-6 | Přidat index řad ID (C/B/H) na začátek `troubleshooting.md` | `spec/troubleshooting.md` | §Detail |
| P3-7 | Odstranit ruční „Last audited on" z `docs/index.md`; zmírnit „complete English documentation" | `docs/index.md` | G7 |
| P3-8 | Doplnit datum k nadpisu `verification.md` §6 | `spec/verification.md` | §Detail |
| P3-9 | Vytvořit „první den" onboarding stránku | nový `spec/onboarding.md` nebo sekce v `CONTRIBUTING.md` | G8 |

---

## Systémové doporučení nad rámec jednotlivých oprav

Projekt už dělá pravidelné audity (`spec/2026-08-15-self-audit.md`, `2026-08-16-re-audit.md`) a to je správně. Ale řádek 88 self-auditu z 15. 8. vyjmenovává mimo jiné: *„`spec/kernel-interface.md` chybí Storage; `spec/graphics.md` chybí width/height; `spec/runtime.md` chybí file.*; `README` metrika končí M6; `verification.md` test count stale"*.

O čtyři dny později tento audit nachází **typově identické nálezy**: `runtime.md` chybí `mouse_wheel`/`ms`/`of_day_ms`/`surface_render`/`key_input`, README metrika je pozadu, `verification.md` test count je zase stale.

Ruční audit tuhle třídu chyb najde, ale nezabrání jejímu návratu — protože příčina není nedbalost, ale to, že **shoda dokumentace s kódem není v tomto projektu vynucená ničím**, zatímco shoda boot logu (`capture-boot.sh --check`) a překladové vrstvy (`sync-docs.sh --check`) vynucená je. Projekt má na to už i vzor.

Konkrétně navrhuji přidat `tools/check-ki-docs.sh` do CI pipeline hned za `sync-docs.sh --check`:

- vytáhne `GraphicsOp`, `InputOp`, `TimerOp`, `RuntimeOp`, `StorageOp`, `Syscall`, `KiStatus` z `src/kernel/api/*.zig` a názvy z `luaL_Reg` polí v `src/kernel/lua/bindings.zig`,
- ověří, že se každý identifikátor vyskytuje v `spec/kernel-interface.md`, příslušném `spec/<modul>.md` a v tabulce `spec/runtime.md` §4,
- selže s výpisem chybějících.

Je to ~60 řádků bashe s `grep`, žádná nová závislost, a udělá z pravidla `kernel-interface.md` §4/6 („Dokumentace KI je ABI-pravda") skutečně vymahatelný invariant místo dobrého úmyslu. Vzhledem k tomu, že celý ADR-018 (přechod na Ring 3) stojí na předpokladu, že dnešní dokumentace KI je přesná, je to ta nejlevnější pojistka v celém repu — přesně v duchu, v jakém je psaný `kernel-interface.md` §1.

---

*Konec auditu. 9 kritických nálezů, 8 mezer v pokrytí, 29 úkolů v akčním plánu.*
