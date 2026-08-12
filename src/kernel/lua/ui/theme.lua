-- theme.lua - declarative colors and geometry (hot-reloadable via F5)
-- Change any value and the shell repaints live; the kernel is never rebuilt.

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

-- Apply the persistent disk config (/theme.lua on the mounted filesystem) if
-- present: the config is Lua code that overrides the theme table — there is
-- no separate config format (spec/runtime.md §5a trigger 2). Called at boot,
-- on F5 reload, and after every editor save.
function apply_disk_theme()
    local h = file.open("/theme.lua")
    if not h then return end
    local content = ""
    while true do
        local chunk = file.read(h, 4096)
        if not chunk or chunk == "" then break end
        content = content .. chunk
    end
    file.close(h)
    local cfg = load(content)
    if cfg then
        pcall(cfg)
    end
    gfx.invalidate()
end

apply_disk_theme()
