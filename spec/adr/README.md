# ADR Index

Záznam architektonických rozhodnutí (Architecture Decision Records). Každé rozhodnutí je
samostatný soubor. Pravidla:

- **Rozhodnutí se nemění dodatečně.** Změna názoru = nový ADR odkazující na starý.
- Čísla se nepřehazují a nemazají; nový ADR dostane další volné číslo.
- ADR nemusí být dlouhý. 5 vět s jasným verdiktem > 2 stránky váhání.

## Současný stav

| ADR | Rozhodnutí | Stav |
|-----|------------|------|
| [001](001-evolutionary-sasos.md) | Evoluční architektura (SASOS → mikrojádro později) | Accepted |
| [002](002-single-address-space-ring0.md) | Single Address Space, Ring 0 | Accepted |
| [003](003-stable-interfaces-day-one.md) | Stabilní rozhraní od prvního dne | Accepted |
| [004](004-kernel-interface-not-abi.md) | Kernel Interface (KI), ne ABI | Accepted |
| [005](005-renderer-layer.md) | Renderer jako samostatná vrstva | Accepted |
| [006](006-generic-runtime-api.md) | Generické Runtime API | Accepted — implementováno (Wasm v M7) |
| [007](007-lua-5-4-vendored.md) | Lua 5.4 vendored, staticky, ne LuaJIT | Accepted |
| [008](008-event-loop-not-mlfq.md) | Scheduler: událostní smyčka, ne MLFQ | Superseded ADR-017 (pro M7) |
| [009](009-minimal-rendering-primitives.md) | Minimální renderovací primitiva | Accepted |
| [010](010-no-filesystem-yet.md) | Žádný souborový systém, dokud nebude potřeba | Superseded ADR-023 |
| [011](011-wasm3-later.md) | wasm3 později, šev Runtime → Program | Accepted — implementováno (M7) |
| [012](012-limine-bootloader.md) | Limine bootloader | Accepted |
| [013](013-zig-version-pinning.md) | Pinning Zigu mimo název projektu (.zig-version) | Accepted |
| [014](014-deterministic-build.md) | Deterministický build | Accepted |
| [015](015-measure-every-milestone.md) | Měření po každém milníku | Accepted |
| [016](016-bootable-commit.md) | Bootovatelný commit | Accepted |
| [017](017-concurrency-model-m7.md) | Concurrency model M7 (preemptivní RR, kritické sekce bez locků) | Accepted |
| [018](018-ring3-ki-transport.md) | Transport KI v Ring 3: mailbox IPC, comptime dispatch, IRQ routing | Accepted |
| [019](019-bootloader-gate.md) | Bootloader gate: kernel nezávisí na typech bootloaderu (BootInfo) | Accepted |
| [020](020-future-extensibility.md) | Rozšiřitelnost: nové features jako nové KI moduly na konec | Accepted |
| [021](021-extended-rendering-primitives.md) | Rozšířená renderovací primitiva pro UI (roundRect, border, gradient) | Accepted |
| [022](022-network.md) | Síť jako KI modul `net.*` — minimální stack (virtio-net, ARP/IPv4/ICMP/UDP), M9 | Accepted |
| [023](023-filesystem-ext2-non-posix.md) | Persistence: ext2 backend (read-write od M7.1, M6 read-only), non-POSIX sémantika, tenké rozhraní | Accepted |
| [024](024-keyboard-layout-registry.md) | Registr klávesových rozložení (per-session layout) | Accepted |
| [025](025-lua-shell-from-disk.md) | Lua shell z disku do `/wm/` s initrd fallbackem (Úroveň 2) | Accepted |
| [026](026-wasm-import-surface.md) | Wasm import surface a surface model (Fáze B) | Accepted |
| [027](027-wasm-apps-from-disk.md) | Wasm aplikace z disku, WM/aplikace decoupling, klávesnice | Accepted |

## Šablona nového ADR

```markdown
# ADR-0XX — <Název>

**Status:** <Proposed / Accepted / Superseded by ADR-0YY>
**Datum:** YYYY-MM-DD

## Rozhodnutí
<Co bylo rozhodnuto, jednou větou až dvěma.>

## Odůvodnění
<Proč. Kontext, alternativa, argument.>

## Důsledky
<Co z toho plyne pro kód, rozhraní, roadmapu.>

## Související
<Odkazy na spec dokumenty a jiné ADR.>
```
