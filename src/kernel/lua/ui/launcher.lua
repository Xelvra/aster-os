-- launcher.lua - application launcher (Super+Space): search box + filtered list.

-- Applications the launcher can run. Each entry is { title, id }; the id
-- maps to a shell action (open a window, toggle something). Apps come first,
-- then window actions.
local apps = {
    { title = "repl",        id = "repl" },
    { title = "sysmon",      id = "sysmon" },
    { title = "files",       id = "files" },
    { title = "editor",      id = "editor" },
}
local actions = {
    { title = "help",            id = "help" },
    { title = "toggle fullscreen", id = "fullscreen" },
    { title = "close",       id = "close" },
}

-- Launcher state (declared before the render/input functions that use it,
-- so a local in Lua is visible from the first render).
local launcher_open = false
local launcher_input = ""
local launcher_sel = 1
local launcher_mode = "run" -- "run" (app list) or "help" (keybinding cheat sheet)
local mouse_was_down = false

-- Keybinding cheat sheet. "active" is shown normally, "reserved" dimmed:
-- the shortcuts are planned but not wired yet (spec/lua-wm.md §7a).
local shortcuts_active = {
    { "Super+Enter", "terminal (REPL)" },
    { "Super+T", "editor" },
    { "Super+Z", "settings" },
    { "Super+E", "file manager" },
    { "Super+Q", "close window" },
    { "Super+Space", "launcher" },
    { "Super+Alt+Space", "float toggle" },
    { "Super+F / D", "fullscreen" },
    { "Super+J", "togglesplit" },
    { "Super+arrows", "focus direction" },
    { "Super+Shift+arrows", "move window" },
    { "Super+1/2/3", "workspace" },
    { "Super+S", "scratchpad" },
    { "Alt+Tab", "cycle windows" },
    { "F5", "hot reload" },
}
local shortcuts_reserved = {
    { "Super+C", "calculator" },
    { "Super+W", "browser" },
    { "Super+X", "control center" },
    { "Super+V", "clipboard" },
    { "Super+A", "notifications" },
    { "Super+P", "color picker" },
    { "Print", "screenshot" },
}

local function launcher_filtered()
    local q = launcher_input:lower()
    local out = {}
    local function add(list)
        for _, a in ipairs(list) do
            if q == "" or a.title:lower():find(q, 1, true) then
                out[#out + 1] = a
            end
        end
    end
    add(apps)
    add(actions)
    return out
end

-- Open the launcher in a given mode: "run" (app list) or "help" (shortcut
-- cheat sheet). Called from Super+Space and the bar chevron.
local function launcher_open_mode(mode)
    launcher_open = true
    launcher_mode = mode
    launcher_input = ""
    launcher_sel = 1
    gfx.invalidate()
end

local function launcher_render()
    -- Help mode: a cheat sheet of active and reserved keybindings, wider than
    -- the run popup.
    if launcher_mode == "help" then
        local row_h = 18
        local lw, lh = 460, 40 + (#shortcuts_active + #shortcuts_reserved + 2) * row_h
        local lx = math.floor((SW - lw) / 2)
        local ly = theme.bar.height + 8 + math.max(math.floor((SH - theme.bar.height - 8 - lh) / 2), 0)
        gfx.draw_rect(lx, ly, lw, lh, theme.surface)
        gfx.rect_border(lx, ly, lw, lh, 1, theme.accent)
        -- "help:" is white like the run prompt; the Esc hint is dimmed.
        gfx.draw_text("help: ", lx + 8, ly + 8, theme.text)
        gfx.draw_text("Esc back", lx + 8 + 6 * 8, ly + 8, theme.text_dim)
        local ty = ly + 30
        for _, s in ipairs(shortcuts_active) do
            gfx.draw_text(s[1], lx + 12, ty, theme.text)
            gfx.draw_text(s[2], lx + 200, ty, theme.text_dim)
            ty = ty + row_h
        end
        for _, s in ipairs(shortcuts_reserved) do
            gfx.draw_text(s[1], lx + 12, ty, theme.text_dim)
            gfx.draw_text(s[2], lx + 200, ty, theme.text_dim)
            ty = ty + row_h
        end
        return
    end
    -- Run mode: a centered popup with a search box and the filtered app list.
    local items = launcher_filtered()
    local row_h = 20
    local lw, lh = 320, 40 + math.max(#items, 1) * row_h
    local lx = math.floor((SW - lw) / 2)
    local ly = theme.bar.height + 8 + math.max(math.floor((SH - theme.bar.height - 8 - lh) / 2), 0)
    gfx.draw_rect(lx, ly, lw, lh, theme.surface)
    gfx.rect_border(lx, ly, lw, lh, 1, theme.accent)
    -- Search box.
    gfx.draw_text("run: " .. launcher_input, lx + 8, ly + 8, theme.text)
    local ty = ly + 30
    for i, a in ipairs(items) do
        local sel = (i == launcher_sel)
        local color = sel and theme.accent or theme.text_dim
        gfx.draw_text(a.title, lx + 12, ty, color)
        ty = ty + row_h
    end
    if #items == 0 then
        gfx.draw_text("no match", lx + 12, ty, theme.text_dim)
    end
end

-- ---------------------------------------------------------------------------
-- Launcher actions: map an app id to a shell action.
-- ---------------------------------------------------------------------------
local function launcher_run(id)
    if id == "repl" then
        local w = find_win("repl")
        if not w then
            windows[#windows + 1] = window("repl", current_ws)
        else
            w.ws = current_ws
        end
        repl_visible = true
        set_focus("repl")
    elseif id == "sysmon" then
        local w = find_win("sysmon")
        if not w then
            windows[#windows + 1] = window("sysmon", current_ws)
            w = windows[#windows]
        end
        w.ws = current_ws
        set_focus("sysmon")
    elseif id == "files" then
        local w = find_win("files")
        if not w then
            windows[#windows + 1] = window("files", current_ws)
        else
            w.ws = current_ws
        end
        files_open("/")
        set_focus("files")
    elseif id == "editor" then
        local w = find_win("editor")
        if not w then
            windows[#windows + 1] = window("editor", current_ws)
        else
            w.ws = current_ws
        end
        -- Like Super+T: a clean buffer starts a fresh untitled document, a
        -- dirty buffer is kept so unsaved edits are never lost.
        if not ed_open or not ed_dirty then editor_load(nil) end
        set_focus("editor")
    elseif id == "help" then
        launcher_mode = "help"
        launcher_input = ""
        launcher_sel = 1
        gfx.invalidate()
    elseif id == "fullscreen" then
        if fullscreen_win == focused then
            fullscreen_win = nil
        elseif find_win(focused) then
            fullscreen_win = focused
        end
    elseif id == "close" then
        if find_win(focused) then close_window(focused) end
    end
    layout_pass()
end
