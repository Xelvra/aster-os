# Troubleshooting — Známé pasti a lekce

**Status:** V1 (draft).
**Účel:** zachycovat chyby, které stály čas při vývoji, aby se nemusely znovu objevovat.
Dokument je **druhý mozek** — piš lekci ve chvíli, kdy je problém vyřešený, ne zpětně.

---

## Pravidla použití

- **Co sem patří:** ne-obvious chyba, která si vyžádala více než pár minut hledání, změnu
  toolchainu, nečekané chování build systému, past v protokolu. Opakování běžné chyby (syntaxe)
  sem nepatří.
- **Struktura záznamu:** `Symptom → Příčina → Řešení → Ověřit`.
- **Kdy:** ve chvíli vyřešení, ne na konci milníku. DoD (`spec/verification.md`) to vyžaduje.
- **Jazyk:** česky (dokumentace), kód/identifikátory anglicky.

---

## 1. Zig 0.16 build API

Build API se mezi 0.15 a 0.16 výrazně změnilo. **Nejlepší zdroj je instalovaná std lib
(`/usr/lib/zig/std/Build.zig`, `Build/Step/Run.zig`), ne webové docs** — docs byly
v kontextu zpožděné.

| Záznam | Symptom | Příčina | Řešení | Ověřit |
|--------|---------|---------|--------|--------|
| Z1 | `addExecutable` nezná `root_source_file` | 0.16: executable staví na `root_module` | `b.addExecutable(.{ .root_module = b.createModule(.{ .root_source_file = ... }) })` | `zig build` |
| Z2 | asm clobbers: `: "memory"` = syntax error | 0.16: clobbers jsou struct | `: .{ .memory = true }` | `zig build` |
| Z3 | `var x: volatile T` = syntax error | 0.16: `volatile` je pointer qualifier, ne type qualifier | `@as(*volatile T, @ptrCast(&x))` | build |
| Z4 | naked `_start`: `call symbol` = "undefined label" | inline asm nevidí Zig symboly | `@extern(*const fn...)` + `call *%[target]` | boot |
| Z5 | `export fn` s duplicitním `extern fn` = error | stejné jméno v jednom modulu | jiné jméno + `@export(&impl, .{ .name = "sym" })` | build |
| Z6 | `export var` vyžaduje `extern struct` | automatický layout nemá garantovanou reprezentaci | `pub const S = extern struct { ... }` | build |
| Z7 | `standardOptimizeOption` ignoruje `-Doptimize` | 0.16 používá `--release` flag, ne `-Doptimize` | vlastní `b.option(OptimizeMode, "optimize", ...)` s defaultem `.ReleaseSafe` | `zig build -Doptimize=Debug` |

---

## 2. Limine boot protokol

| Záznam | Symptom | Příčina | Řešení | Ověřit |
|--------|---------|---------|--------|--------|
| L1 | requests nefungují, kernel neví o framebufferu/hhdm | requesty jako `const` jsou DCE-odstraněné v ReleaseSafe (`comptime { _ = &x; }` nestačí) | `export var` + `extern struct` + `linksection(".limine_requests")` | `readelf -S` má `.limine_requests` |
| L2 | kernel nebootuje v ReleaseSafe s linker.ld, ale v Debug ano | linker script mění layout sekcí jinak per optimize | **linker.ld se nepoužívá** — Zig default layout dává `.limine_requests` jako samostatnou sekci | `zig build -Doptimize=ReleaseSafe` + smoke |
| L3 | #UD (invalid opcode) na `movdqu` hned po bootu | Limine **nezapíná SSE** (CR0.OSFXSR/CR4.OSXMMEXCPT), ale Zig generuje SSE instrukce | `error_tracing = false` v module + `enable_sse()` v `_start` | boot bez #UD |
| L4 | base revision check selhává | Limine zapisuje do request tagu; čtení bez `volatile` optimalizuje kompilátor | číst requesty přes `*volatile` pointer | boot, `base_revision[2] == 0` |
| L5 | requests v pořadí end→start marker | `linksection` do jedné sekce zachovává pořadí deklarací | start_marker, requesty, end_marker v **jednom** souboru ve správném pořadí | `readelf -x .data` |

---

## 3. Build a determinismus (ADR-014)

| Záznam | Symptom | Příčina | Řešení | Ověřit |
|--------|---------|---------|--------|--------|
| D1 | dvakrát build → jiný hash | `.debug_str` sekce obsahuje absolutní cestu do build cache (`/home/.../.zig-cache/...`), která se mění | `strip = optimize != .Debug` v module | `tools/verify-reproducible.sh` |
| D2 | `zig build iso` neprodukuje `zig-out/bin/aster` | iso step nezávisí na install stepu | spustit `zig build` (install) před/po iso; smoke skript buildí iso sám | `zig build && zig build iso` |
| D3 | smoke failuje, ale kernel běží | `find .zig-cache -name '*.iso' \| head -1` vybírá staré ISO z cache | `find ... -printf '%T@ %p\n' \| sort -rn \| head -1` | smoke dvakrát po sobě |

---

## 4. Tooling (QEMU, xorriso, Limine host tool)

| Záznam | Symptom | Příčina | Řešení | Ověřit |
|--------|---------|---------|--------|--------|
| T1 | xorriso step: "file_hash IsDir" | `addFileArg` na adresář | `addDirectoryArg(iso_dir)` | `zig build iso` |
| T2 | `limine bios-install` FileNotFound | hostitelský `limine` nástroj není v systému | zkompilovat z `libs/limine/tools/limine.c` (cc) v build.zig; argv[0] přes `addFileArg` | `zig build iso` |
| T3 | smoke/bench čekají celý timeout | kernel haltuje, QEMU běží dál | číst serial živě přes FIFO (`-chardev pipe`), ukončit po markeru | smoke za ~3s ne 30s |
| T4 | `bc: příkaz nenalezen` v bench | `bc` není nainstalovaný | `awk "BEGIN { printf ... }"` místo `bc` | `./tools/bench.sh` |

---

## 5. Jak předcházet (meta-lekce)

- **Měň jednu věc a ověřuj** — při M0 se střídaly strip/linker.ld/optimize současně, což
  zamlžilo příčiny. Jeden faktor na krok.
- **Po ne-obvious fixu zapiš záznam hned** — kontext vyprchá.
- **Ověřuj na stejném optimize, jako produkce** — Debug boot nepredikuje ReleaseSafe
  (L2, D1). Vždy nakonec `-Doptimize=ReleaseSafe` + smoke.
- **Nový toolchain (Zig major) = revize všech API předpokladů**, ne jen syntaxe.
