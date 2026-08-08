# ADR Index

Záznam architektonických rozhodnutí (Architecture Decision Records). Každé rozhodnutí je
samostatný soubor. Pravidla:

- **Rozhodnutí se nemění dodatečně.** Změna názoru = nový ADR odkazující na starý.
- Čísla se nepřehazují a nemazají; nový ADR dostane další volné číslo.
- ADR nemusí být dlouhý. 5 vět s jasným verdiktem > 2 stránky váhání.

## Současný stav

| ADR | Rozhodnutí | Stav |
|-----|------------|------|
| [001](001-evolutionary-sasos.md) | Evoluční architektura (SASOS → mikrojádro později) | Přijato |
| [002](002-single-address-space-ring0.md) | Single Address Space, Ring 0 | Přijato |
| [003](003-stable-interfaces-day-one.md) | Stabilní rozhraní od prvního dne | Přijato |
| [004](004-kernel-interface-not-abi.md) | Kernel Interface (KI), ne ABI | Přijato |
| [005](005-renderer-layer.md) | Renderer jako samostatná vrstva | Přijato |
| [006](006-generic-runtime-api.md) | Generické Runtime API | Přijato |
| [007](007-lua-5-4-vendored.md) | Lua 5.4 vendored, staticky, ne LuaJIT | Přijato |
| [008](008-event-loop-not-mlfq.md) | Scheduler: událostní smyčka, ne MLFQ | Přijato |
| [009](009-minimal-rendering-primitives.md) | Minimální renderovací primitiva | Přijato |
| [010](010-no-filesystem-yet.md) | Žádný souborový systém, dokud nebude potřeba | Přijato |
| [011](011-wasm3-later.md) | wasm3 později, šev Runtime → Program | Přijato |
| [012](012-limine-bootloader.md) | Limine bootloader | Přijato |
| [013](013-zig-version-pinning.md) | Pinning Zigu mimo název projektu (.zig-version) | Přijato |
| [014](014-deterministic-build.md) | Deterministický build | Přijato |
| [015](015-measure-every-milestone.md) | Měření po každém milníku | Přijato |
| [016](016-bootable-commit.md) | Bootovatelný commit | Přijato |
| [017](017-concurrency-model-m7.md) | Concurrency model M7 (preemptivní RR, kritické sekce bez locků) | Přijato |
| [018](018-ring3-ki-transport.md) | Transport KI v Ring 3: mailbox IPC, comptime dispatch, IRQ routing | Přijato |
| [019](019-bootloader-gate.md) | Bootloader gate: kernel nezávisí na typech bootloaderu (BootInfo) | Přijato |
| [020](020-future-extensibility.md) | Rozšiřitelnost: nové features jako nové KI moduly na konec | Přijato |
| [021](021-extended-rendering-primitives.md) | Rozšířená renderovací primitiva pro UI (roundRect, border, gradient) | Přijato |
| [022](022-network.md) | Síť jako KI modul `net.*` — minimální stack (virtio-net, ARP/IPv4/ICMP/UDP), M9 | Přijato |
| [023](023-filesystem-ext2-non-posix.md) | Persistence: ext2 backend (read-only), non-POSIX sémantika, tenké rozhraní | Přijato |

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
