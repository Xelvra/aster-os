-- api.lua - reference for the Lua API the WM shell exposes to configuration
-- and plugins. This file is documentation (not executed); the real bindings
-- live in the kernel (src/kernel/lua/bindings.zig). Everything here is a
-- normal Lua global or table — call it from /wm/theme.lua or any shell code.

-- Graphics (gfx.*): draw to the framebuffer. Coordinates are pixels, colors
-- are 0xRRGGBB integers.
--   gfx.width()  -> screen width (px)
--   gfx.height() -> screen height (px)
--   gfx.fill_screen(color)
--   gfx.draw_rect(x, y, w, h, color)
--   gfx.round_rect(x, y, w, h, radius, color)
--   gfx.rect_border(x, y, w, h, thickness, color)
--   gfx.gradient_border(x, y, w, h, thickness, color_a, color_b)
--   gfx.draw_text(text, x, y, color)
--   gfx.invalidate()            -- request a repaint of the current frame

-- Input (input.*): keyboard/mouse state and events.
--   input.next_event() -> { type = "key"|"mouse", pressed, code, char, ... }
--   input.mouse_x() / input.mouse_y() -> cursor position
--   input.mouse_left() / input.mouse_right() / input.mouse_middle() -> bool
--   input.set_layout(name)  input.layout_name() -> keyboard layout

-- Time (time.*):
--   time.ticks() -> monotonic tick counter (100 ticks = 1 s)

-- File (file.*): access the mounted disk (ext2). Returns nil on failure.
--   file.open(path)  -> handle or nil
--   file.read(h, n)  -> string (up to n bytes) or "" at EOF
--   file.write(h, s) file.truncate(h, len) file.close(h)
--   file.create(path) -> handle (new file)
--   file.remove(path) -> bool
--   file.dir(path)   -> array of { name = "...", dir = bool }

-- System monitor (sysmon.*):
--   sysmon.ram_total_mb() / sysmon.ram_free_mb()

-- Runtime (runtime.*):
--   runtime.reload()  -- request a shell hot reload (performed by the event loop)

-- Debug (debug.*):
--   debug.write(str)  -- print to the privileged serial diagnostic sink

-- Shell helpers (defined by the shell modules themselves):
--   print(...)            -- write to the REPL scrollback (overrides stock print)
--   wm_error(source, msg) -- unified error channel: "<source>: <message>"
--   on_shell_error(msg)   -- kernel hook: frame-loop errors before hot reload
--   theme                 -- global config table (colors/geometry), see theme.lua
--   _COPYRIGHT            -- the bundled Lua's copyright line (LUA_COPYRIGHT)
--   _VERSION              -- stock Lua version string ("Lua 5.4")
