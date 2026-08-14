-- theme.lua - declarative colors and geometry (hot-reloadable).
-- Open with Super+T, edit, save with Ctrl+S — the whole system repaints
-- live, no F5 and no kernel rebuild. A config error is reported in the REPL
-- and the last valid look stays; the system never crashes.
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
-- opened (no disk, file missing). Global so other modules (files.lua via
-- theme_config_valid) can read the config.
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

-- Check whether the on-disk /theme.lua parses and runs without applying it
-- (no live change, no invalidate). Used to protect the .theme.bak fallback:
-- while the working config is broken, the backup must not be deleted.
function theme_config_valid()
    local content = read_file("/theme.lua")
    if content == nil then return true end
    local cfg, err = load(content)
    if not cfg then return false, err end
    local saved = theme
    theme = clone(theme)
    local ok, res = pcall(cfg)
    theme = saved
    if not ok then return false, res end
    return true
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
