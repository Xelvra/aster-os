# Aster OS — ARCHIVED

> **This repository is archived and read-only. It is not maintained, and it no longer builds.**
>
> The work continues in **[aster-wm](https://github.com/Xelvra/aster-wm)** — the desktop
> environment this project turned out to be about.

Aster OS was an experimental desktop operating system written in Zig, targeting x86_64 under
QEMU `q35`. Limine booted a Ring 0 kernel with its own page frame allocator and heap, an IDT
with APIC and I/O APIC timers, a PS/2 keyboard driver with switchable US/CZ layouts, a
software renderer drawing straight into the framebuffer, a virtio-blk driver over GPT with a
read-write ext2 filesystem, and an embedded Lua 5.4 interpreter. On top of that ran a
desktop shell written entirely in Lua: a tiling window manager, a bar, a launcher, an editor,
a file browser and a REPL. It reached M7 — boot, memory, CPU, graphics, Lua runtime, desktop
shell, storage, and a WebAssembly runtime — across 344 commits.

The kernel turned out to be scaffolding. The Lua desktop running on top of it turned out to
be the interesting part, and it was being held back by the platform work underneath it:
every feature it wanted meant first writing more operating system. So the desktop was
extracted and the OS layer was retired. In aster-wm the same idea sits on a twelve-function
host contract instead of a kernel, which means it runs under SDL, on DRM/KMS, in a browser
via WebAssembly — and eventually on this kernel again, as one backend out of four rather
than as the foundation.

What is kept here is the record of what was built, and the source that the bare-metal backend
will later be taken from. When the repository was archived, the vendored dependencies
(Limine, Lua 5.4, wasm3), the internal specification and the build and test tooling were
removed. The kernel source under `src/` is intact, but it will not compile as it stands.

## What it looked like

![Lua desktop shell running on bare metal](.github/images/screenshot.png)

## Milestones reached

| M | Milestone | Kernel | First frame |
|---|-----------|-------:|------------:|
| M0 | Boot | 12 KiB | ≈ 0.3 s |
| M1 | Memory | 17 KiB | ≈ 0.4 s |
| M2 | CPU | 29 KiB | ≈ 0.5 s |
| M3 | Graphics | 34 KiB | ≈ 0.6 s |
| M4 | Lua | 336 KiB | ≈ 60 ms |
| M5 | UI | 371 KiB | ≈ 24 ms |
| M6 | Storage | 362 KiB | ≈ 26 ms |
| M7 | Runtime | 578 KiB | ≈ 25 ms |

Kernel-only times measured under KVM; the M0–M3 rows are approximations with the bootloader
subtracted. M7 was measured after an audit pass and the WebAssembly runtime had been added,
not after an optimization pass, so it is not directly comparable with the M0–M6 rows.

## License

MIT — see [LICENSE](LICENSE). The vendored dependencies and their notices are in the
`v0.8.0-final` tag.
