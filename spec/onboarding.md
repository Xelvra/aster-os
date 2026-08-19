# Onboarding — první den

**Status:** V1 (draft).
**Pro:** nového člena týmu — čti od shora dolů, jen první dva bloky jsou nutné
pro první boot; zbytek si dočti, až ho potřebuješ.

---

## 1. Co je Aster OS

Experimentální desktopový OS psaný v Zigu (x86_64). Kernel běží v Ring 0 s jediným
adresním prostorem; desktop (okenní manažer) je napsaný v Lua 5.4 vestavěné v kernelu.
Milníky M0–M7: boot, framebuffer, shell, WM, scheduler + SMP (BSP-only), storage (ext2),
wasm runtime. Přehled: `spec/architecture.md` §1–§3, `spec/roadmap.md`.

Jazyky: kód/komentáře/commity anglicky, `spec/*.md` česky (pravidlo `spec/code-style.md`
§0). Povolený autorský kód: Zig, Lua, Assembly — nic jiného bez svolení.

## 2. První boot (30 minut)

1. **Nástroje:** Zig z `.zig-version` (oficiální tarball, ne distro balík), QEMU
   (`qemu-system-x86_64`), xorriso, mtools, parted, e2fsprogs (`mke2fs`), hostitelský
   `lua5.4`. Kompletní tabulka: `spec/verification.md` §5–6.
2. **Hooks:** `./tools/install-hooks.sh` (pre-push ověřuje `boot-log.md` a `docs/`).
3. **Build:** `zig build` (default `ReleaseSafe`).
4. **Boot:** `zig build run` (auto KVM). Bez disku se souborový systém nepřipojí —
   na M7.1+:
   ```bash
   ./tools/make-test-disk.sh disk.img
   zig build run -Ddisk=disk.img
   ```
5. **Ověř, že prostředí funguje:** `zig build test`, `./tools/qemu-smoke.sh`
   (boot marker na serialu). V OS: launcher je **Super+Space**, per-window help **F1**,
   uživatelská příručka je na disku v `/README` (otevře se Super+E).

**Zasekl ses na bootu?** `spec/troubleshooting.md` (pasti C/B/H, index řad nahoře),
`spec/debugging.md` (GDB+QEMU, čtení serial dumpu). Není-li tam tvůj případ, otevři
handoff — postup v `spec/handoff.md`.

## 3. Ověř, že prostředí funguje (před první změnou)

Standardní verifikační sada (kanonická podoba: `spec/verification.md` §1):

```bash
zig fmt --check .
zig build
zig build test
zig build shell-test
./tools/qemu-smoke.sh
./tools/qemu-test.sh
./tools/verify-reproducible.sh
./tools/capture-boot.sh --check
./tools/sync-docs.sh --check
./tools/check-ki-docs.sh --check
```

Na první selhání se opraví a pokračuje se od začátku. Úkol je hotový jen, když vše
projde a report obsahuje skutečný výstup příkazů. DoD: `spec/verification.md` §2.

## 4. Čtení specifikace — v jakém pořadí

1. `spec/README.md` — index všech dokumentů a strategie dokumentace.
2. `spec/architecture.md` — přehled a terminologie, vrstvy a pravidla přístupu.
3. `spec/non-goals.md` — co se vědomě nedělá (šetří čas).
4. `spec/kernel-interface.md` — KI, jediný veřejný povrch, pravidla přístupu.
5. `spec/invariants.md` — Safety / Performance / Architecture, kód je hotový jen
   když je drží.
6. `spec/code-style.md` — styl a §6 kontrolní seznam pro review.
7. `spec/roadmap.md` — co se kdy dělá, metriky.
8. Subsystémové spec podle toho, čeho se týká tvoje změna: `memory.md`, `scheduler.md`,
   `storage.md`, `graphics.md`, `input.md`, `timer.md`, `runtime.md`, `desktop-ui.md`,
   `lua-wm.md`, `editor.md`.
9. Rozhodnutí (ADR) — čti až když chceš důvod konkrétního rozhodnutí: `spec/adr/`
   (každé rozhodnutí = jeden soubor, index v `adr/README.md`).

## 5. Kam sáhnout při první chybě

| Situace | Kam |
|---|---|
| Crash / hang / nečitelný serial | `spec/debugging.md` |
| Ne-obvious chyba, co stála čas | `spec/troubleshooting.md` (a zapiš novou lekci) |
| Nevyřešený problém | `spec/handoff.md` — formální postup H |
| Architektonická otázka | `spec/adr/` + `spec/architecture.md` |
| „Můžu tohle změnit?" | `spec/kernel-interface.md`, `spec/non-goals.md` |

## 6. Commit a push

- Commit jen se zelenou verifikací (ADR-016: každý commit musí zanechat systém
  bootovatelný). Message anglicky, subject + tělo.
- `CHANGELOG.md` je ručně kurátorovaný — nepřepisuj ho `generate-changelog.sh`
  (ten píše surovou historii do `CHANGELOG-commits.md`).
- Push blokuje pre-push hook, pokud `boot-log.md` nebo `docs/` zaostávají za kódem —
  regeneruj: `./tools/capture-boot.sh` (a `sync-docs.sh --check` ukáže, co je stale).
- Reprodukovatelný build (ADR-014) je závazný: `./tools/verify-reproducible.sh`.

## 7. Rychlý glosář

| Termín | Význam |
|---|---|
| **KI** | Kernel Interface — jediný veřejný povrch (`api/*`), viz `spec/kernel-interface.md` |
| **WM** | Window Manager — Lua shell v `src/kernel/lua/ui/` (`spec/lua-wm.md`) |
| **Chunk** | celý Lua shell je jeden konkatenovaný Lua kód v jednom `lua_State` |
| **ADR** | Architecture Decision Record — nemění se, změna názoru = nový soubor |
| **BSP / AP** | bootstrap processor / application processors (SMP; dnes BSP-only) |