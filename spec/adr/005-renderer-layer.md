# ADR-005 — Renderer jako samostatná vrstva

**Status:** Accepted
**Datum:** 2026-08-06

## Rozhodnutí
Mezi Graphics API a Framebufferem je vrstva **Renderer**:
`Lua → Graphics API → Renderer → Framebuffer`.

## Odůvodnění
Zabrání tomu, aby se framebuffer stal nechtěným API celého systému. Renderer dnes =
`fillRect()`; zítra = GPU backend; později = IPC compositor. Lua o tom nikdy nebude vědět.

## Důsledky
- `api/graphics.zig` volá `renderer.zig`, který píše do `framebuffer.zig`.
- Renderer nesmí znát Lua VM (invariant Architecture).

## Související
- ADR-003, ADR-009 (minimální primitiva)
- `spec/graphics.md`, `spec/invariants.md`
