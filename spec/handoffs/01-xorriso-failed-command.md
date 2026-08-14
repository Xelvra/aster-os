# Handoff H1: falešné `failed command: xorriso` + cache neinvaliduje výstup

**Datum:** 2026-08-07
**Status:** closed (S1 vysvětleno a vyřešeno; S2 = objektivní chování Zig, viz §4)

---

## 1. Symptom

Dva související symptomy:

**S1.** Při **prvním** `zig build run` / `zig build iso` po vyčištění `.zig-cache` se na
stderr objeví `failed command: xorriso ...`. Build přesto pokračuje (proběhne `limine
bios-install`), QEMU nabootuje a celý build končí **exit 0**. Při druhém běhu (xorriso
cached) se hláška neobjeví.

**S2.** Když se smaže/modifikuje výstupní soubor `addOutputFileArg` stepu (ISO), Zig step
**znovu nespustí** → `bios-install` selže: `limine: error: ...aster.iso: No such file or
directory`.

> Reprodukce S1: `rm -rf .zig-cache && zig build iso`
> Reprodukce S2: `zig build iso` (vytvoří ISO), pak `rm <cesta-ISO>`, pak `zig build iso`
> Očekávané chování: zmizelý výstup stepu → step se znovu spustí
> Skutečné chování: step zůstává cached, `bios-install` dostane `No such file`

## 2. Prostředí

| Vrstva | Hodnota |
|---|---|
| Build | `zig build iso` / `zig build run`, default `ReleaseSafe` |
| Toolchain | Zig 0.16.0, Arch Linux |
| Runtime | xorriso 1.5.8.pl02, QEMU (libvirt) |
| Vlastní kód | `build.zig` — xorriso step (`addSystemCommand`) + `bios_install` (`Step.Run.create`) |

## 3. Co bylo vyzkoušeno

| # | Pokus | Výsledek | Závěr |
|---|-------|----------|-------|
| 1 | xorriso manuálně (stejný příkaz, stejné cesty) | exit 0, ISO vzniká | xorriso sám o sobě není problém |
| 2 | `sh -c "...; echo XORRISO_EXIT=$?"` wrapper | `XORRISO_EXIT=0` | proces xorriso exit status je 0 |
| 3 | `xorriso.expectExitCode(0)` | build stále exit 0, hláška pořád | Zig krok reálně neselže |
| 4 | `-quiet` flag | hláška pořád | není o verbositě výstupu |
| 5 | kopie ISO (`cp` step), `bios_install` na kopii (žádná in-place modifikace xorriso outputu) | hláška pořád | není o in-place modifikaci outputu |
| 6 | `--summary all` | `iso success`, `bios-install success 1ms` | kroky uspějí; xorriso step v summary chybí jako samostatný uzel |
| 7 | **Minimální reprodukce S2 bez xorriso** (samostatný `build.zig`: `addSystemCommand` sh → `addOutputFileArg`, install step) | smazání output → `FileNotFound`, step se nespustí znovu | **potvrzeno: Zig 0.16 neinvaliduje output stepu, když soubor zmizí** |
| 8 | **Minimální reprodukce: in-place modifikace outputu** (krok A vytvoří, krok B modifikuje in-place, obojí přes `addFileArg`) | step B se spustí jednou, pak cached; **žádné** `failed command` | in-place modifikace sama o sobě nezpůsobuje S1 |
| 9 | `--verbose` | jen zobrazí argv, nic víc | — |

## 4. Hypotézy

1. **Hypotéza A (potvrzené chování): Zig 0.16.0 nepovažuje absenci výstupního souboru
   `addOutputFileArg` za důvod k opětovnému spuštění stepu.**
   Doklad: minimální reprodukce (§3/7, §3/8) — smazání i modifikace outputu nezpůsobí
   rerun. **Není to nutně bug** — cache může být navržená jako content-addressed podle
   deklarovaných vstupů a absence artefaktu je omezení implementace. Mechanismus (jak Zig
   identifikuje cached step) nebyl zkoumán; z experimentu plyne jen chování.
   → VYŘEŠENO §9: správný build graph = každý step vlastní svůj output, žádná in-place
   mutace cizího artefaktu.
2. **Hypotéza B — S1 VYŘEŠENA (příčina nalezena ve zdrojovém kódu Zig):**
   „failed command" je **design Zig**, ne bug. Mechanismu:
   - `std/Build/Step/Run.zig:2723-2730` (`evalGeneric`): stderr z `addSystemCommand`
     stepu se vždy považuje za **diagnostický výstup** (`result_stderr`), i když exit
     status je 0.
   - `spawnChildAndCollect` (`Run.zig:1539-1541`) nastavuje `result_failed_command`
     **vždy**, nezávisle na výsledku.
   - `compiler/build_runner.zig:1382-1391`: chybové/zprávové výpisy se tisknou
     **"No matter the result"** — tedy i pro úspěšné stepy; `printErrorMessages` vytiskne
     `failed command:` když je `error_style.verboseContext()`.
   - **xorriso píše na stderr** (banner, UPDATE zprávy) → step má `result_stderr` → Zig
     vytiskne "failed command: xorriso" při každém skutečném běhu, exit 0 a build pokračuje.
   - Potvrzeno minimální reprodukcí: `sh -c "echo X >&2; echo d > \"$1\""` +
     `addOutputFileArg` → "failed command", exit 0. Bez stderr zápisu → žádná hláška.
   - **Řešení pro Aster OS:** potlačit stderr xorriso (přesměrovat do /dev/null, nebo `-quiet`
     nestačí — banner jde na stderr i s `-quiet`). Viz §9.

## 5. Reprodukce

**S1:**
1. `cd <repo>`
2. `rm -rf .zig-cache`
3. `zig build iso 2>&1 | grep "failed command"` → hláška se objeví
4. `zig build iso 2>&1 | grep "failed command"` → nic (cached)

**S2 (minimální, mimo repo):**
1. samostatný adresář s `build.zig`: `addSystemCommand(&.{ "sh", "-c", "echo test > \"$1\"", "sh" })` + `addOutputFileArg("test.txt")` + install step
2. `rm -rf .zig-cache && zig build` → soubor vznikne
3. `rm <cesta k .zig-cache/.../test.txt>`
4. `zig build` → `FileNotFound`, soubor se znovu nevytvoří

## 6. Důležité artefakty

- Původní výstup uživatele včetně `failed command: xorriso` + úspěšný boot.
- `--summary all` výstup: `iso success`, `bios-install success 1ms`.
- Minimální reprodukce S2 v `/tmp/zigmin/` (build.zig + test).

## 7. Omezení a podezřelé okolnosti

- S1 se objeví jen když xorriso **reálně běží** (poprvé po čisté cache), nikdy při cached
  re-runu — to je konzistentní s vysvětlením (stderr se zpracuje jen při běhu stepu).
- `bios-install success 1ms` je podezřele rychlé — možná bios_install nedělá práci, jen
  čte hotový ISO. (Nezkoumáno dál; viz §9 build graph.)
- Build je funkční (exit 0, boot); S1 je matoucí, ale neškodný výpis. S2 je objektivní
  chování Zig cache.
- **Formulace S1:** Zig tiskne `failed command` pro příkaz, jehož pozorovaný exit status
  procesu je 0, přičemž příslušný build step je nakonec považován za úspěšný.

## 8. Ideální výsledek

- S2: zmizelý/modifikovaný výstup `addOutputFileArg` stepu → step se znovu spustí
  (nebo je zdokumentováno, že Zig výstupy nesleduje a je potřeba jiný pattern).
- S1: první build po čisté cache bez `failed command: xorriso` na stderr.

## 9. Řešení (k 2026-08-07)

**S1 (vyřešeno):** xorriso banner jde na stderr i s `-quiet`; Zig 0.16 tiskne
"failed command" pro každý `addSystemCommand` step s diagnostickým stderr, i při exit 0.
Řešení v `build.zig`: xorriso step běží přes `sh -c` wrapper, který **zachytává stderr do
dočasného souboru a přehraje ho jen při nenulovém exit code**. Tak se banner (úspěch)
potlačí, ale skutečná chyba (exit 5, např. chybějící zdroj) se stále vypíše. Ověřeno:
`rm -rf .zig-cache && zig build run` — žádná hláška, boot OK; umělá chyba xorriso → exit 5
+ chybová zpráva zachována.

**S2 (workaround):** správný build graph pro `bios-install`, který modifikuje ISO in-place:
```
xorriso ──► aster.iso (xorriso output)
  cp   ──► aster-copy.iso
bios-install ──► aster-copy.iso (modifikuje kopii, ne xorriso output)
```
Tak xorriso output zůstává nedotčený a každý step vlastní svůj output. (Vyzkoušeno — to
samotné S1 nezpůsobuje, ale je to správný pattern pro konzistentní cache.)
