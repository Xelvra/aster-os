-- main.lua - Aster desktop shell (M5)
-- A small tiling window manager with a Noctalia-style bar, driven entirely
-- by the declarative `theme` table below. Change any value and the shell
-- repaints live (F5 or gfx.invalidate from the REPL); the kernel is never
-- rebuilt. The REPL is one of the windows (~ toggles it).
--
-- Keyboard (SUPER = the Windows key):
--   SUPER+1..3      switch workspace
--   SUPER+Q         close focused window
--   SUPER+Arrows    move focus
--   SUPER+Shift+Arrows  move window between workspaces
--   SUPER+D         toggle launcher
--   SUPER+~         toggle REPL
--   Alt+Tab         cycle focus
--   F5              hot reload (kernel restarts the Lua state)

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
    launcher   = 0x01CCFF,

    wm = {
        gap_out = 8,
        gap_in  = 3,
        border  = 2,
        radius  = 10,
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

local SW = gfx.width()
local SH = gfx.height()

-- ---------------------------------------------------------------------------
-- Window list. Each entry: { title, ws, x, y, w, h, floating }.
-- x/y/w/h are recomputed on every layout pass (tiling); floating windows
-- keep their position until tiled again (Super+Space toggles).
-- ---------------------------------------------------------------------------
local windows = {}
local focused = nil -- title of the focused window
local current_ws = 1
local drag = nil     -- { title, dx, dy } while dragging a window header
local layout_mode = "splith" -- "splith" (side by side) or "splitv" (stacked)
local fullscreen_win = nil    -- title of a fullscreen window, if any

local function window(title, ws)
    return { title = title, ws = ws, x = 0, y = 0, w = 0, h = 0, floating = false }
end

-- The REPL console lives as a window so it survives focus switches.
windows[#windows + 1] = window("repl", 1)
windows[#windows + 1] = window("sysmon", 1)
windows[#windows + 1] = window("files", 2)
focused = windows[1].title
local repl_visible = true

local function find_win(title)
    for _, w in ipairs(windows) do
        if w.title == title then return w end
    end
    return nil
end

local function set_focus(title)
    local w = find_win(title)
    if not w then return end
    focused = title
    -- Raise to top (z-order: end of list = topmost).
    for i, win in ipairs(windows) do
        if win.title == title then
            table.remove(windows, i)
            table.insert(windows, win)
            break
        end
    end
    gfx.invalidate()
end

-- ---------------------------------------------------------------------------
-- Tiling layout: within a workspace, windows are split either side by side
-- or stacked, always filling the area between the bar and the screen edges.
-- ---------------------------------------------------------------------------
local function layout_pass()
    local bar_h = theme.bar.height
    local out = theme.wm.gap_out
    local inner = theme.wm.gap_in
    local border = theme.wm.border
    local area_x = out
    local area_y = bar_h + out
    local area_w = SW - 2 * out
    local area_h = SH - bar_h - 2 * out

    -- Fullscreen: the window covers everything (no bar, no gaps).
    if fullscreen_win then
        local w = find_win(fullscreen_win)
        if w and w.ws == current_ws then
            w.x, w.y, w.w, w.h = 0, 0, SW, SH
            return
        else
            fullscreen_win = nil
        end
    end

    local ws_wins = {}
    for _, w in ipairs(windows) do
        if w.ws == current_ws and not w.floating then ws_wins[#ws_wins + 1] = w end
    end
    local n = #ws_wins
    for i, w in ipairs(ws_wins) do
        if n == 1 then
            w.x, w.y, w.w, w.h = area_x, area_y, area_w, area_h
        elseif layout_mode == "splith" then
            -- Side by side; focused window gets the wider split (60/40).
            local f = (focused == w.title)
            local left = (i == 1)
            local gap = inner + border
            local w1, w2 = math.floor(area_w * 0.6), math.floor(area_w * 0.4)
            if left then
                w.x = area_x
                w.y = area_y
                w.w = (f and w1 or w2) - gap
                w.h = area_h
            else
                w.x = area_x + (f and w1 or w2)
                w.y = area_y
                w.w = (f and w2 or w1) - gap
                w.h = area_h
            end
        else
            -- splitv: stack vertically.
            local gap = inner + border
            local row_h = math.floor((area_h - (n - 1) * gap) / n)
            w.x = area_x
            w.w = area_w
            w.y = area_y + (i - 1) * (row_h + gap)
            w.h = row_h
        end
    end
end

-- ---------------------------------------------------------------------------
-- Bar (Noctalia-style): launcher + clock + workspace capsules left,
-- volume / session right.
-- ---------------------------------------------------------------------------
local clock_cache = nil

local function bar_render()
    if fullscreen_win then return end
    local bar_h = theme.bar.height
    gfx.draw_rect(0, 0, SW, bar_h, theme.surface)

    local x = 8
    -- Launcher (a square rounded button).
    gfx.round_rect(x, (bar_h - 20) / 2, 20, 20, 6, theme.launcher)
    x = x + 20 + 8
    gfx.draw_text(">", x - 20 + 6, (bar_h - 16) / 2 + 1, theme.background)
    x = x + 4

    -- Clock.
    local t = time.ticks()
    local secs = math.floor(t / 100)
    local hh = math.floor(secs / 3600) % 24
    local mm = math.floor(secs / 60) % 60
    local clock = string.format("%02d:%02d", hh, mm)
    gfx.draw_text(clock, x, (bar_h - 16) / 2 + 1, theme.text)
    x = x + 5 * 8 + 12

    -- Workspace capsules.
    for i, name in ipairs(theme.ws) do
        local w = 4 + name:len() * 8 + 8
        local active = (i == current_ws)
        local color = active and theme.accent or theme.surface_alt
        local text_color = active and theme.background or theme.text_dim
        gfx.round_rect(x, (bar_h - 20) / 2, w, 20, 10, color)
        gfx.draw_text(name, x + 4, (bar_h - 16) / 2 + 1, text_color)
        x = x + w + 6
    end

    -- Right side: volume and session placeholders.
    local right = SW - 8
    local vol = "Vol 100%"
    gfx.draw_text(vol, right - vol:len() * 8, (bar_h - 16) / 2 + 1, theme.text)
    right = right - vol:len() * 8 - 16
    local sess = "Lock"
    gfx.draw_text(sess, right - sess:len() * 8, (bar_h - 16) / 2 + 1, theme.text_dim)
end

-- ---------------------------------------------------------------------------
-- Window rendering.
-- ---------------------------------------------------------------------------
local function blend(color, factor)
    -- factor in [0,1]; darken toward background for inactive opacity.
    local br = math.floor((color >> 16) & 0xFF)
    local bg = math.floor((color >> 8) & 0xFF)
    local bb = math.floor(color & 0xFF)
    local abr = math.floor((theme.background >> 16) & 0xFF)
    local abg = math.floor((theme.background >> 8) & 0xFF)
    local abb = math.floor(theme.background & 0xFF)
    local r = math.floor(br + (abr - br) * (1 - factor))
    local g = math.floor(bg + (abg - bg) * (1 - factor))
    local b = math.floor(bb + (abb - bb) * (1 - factor))
    return (r << 16) | (g << 8) | b
end

local function win_render(w)
    local active = (focused == w.title)
    local border_c = active and theme.accent or theme.inactive
    local title_bg = active and theme.surface_alt or theme.surface
    local opacity = active and theme.wm.opacity_active or theme.wm.opacity_inactive

    -- Border.
    if active then
        gfx.gradient_border(w.x, w.y, w.w, w.h, theme.wm.border, theme.accent, theme.accent_dark)
    else
        gfx.rect_border(w.x, w.y, w.w, w.h, theme.wm.border, border_c)
    end

    -- Title bar.
    local tx = w.x + theme.wm.border
    local ty = w.y + theme.wm.border
    local th = theme.wm.title_h
    gfx.draw_rect(tx, ty, w.w - 2 * theme.wm.border, th, blend(title_bg, opacity))

    -- Body.
    gfx.draw_rect(tx, ty + th, w.w - 2 * theme.wm.border, w.h - 2 * theme.wm.border - th, blend(theme.surface, opacity))

    -- Title text.
    local label = w.title
    if w.title == "repl" then
        label = "~ repl"
    elseif w.title == "sysmon" then
        label = "sysmon"
    end
    gfx.draw_text(label, tx + 6, ty + (th - 16) / 2 + 1, active and theme.text or theme.text_dim)
end

local function repl_render()
    if not repl_visible then return end
    local w = find_win("repl")
    if not w or w.ws ~= current_ws then return end
    local tx = w.x + theme.wm.border + 6
    local ty = w.y + theme.wm.border + theme.wm.title_h + 6
    local row_h = 18
    local max_lines = math.floor((w.h - theme.wm.title_h - 12) / row_h)
    local col = tx
    local i = math.max(1, #lines - max_lines + 1)
    while i <= #lines do
        gfx.draw_text(lines[i], col, ty, theme.text)
        ty = ty + row_h
        i = i + 1
    end
    local prompt = "> " .. current
    gfx.draw_text(prompt, col, ty, theme.text)
    local cx = col + (2 + cursor) * glyph_w
    gfx.draw_rect(cx, ty, glyph_w, glyph_h, theme.accent)
end

local function sysmon_render()
    local w = find_win("sysmon")
    if not w or w.ws ~= current_ws then return end
    local tx = w.x + theme.wm.border + 6
    local ty = w.y + theme.wm.border + theme.wm.title_h + 6
    local total = sysmon.ram_total_mb()
    local free = sysmon.ram_free_mb()
    local used = math.max(total - free, 0)
    gfx.draw_text("ram " .. tostring(used) .. "M / " .. tostring(total) .. "M", tx, ty, theme.text)
    ty = ty + 18
    local pct = (total > 0) and math.floor(used * 100 / total) or 0
    gfx.draw_text("ram " .. tostring(pct) .. "%", tx, ty, theme.text_dim)
    ty = ty + 18
    gfx.draw_text("ticks " .. tostring(time.ticks()), tx, ty, theme.text_dim)
end

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
    local ly = bar_height + 8 + math.max(math.floor((SH - bar_height - 8 - lh) / 2), 0)
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
-- REPL state (shared with the earlier shell; kept as globals so reload
-- works without the kernel knowing).
-- ---------------------------------------------------------------------------
lines = lines or {}
current = current or ""
history = history or {}
hist_idx = hist_idx or 0
cursor = cursor or 0
glyph_w = 8
glyph_h = 16
bar_height = theme.bar.height

local function add_line(s)
    table.insert(lines, s)
    if #lines > 200 then table.remove(lines, 1) end
end

add_line("shell  F5")

function print(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    add_line(table.concat(parts, "\t"))
end

local function run(code)
    local chunk, err = load(code)
    if not chunk then
        add_line("error: " .. tostring(err))
        gfx.invalidate()
        return
    end
    local ok, res = pcall(chunk)
    if not ok then
        add_line("error: " .. tostring(res))
    elseif res ~= nil then
        add_line(tostring(res))
    end
    gfx.invalidate()
end

-- ---------------------------------------------------------------------------
-- Input handling.
-- ---------------------------------------------------------------------------
local function is_in_header(w)
    local mx = input.mouse_x()
    local my = input.mouse_y()
    return mx >= w.x and mx <= w.x + w.w and
           my >= w.y and my <= w.y + theme.wm.border + theme.wm.title_h
end

local function is_in_window(w)
    local mx = input.mouse_x()
    local my = input.mouse_y()
    return mx >= w.x and mx <= w.x + w.w and my >= w.y and my <= w.y + w.h
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

local function handle_mouse()
    local mx = input.mouse_x()
    local my = input.mouse_y()
    local left = input.mouse_left()

    if launcher_open then
        if left and not launcher_was_down then
            -- Clicking an item runs it; click outside closes.
            local items = launcher_filtered()
            local row_h = 20
            local lw, lh = 320, 40 + math.max(#items, 1) * row_h
            local lx = math.floor((SW - lw) / 2)
            local ly = bar_height + 8 + math.max(math.floor((SH - bar_height - 8 - lh) / 2), 0)
            if mx >= lx and mx <= lx + lw and my >= ly and my <= ly + lh then
                local idx = math.floor((my - ly - 30) / row_h) + 1
                if items[idx] then
                    launcher_open = false
                    launcher_run(items[idx].id)
                    gfx.invalidate()
                end
            else
                launcher_open = false
                gfx.invalidate()
            end
        end
        launcher_was_down = left
        return
    end

    if left then
        if not launcher_was_down then
            -- Find window under the cursor (topmost first).
            for i = #windows, 1, -1 do
                local w = windows[i]
                if is_in_window(w) then
                    set_focus(w.title)
                    if is_in_header(w) then
                        drag = { title = w.title, dx = mx - w.x, dy = my - w.y }
                    end
                    break
                end
            end
            -- Clicking a workspace capsule switches workspace.
            local x = 8 + 20 + 8 + 5 * 8 + 12 + 4
            for i, name in ipairs(theme.ws) do
                local ww = 4 + name:len() * 8 + 8
                if mx >= x and mx <= x + ww and my >= 0 and my <= bar_height then
                    current_ws = i
                    layout_pass()
                    gfx.invalidate()
                end
                x = x + ww + 6
            end
        end
        if drag then
            local w = find_win(drag.title)
            if w and w.floating then
                w.x = mx - drag.dx
                w.y = my - drag.dy
                -- Keep the window on screen.
                w.x = math.max(0, math.min(w.x, SW - w.w))
                w.y = math.max(theme.bar.height, math.min(w.y, SH - w.h))
                gfx.invalidate()
            end
        end
    else
        drag = nil
    end
    launcher_was_down = left
end

local function handle_key(ev)
    local code = ev.code
    if launcher_open then
        local items = launcher_filtered()
        if code == "escape" then
            launcher_open = false
        elseif code == "enter" then
            launcher_open = false
            if items[launcher_sel] then launcher_run(items[launcher_sel].id) end
        elseif code == "up" then
            launcher_sel = math.max(launcher_sel - 1, 1)
        elseif code == "down" then
            launcher_sel = math.min(launcher_sel + 1, math.max(#items, 1))
        elseif code == "backspace" then
            launcher_input = string.sub(launcher_input, 1, -2)
            launcher_sel = 1
        elseif ev.char then
            launcher_input = launcher_input .. ev.char
            launcher_sel = 1
        end
        gfx.invalidate()
        return
    end

    -- SUPER = mainMod (Hyprland convention). Window management:
    --   Super+Enter     terminal (REPL dropdown)
    --   Super+Q         close focused window
    --   Super+Space     launcher
    --   Super+Alt+Space float toggle
    --   Super+F / D     fullscreen
    --   Super+J         togglesplit
    --   Super+arrows    focus direction
    --   Super+Shift+arrows  move window (swap position)
    --   Super+1/2/3     workspace
    --   Super+Shift+1/2/3   move window to workspace
    --   Super+S         toggle special (scratchpad)
    if ev.super and ev.pressed then
        if code == "digit_1" then
            current_ws = 1
        elseif code == "digit_2" then
            current_ws = 2
        elseif code == "digit_3" then
            current_ws = 3
        elseif code == "enter" then
            -- Terminal: show the REPL and focus it.
            repl_visible = true
            set_focus("repl")
        elseif code == "q" then
            if find_win(focused) then
                for i, w in ipairs(windows) do
                    if w.title == focused then table.remove(windows, i) break end
                end
                if #windows > 0 then set_focus(windows[#windows].title) end
            end
        elseif code == "space" then
            if ev.alt then
                -- Super+Alt+Space: float toggle.
                local w = find_win(focused)
                if w and w.ws == current_ws then
                    w.floating = not w.floating
                    if not w.floating then
                        w.x, w.y, w.w, w.h = 0, 0, 0, 0
                    else
                        w.w = math.floor(SW * 0.5)
                        w.h = math.floor((SH - theme.bar.height) * 0.6)
                        w.x = math.floor((SW - w.w) / 2)
                        w.y = theme.bar.height + math.floor(((SH - theme.bar.height) - w.h) / 2)
                    end
                end
            else
                launcher_open = not launcher_open
                if launcher_open then
                    launcher_input = ""
                    launcher_sel = 1
                end
            end
        elseif code == "f" or code == "d" then
            -- Fullscreen toggle.
            if fullscreen_win == focused then
                fullscreen_win = nil
            elseif find_win(focused) then
                fullscreen_win = focused
            end
        elseif code == "j" then
            -- Toggle between side-by-side and stacked layout.
            layout_mode = (layout_mode == "splith") and "splitv" or "splith"
        elseif code == "s" then
            -- Scratchpad: float the focused window (special workspace).
            local w = find_win(focused)
            if w then
                if w.floating then
                    w.floating = false
                    w.x, w.y, w.w, w.h = 0, 0, 0, 0
                else
                    w.floating = true
                    w.w = math.floor(SW * 0.5)
                    w.h = math.floor((SH - theme.bar.height) * 0.5)
                    w.x = math.floor((SW - w.w) / 2)
                    w.y = theme.bar.height + 8
                end
            end
        elseif ev.shift then
            -- Super+Shift+arrows: move the focused window in the layout or to
            -- another workspace. Super+Shift+1/2/3 moves it to that workspace.
            local w = find_win(focused)
            if w then
                if code == "digit_1" then
                    w.ws = 1
                elseif code == "digit_2" then
                    w.ws = 2
                elseif code == "digit_3" then
                    w.ws = 3
                elseif code == "right" then
                    w.ws = math.min(w.ws + 1, #theme.ws)
                elseif code == "left" then
                    w.ws = math.max(w.ws - 1, 1)
                elseif code == "down" then
                    w.ws = math.min(w.ws + 1, #theme.ws)
                elseif code == "up" then
                    w.ws = math.max(w.ws - 1, 1)
                end
                w.floating = false
                w.x, w.y, w.w, w.h = 0, 0, 0, 0
                current_ws = w.ws
            end
        elseif code == "left" or code == "right" or code == "up" or code == "down" then
            -- Focus in a direction among windows on this workspace.
            local ws_wins = {}
            for _, w in ipairs(windows) do
                if w.ws == current_ws then ws_wins[#ws_wins + 1] = w end
            end
            if #ws_wins > 0 then
                local idx = 1
                for i, w in ipairs(ws_wins) do if w.title == focused then idx = i break end end
                local dir = (code == "right" or code == "down") and 1 or -1
                local nxt = ws_wins[((idx - 1 + dir) % #ws_wins) + 1]
                if nxt then set_focus(nxt.title) end
            end
        end
        layout_pass()
        gfx.invalidate()
        return
    end

    if ev.alt and ev.pressed and code == "tab" then
        local ws_wins = {}
        for _, w in ipairs(windows) do
            if w.ws == current_ws then ws_wins[#ws_wins + 1] = w end
        end
        if #ws_wins > 0 then
            local idx = 1
            for i, w in ipairs(ws_wins) do if w.title == focused then idx = i break end end
            local nxt = ws_wins[(idx % #ws_wins) + 1]
            if nxt then set_focus(nxt.title) end
        end
        return
    end

    -- REPL input goes to the focused window when it is the REPL.
    if find_win(focused) and focused == "repl" and repl_visible then
        if code == "enter" then
            add_line("> " .. current)
            if current ~= "" then table.insert(history, current) end
            run(current)
            current = ""
            cursor = 0
        elseif code == "backspace" then
            current = string.sub(current, 1, cursor - 1) .. string.sub(current, cursor + 1)
            cursor = cursor - 1
        elseif code == "left" then
            if cursor > 0 then cursor = cursor - 1 end
        elseif code == "right" then
            if cursor < #current then cursor = cursor + 1 end
        elseif code == "up" then
            if #history > 0 then
                if hist_idx == 0 then hist_idx = #history end
                hist_idx = hist_idx - 1
                if hist_idx == 0 then hist_idx = #history end
                current = history[hist_idx]
                cursor = #current
            end
        elseif code == "down" then
            if #history > 0 then
                hist_idx = hist_idx + 1
                if hist_idx > #history then hist_idx = 1 end
                current = history[hist_idx]
                cursor = #current
            end
        elseif code == "home" then
            cursor = 0
        elseif code == "end" then
            cursor = #current
        elseif code == "delete" then
            if cursor < #current then
                current = string.sub(current, 1, cursor) .. string.sub(current, cursor + 2)
            end
        elseif ev.char then
            current = string.sub(current, 1, cursor) .. ev.char .. string.sub(current, cursor + 1)
            cursor = cursor + 1
        end
        gfx.invalidate()
    end
end

-- ---------------------------------------------------------------------------
-- Update + render entry points called by the kernel.
-- ---------------------------------------------------------------------------
function update()
    layout_pass()
    handle_mouse()
    local ev = input.next_event()
    if ev then
        if ev.type == "key" and ev.pressed then
            handle_key(ev)
        end
    end
end

function render()
    gfx.fill_screen(theme.background)
    layout_pass()
    bar_render()
    -- Tiled windows first, then floating windows on top.
    for _, w in ipairs(windows) do
        if w.ws == current_ws and not w.floating then
            win_render(w)
        end
    end
    for _, w in ipairs(windows) do
        if w.ws == current_ws and w.floating then
            win_render(w)
        end
    end
    if repl_visible then repl_render() end
    sysmon_render()
    if launcher_open then launcher_render() end
end
