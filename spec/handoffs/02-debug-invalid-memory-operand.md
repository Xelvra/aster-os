# Handoff H2: Debug build — `invalid memory operand` u `lidtq`/`invlpg` (Zig 0.16)

**Datum:** 2026-08-08
**Status:** closed (workaround v kódu; příčina = nekonzistence Zig 0.16 mezi módy)

---

## 1. Symptom

`zig build -Doptimize=Debug` selhává při kompilaci kernelu:

> Reprodukce: `zig build -Doptimize=Debug`
> Očekávaný výstup: build projde, kernel bootuje.
> Skutečný výstup:
> ```
> src/kernel/mem/page_map.zig:46:1: error: invalid memory operand: '(%[addr])'
> src/kernel/cpu/idt.zig:44:1: error: invalid memory operand: '(%[idt])'
> ```

ReleaseSafe build (`zig build`) prochází a bootuje. Debug build **nevytvoří binárku**.

## 2. Prostředí

| Vrstva | Hodnota |
|---|---|
| Build | `zig build -Doptimize=Debug`, target `x86_64-freestanding` |
| Toolchain | Zig 0.16.0 (`.zig-version`), Linux |
| Runtime | QEMU q35 (boot Debug neproběhne — kompilace selže) |
| Vlastní kód | `src/kernel/cpu/idt.zig` (`load`), `src/kernel/mem/page_map.zig` (`flushTlb`) |

## 3. Co bylo vyzkoušeno

| # | Pokus | Výsledek | Závěr |
|---|-------|----------|-------|
| 1 | `zig build -Doptimize=Debug` | kompilace selže (2 chyby) | reprodukováno |
| 2 | `zig build` (ReleaseSafe) | build + boot OK | produkce není postižena |
| 3 | izolovaný host exe: `asm ("invlpg (%[addr])", : : [addr] "r" (...))` v `-ODebug` | `invalid memory operand` | potvrzeno — není kernel-specifické |
| 4 | tentýž zdroj v `-OReleaseSafe` | kompiluje, `invlpg (%rax)` | potvrzeno — nekonzistence módu |
| 5 | constraint `"m"` + `invlpg %[addr]` | kompiluje v obou módech | zamítnuto — **sémanticky špatně**: invaliduje stránku, kde je uložená proměnná, ne stránku na adrese `virtual` |
| 6 | scratch registr: `"mov %[addr], %%rax\ninvlpg (%%rax)"` + clobbers `.{ .rax = true, .memory = true }` | kompiluje v obou módech, generuje `invlpg (%rax)` | **řešení** |

## 4. Hypotézy

1. **Hypotéza A (potvrzena):** Zig 0.16 má nekonzistenci mezi `-ODebug` a `-OReleaseSafe`
   pro inline asm `("r")` operand + memory deref `(...)`. Debug striktně vyžaduje
   memory-operand constraint, ReleaseSafe toleruje `"r"` + `(%reg)`.
   - Potvrzení: izolovaný host exe reprodukuje přesně (bod 3/4).
   - Vyvrácení: — (nepodařilo se; oba módy se chovají konzistentně napříč testy).

## 5. Reprodukce

1. Z `zig build -Doptimize=Debug` → chyba `invalid memory operand: '(%[addr])'`.
2. Minimální případ (host): `asm volatile ("invlpg (%[addr])", : : [addr] "r" (x), : .{ .memory = true })`
   v `-ODebug` → stejná chyba; v `-OReleaseSafe` → projde.

## 6. Důležité artefakty

- Záznam C27 v `spec/troubleshooting.md` (symptom → příčina → řešení → ověření).
- Fix v `src/kernel/cpu/idt.zig` a `src/kernel/mem/page_map.zig` (scratch registr).

## 7. Omezení a podezřelé okolnosti

- Není to chyba našeho kódu — `"r"` + `(%reg)` je standardní a **správný** zápis pro
  `invlpg`/`lidt` (memory operand z hodnoty v registru). Workaround je čistý, ale měl by
  se **vrátit k přímému zápisu, až Zig 0.16 fix přijde** (upgrade Zigu / release note).
- Constraint `"m"` je lákavý (kompiluje), ale sémanticky nesprávný — nesmí se použít.

## 8. Ideální výsledek

- `zig build -Doptimize=Debug` kompiluje a bootuje (dosaženo workaroundem).
- **Closed podmínka:** po upgradu Zig (nebo 0.16 patch) ověřit, že přímý zápis
  `lidtq (%[reg])` / `invlpg (%[addr])` už Debug přijímá, a workaround odstranit.
  Do té doby zůstává workaround s vysvětlujícím komentářem v kódu.
