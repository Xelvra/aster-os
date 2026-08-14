-- theme.lua - persistent Aster OS config (data, applied live).
-- This is the on-disk copy settings opens with Super+Z: it mirrors the
-- defaults from src/kernel/lua/ui/theme.lua so the whole config is editable
-- here. Edit, save with Ctrl+S and the system repaints live — no F5, no
-- kernel rebuild. A broken config is reported in the REPL and the last valid
-- look stays (the previous good version is kept in .theme.bak).
--
-- Colors are 0xRRGGBB integers:
--   theme.background  desktop background
--   theme.surface     window body
--   theme.surface_alt active title bar / bar
--   theme.text / theme.text_dim   normal / dim text
--   theme.accent      accent (active border, launcher, selected entry)
--   theme.accent_b / theme.accent_dark   gradient-border end colors
--   theme.inactive    inactive window border
--   theme.wm.*        gaps, border width, title height, window opacity
--   theme.bar.height  taskbar height
--   theme.ws          workspace names
--
-- Examples:
--   theme.accent = 0xFF5544          -- accent color
--   theme.wm.border = 4              -- thicker window borders
--   theme.wm.gap_out = 8             -- gap to the screen edge
--   theme.wm.opacity_inactive = 0.7
--
-- This chunk is loaded with load()+pcall against a copy of the running
-- theme table, so it may override the defaults below selectively.

theme = {
    background = 0x111826,
    surface    = 0x182545,
    surface_alt = 0x223454,
    text       = 0xDDDDDD,
    text_dim   = 0x798BB2,
    accent     = 0x82DCCC,
    accent_b   = 0x00AA84,
    accent_dark = 0x007D6F,
    inactive   = 0x798BB2,

    wm = {
        gap_out = 0,
        gap_in  = 0,
        border  = 2,
        title_h = 24,
        opacity_active = 0.95,
        opacity_inactive = 0.85,
    },

    bar = {
        height = 35,
        radius = 0,
    },

    ws = { "1", "2", "3" },
}
