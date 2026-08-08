-- launcher.lua - application launcher (Super+Space): search box + filtered list.

-- Applications the launcher can run. Each entry is { title, id }; the id
-- maps to a shell action (open a window, toggle something).
local apps = {
    { title = "repl",        id = "repl" },
    { title = "sysmon",      id = "sysmon" },
    { title = "files",       id = "files" },
    { title = "toggle fullscreen", id = "fullscreen" },
    { title = "close",       id = "close" },
}

-- Launcher state (declared before the render/input functions that use it,
-- so a local in Lua is visible from the first render).
local launcher_open = false
local launcher_input = ""
local launcher_sel = 1
local launcher_was_down = false

local function launcher_filtered()
    local q = launcher_input:lower()
    local out = {}
    for _, a in ipairs(apps) do
        if q == "" or a.title:lower():find(q, 1, true) then
            out[#out + 1] = a
        end
    end
    return out
end

local function launcher_render()
    -- A centered popup with a search box and the filtered app list.
    local items = launcher_filtered()
    local row_h = 20
    local lw, lh = 320, 40 + math.max(#items, 1) * row_h
    local lx = math.floor((SW - lw) / 2)
    local ly = theme.bar.height + 8 + math.max(math.floor((SH - theme.bar.height - 8 - lh) / 2), 0)
    gfx.round_rect(lx, ly, lw, lh, 10, theme.surface)
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
        set_focus("files")
    elseif id == "fullscreen" then
        if fullscreen_win == focused then
            fullscreen_win = nil
        elseif find_win(focused) then
            fullscreen_win = focused
        end
    elseif id == "close" then
        if find_win(focused) then
            for i, w in ipairs(windows) do
                if w.title == focused then table.remove(windows, i) break end
            end
            if #windows > 0 then set_focus(windows[#windows].title) end
        end
    end
    layout_pass()
end
