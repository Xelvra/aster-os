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
-- Examples — edit /wm/theme.lua and press Ctrl+S to apply live:
--   theme.accent = 0xFF5544             -- warm accent color
--   theme.wm.border = 4                 -- thicker window borders
--   theme.wm.gap_out = 8                -- gap to the screen edge
--   theme.wm.gap_in = 4                 -- gap between tiled windows
--   theme.wm.opacity_inactive = 0.7     -- dim inactive windows more
--   theme.ws = { "dev", "web", "chat" } -- named workspaces
--   theme.ws = { "1", "2", "3", "4" }   -- add a fourth workspace
--   theme.bar.height = 40               -- taller taskbar
--
-- The on-disk copy is /wm/theme.lua (applied at boot, on F5 and after every
-- editor save). A broken or missing working copy falls back to the built-in
-- initrd defaults; /wm/.theme.bak keeps the previous Ctrl+S as a read-only
-- manual backup that is never loaded automatically (ADR-025).

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

-- Validate the structure of a theme table: a syntactically valid config can
-- still be semantically broken (e.g. `theme.wm = {}`), and applying it would
-- crash the next layout_pass and loop the hot reload forever. Every field the
-- shell arithmetic relies on must have the right type before the theme is
-- swapped in (audit 2026-08-15).
local function theme_valid(t)
    if type(t) ~= "table" then return false end
    local numeric = {
        "background", "surface", "surface_alt", "text", "text_dim",
        "accent", "accent_b", "accent_dark", "inactive", "red",
    }
    for _, k in ipairs(numeric) do
        if type(t[k]) ~= "number" then return false end
    end
    if type(t.wm) ~= "table" then return false end
    local wm_numeric = { "gap_out", "gap_in", "border", "title_h", "opacity_active", "opacity_inactive" }
    for _, k in ipairs(wm_numeric) do
        if type(t.wm[k]) ~= "number" then return false end
    end
    if type(t.bar) ~= "table" or type(t.bar.height) ~= "number" then return false end
    if type(t.ws) ~= "table" or #t.ws == 0 then return false end
    return true
end

-- Apply a Lua config chunk to the live theme atomically. Returns nil on
-- success or an error string. load() catches syntax errors; the chunk then
-- runs under pcall on a clone so a runtime error (e.g. a bad type) rolls
-- back to the previous theme instead of leaving a half-applied config. The
-- result is validated structurally (theme_valid) so a semantically broken
-- config is rejected the same way and the shell never hot-reloads it forever.
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
    if not theme_valid(theme) then
        theme = saved
        return "invalid theme: missing or wrong-typed field"
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

-- Apply the persistent disk config (/wm/theme.lua) if present: the config is
-- Lua code that overrides the theme table — there is no separate config
-- format (spec/runtime.md §5a trigger 2). A broken or missing working copy is
-- never used: the error is returned for the caller to report and the live
-- theme stays on the built-in initrd default (rollback inside
-- apply_theme_content). /wm/.theme.bak is only a manual backup of the last
-- Ctrl+S — it is never loaded as configuration (ADR-025). Returns nil when
-- no config is present (defaults stand) or when it applied cleanly.
function apply_disk_theme()
    local content = read_file("/wm/theme.lua")
    if content == nil then return nil end
    return apply_theme_content(content)
end
