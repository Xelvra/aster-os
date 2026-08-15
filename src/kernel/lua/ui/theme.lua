-- theme.lua - declarative colors and geometry (hot-reloadable).
-- Open with Super+Z (settings), edit, save with Ctrl+S — the whole system
-- repaints live, no F5 and no kernel rebuild. A config error is reported in
-- the REPL and the last valid look stays; the system never crashes.
--
-- This file is full Lua code, not a data format: you can compute values,
-- branch on conditions or call shell functions. The `theme` table is the WM's
-- single visual contract; everything the shell draws reads from it. To change
-- window behaviour (which windows exist, keybindings, launcher entries) the
-- WM exposes its Lua API — see the shell modules in this directory.
--
-- Colors are 0xRRGGBB integers:
--   theme.background     desktop background
--   theme.surface        window body
--   theme.surface_alt    active title bar / taskbar
--   theme.text           normal text
--   theme.text_dim       dim / secondary text
--   theme.accent         accent (active border, launcher, selected entry)
--   theme.accent_b       gradient-border start color
--   theme.accent_dark    gradient-border end color
--   theme.inactive       inactive window border
--   theme.red            error color (read-only files)
--
-- Geometry (pixels / ratios):
--   theme.wm.gap_out          gap from the tiling area to the screen edges
--   theme.wm.gap_in           gap between tiled windows
--   theme.wm.border           window border width
--   theme.wm.title_h          title-bar height
--   theme.wm.opacity_active   active window opacity (0..1)
--   theme.wm.opacity_inactive inactive window opacity (0..1)
--   theme.bar.height          taskbar height
--
-- Workspaces:
--   theme.ws = { "1", "2", "3" }   capsule labels; length = workspace count
--
-- Examples — edit /theme.lua and press Ctrl+S to apply live:
--   theme.accent = 0xFF5544             -- warm accent color
--   theme.wm.border = 4                 -- thicker window borders
--   theme.wm.gap_out = 8                -- gap to the screen edge
--   theme.wm.gap_in = 4                 -- gap between tiled windows
--   theme.wm.opacity_inactive = 0.7     -- dim inactive windows more
--   theme.ws = { "dev", "web", "chat" } -- named workspaces
--   theme.ws = { "1", "2", "3", "4" }   -- add a fourth workspace
--   theme.bar.height = 40               -- taller taskbar
--
-- The on-disk copy is /theme.lua (applied at boot, on F5 and after every
-- editor save). The last valid version is kept in .theme.bak and is used as
-- a fallback whenever the working copy does not parse or run.

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
    red        = 0xFF6B6B, -- read-only files (files browser), error

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

-- Deep-copy a table (theme has nested wm/bar/ws). A shallow copy would share
-- the nested tables and a config error could not roll them back.
local function clone(t)
    local c = {}
    for k, v in pairs(t) do
        if type(v) == "table" then c[k] = clone(v) else c[k] = v end
    end
    return c
end

-- Apply a Lua config chunk to the live theme atomically. Returns nil on
-- success or an error string. load() catches syntax errors; the chunk then
-- runs under pcall on a clone so a runtime error (e.g. a bad type) rolls
-- back to the previous theme instead of leaving a half-applied config.
function apply_theme_content(content)
    local cfg, err = load(content)
    if not cfg then return err end
    local saved = theme
    theme = clone(theme)
    local ok, res = pcall(cfg)
    if not ok then
        theme = saved
        return res
    end
    gfx.invalidate()
    return nil
end

-- Read a whole file through the file.* bindings; nil when it cannot be
-- opened (no disk, file missing).
function read_file(path)
    local h = file.open(path)
    if not h then return nil end
    local content = ""
    while true do
        local chunk = file.read(h, 4096)
        if not chunk or chunk == "" then break end
        content = content .. chunk
    end
    file.close(h)
    return content
end

-- Apply the persistent disk config (/theme.lua) if present: the config is
-- Lua code that overrides the theme table — there is no separate config
-- format (spec/runtime.md §5a trigger 2). When the working copy fails to
-- parse or run, the last valid version (.theme.bak) is applied instead and
-- the working copy's error is returned for the caller to report. Returns nil
-- when no config is present (defaults stand) or when it applied cleanly.
function apply_disk_theme()
    local content = read_file("/theme.lua")
    if content == nil then return nil end
    local err = apply_theme_content(content)
    if err == nil then return nil end
    local backup = read_file("/.theme.bak")
    if backup ~= nil then
        apply_theme_content(backup)
    end
    return err
end
