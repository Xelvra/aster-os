---
layout: page
title: Milestones
---

# Milestones

Aster's roadmap is a sequence of milestones, each with a clear goal and
definition of done. Every milestone is measured (kernel size, RAM, boot time)
before the next one starts; the exact per-milestone targets live in
[`spec/roadmap.md`](https://github.com/Xelvra/aster-os/blob/main/spec/roadmap.md).

| Milestone | Goal |
|-----------|------|
| M0 ✅ | Boot: deterministic build, boots in QEMU, serial marker |
| M1 ✅ | Memory: page frame allocator + heap allocator |
| M2 ✅ | CPU: IDT, APIC timer, IOAPIC, PS/2 keyboard |
| M3 ✅ | Graphics: framebuffer, renderer, text on screen |
| M4 ✅ | Lua: interactive REPL in kernel, hot reload |
| M5 ✅ | UI: desktop shell in Lua — tiling WM, bar, launcher, workspace, mouse, error containment |
| M6 🔄 | Storage: initfs, virtio-blk, GPT, filesystem, cooperative reads |
| M7 ⏳ | Runtime: wasm apps, multitasking, app isolation |
| M8 ⏳ | Stabilization: invariant audit, metrics, Ring 3 decision |
| M9 ⏳ | Ecosystem: network, audio, browser, WASI |
| M10 ⏳ | Adoption: real hardware, installable image, docs, contributors |

## M6 (Storage) in detail

The current milestone: loading files at runtime. Persistence foundation
(sub-milestone M6.1, per ADR-023):

| Item | Status |
|------|--------|
| M6.1.1 Block device API + virtio-blk (sector reads) | ✅ done |
| M6.1.2 GPT partition discovery | planned next |
| M6.1.3 ext2 mount (read-only, validated feature flags) | planned |
| M6.1.4 Thin Aster file API (`open` / `read` / `close`) | planned |
| M6.1.5 Integration (initfs + persistent FS, QEMU runtime tests) | planned |

Design constraints:

- **Never a custom disk format.** GPT for partitioning, ext2 (read-only) as the
  first filesystem backend (ADR-023). FAT32/ext4/EROFS/9P are future backends.
- ext2 is only an on-disk representation — the file API carries **no POSIX
  semantics** (no inode numbers, uid/gid, mode bits, ACLs).
- Slow filesystem operations must not block the event loop — cooperative
  suspendation is planned.

## Working rules

- **Every commit = a bootable system** (ADR-016). A broken boot is fixed
  immediately, never "in a few commits".
- **Metrics are measured and recorded** at the end of each milestone.
- **No new feature without a green pipeline** (see [Development](development.html)).
- **No premature optimization on paper** — improvements come from real
  implementation experience.

---

Source: [`spec/roadmap.md`](https://github.com/Xelvra/aster-os/blob/main/spec/roadmap.md)
(Czech original).
Synced: 2026-08-08.
