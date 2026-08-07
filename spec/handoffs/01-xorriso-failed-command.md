# Handoff H1: falešné `failed command: xorriso` + cache neinvaliduje výstup

**Datum:** 2026-08-07
**Status:** open

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

1. **Hypotéza A (potvrzeno pro S2): Zig 0.16 cache hashuje jen vstupy, ne výstupy.**
   Step s `addOutputFileArg` se znovu nespustí, když jeho výstup zmizí nebo se
   modifikuje. Doklad: minimální reprodukce (§3/7, §3/8).
   - Potvrzení: minimální reprodukce bez xorriso/Limine/ISO/QEMU.
   - Vyvrácení: nebylo vyvráceno; chování je konzistentní.
   - Dopad na Aster: `limine bios-install` modifikuje ISO in-place → XORRISO output se
     mění → konflikt se Zig cache.
2. **Hypotéza B (nevysvětleno): S1 — proč Zig vytiskne `failed command` pro příkaz
   s exit status 0.**
   - Pozorování: S1 se objeví jen když xorriso reálně běží (poprvé po čisté cache), nikdy
     při cached re-runu.
   - Zatím nevysvětleno; minimální reprodukce S1 se nepodařila (§3/8 ukazuje, že in-place
     modifikace sama o sobě to nezpůsobuje).

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
  re-runu.
- `bios-install success 1ms` je podezřele rychlé — možná bios_install nedělá práci, jen
  čte hotový ISO.
- Build je funkční (exit 0, boot), problém S1 je primárně kosmetický — ale matoucí a může
  maskovat budoucí skutečné selhání. S2 je objektivní chyba cache invalidace.
- **Formulace S1:** Zig tiskne `failed command` pro příkaz, jehož pozorovaný exit status
  procesu je 0, přičemž příslušný build step je nakonec považován za úspěšný.

## 8. Ideální výsledek

- S2: zmizelý/modifikovaný výstup `addOutputFileArg` stepu → step se znovu spustí
  (nebo je zdokumentováno, že Zig výstupy nesleduje a je potřeba jiný pattern).
- S1: první build po čisté cache bez `failed command: xorriso` na stderr, nebo je
  identifikováno a zdokumentováno, že jde o známý neškodný bug Zig 0.16 s workaroundem.
