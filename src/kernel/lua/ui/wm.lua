-- wm.lua - window manager state, tiling layout, bar and window rendering.
-- Concatenated with the other ui modules into one Lua chunk by lua.zig, so
-- local state here is shared across the whole shell.

local SW = gfx.width()
local SH = gfx.height()

-- Window list. Each entry: { title, ws, x, y, w, h, floating, z }.
-- The list order is the tiling order; `z` is the focus/z-order (higher is
-- drawn on top). set_focus() bumps z but never reorders the list, so
-- changing focus cannot shuffle the tiled layout.
local windows = {}
local focused = nil -- title of the focused window
local current_ws = 1
local drag = nil     -- { title, dx, dy } while dragging a window header
local layout_mode = "splith" -- "splith" (side by side) or "splitv" (stacked)
local fullscreen_win = nil    -- title of a fullscreen window, if any
local z_counter = 0

local function window(title, ws)
    z_counter = z_counter + 1
    return { title = title, ws = ws, x = 0, y = 0, w = 0, h = 0, floating = false, z = z_counter }
end

-- The REPL console lives as a window so it survives focus switches.
windows[#windows + 1] = window("repl", 1)
windows[#windows + 1] = window("sysmon", 1)
windows[#windows + 1] = window("files", 2)
focused = windows[1].title
local repl_visible = true

-- Session menu (bar "Lock" button): lock overlay, logout (shell reload),
-- reboot (i8042 reset). "Lock" has no auth yet — any key unlocks.
local session_items = {
    { title = "Lock",   id = "lock" },
    { title = "Logout", id = "logout" },
    { title = "Reboot", id = "reboot" },
}
local session_open = false
local session_sel = 1
local session_btn = { x = 0, w = 0 }
local locked = false

local function session_run(id)
    if id == "lock" then
        locked = true
    elseif id == "logout" then
        runtime.reload()
    elseif id == "reboot" then
        power.reboot()
    end
    gfx.invalidate()
end

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
    -- Raise to top (z-order) without reordering `windows`: the list order
    -- is the tiling order, so focus must never shuffle the layout.
    z_counter = z_counter + 1
    w.z = z_counter
    gfx.invalidate()
end

local function ws_windows(ws)
    local out = {}
    for _, w in ipairs(windows) do
        if w.ws == ws then out[#out + 1] = w end
    end
    return out
end

-- Topmost (highest z) window on a workspace, or nil.
local function topmost_of(ws)
    local best = nil
    for _, w in ipairs(ws_windows(ws)) do
        if best == nil or w.z > best.z then best = w end
    end
    return best
end

-- Focus the topmost window on a workspace so typing works right away
-- (workspace switches via key or capsule, and after closing a window).
local function focus_topmost(ws)
    local t = topmost_of(ws)
    if t then
        set_focus(t.title)
    elseif ws == current_ws then
        focused = nil
    end
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

    -- Tiling only positions non-floating windows; floating windows keep
    -- their manual x/y (dragged or the float-toggle defaults).
    local tiled = {}
    for _, w in ipairs(ws_windows(current_ws)) do
        if not w.floating then tiled[#tiled + 1] = w end
    end
    local n = #tiled
    for i, w in ipairs(tiled) do
        if n == 1 then
            w.x, w.y, w.w, w.h = area_x, area_y, area_w, area_h
        elseif layout_mode == "splith" then
            local gap = inner + border
            local w1, w2 = math.floor(area_w * 0.6), math.floor(area_w * 0.4)
            if n == 2 then
                -- Side by side; the focused window gets the wider split (60/40)
                -- and the positions stay stable (first window left).
                local f = (focused == w.title)
                if i == 1 then
                    w.x = area_x
                    w.y = area_y
                    w.w = (f and w1 or w2) - gap
                    w.h = area_h
                else
                    w.x = area_x + (f and w2 or w1)
                    w.y = area_y
                    w.w = (f and w1 or w2) - gap
                    w.h = area_h
                end
            else
                -- Master-stack: the first window is the master (left, wider),
                -- the rest stack in the right column (spec/lua-wm.md §6.3).
                local stack_n = n - 1
                local row_h = math.floor((area_h - (stack_n - 1) * gap) / stack_n)
                if i == 1 then
                    w.x = area_x
                    w.y = area_y
                    w.w = w1 - gap
                    w.h = area_h
                else
                    w.x = area_x + w1
                    w.y = area_y + (i - 2) * (row_h + gap)
                    w.w = w2 - gap
                    w.h = row_h
                end
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
-- ---------------------------------------------------------------------------
-- Shared workspace-capsule geometry: the bar draws them and handle_mouse
-- hit-tests them; one source of truth so the two can never drift apart.
-- Returns { { i = <ws index>, x = <left>, w = <width> }, ... }.
local function ws_capsules()
    local list = {}
    local x = 8 + 20 + 8 + 4 + 5 * 8 + 12
    for i, name in ipairs(theme.ws) do
        local w = 4 + name:len() * 8 + 8
        list[#list + 1] = { i = i, x = x, w = w }
        x = x + w + 6
    end
    return list
end

local function bar_render()
    if fullscreen_win then return end
    local bar_h = theme.bar.height
    gfx.draw_rect(0, 0, SW, bar_h, theme.surface)

    local x = 8
    -- Launcher (a square rounded button).
    gfx.round_rect(x, (bar_h - 20) // 2, 20, 20, 6, theme.launcher)
    x = x + 20 + 8
    gfx.draw_text(">", x - 20 + 6, (bar_h - 16) // 2 + 1, theme.background)
    x = x + 4

    -- Clock.
    local t = time.ticks()
    local secs = math.floor(t / 100)
    local hh = math.floor(secs / 3600) % 24
    local mm = math.floor(secs / 60) % 60
    local clock = string.format("%02d:%02d", hh, mm)
    gfx.draw_text(clock, x, (bar_h - 16) // 2 + 1, theme.text)
    x = x + 5 * 8 + 12

    -- Workspace capsules.
    for _, c in ipairs(ws_capsules()) do
        local active = (c.i == current_ws)
        local color = active and theme.accent or theme.surface_alt
        local text_color = active and theme.background or theme.text_dim
        gfx.round_rect(c.x, (bar_h - 20) // 2, c.w, 20, 10, color)
        gfx.draw_text(theme.ws[c.i], c.x + 4, (bar_h - 16) // 2 + 1, text_color)
    end

    -- Right side: volume placeholder and the session button (opens the menu).
    local right = SW - 8
    local vol = "Vol 100%"
    gfx.draw_text(vol, right - vol:len() * 8, (bar_h - 16) // 2 + 1, theme.text)
    right = right - vol:len() * 8 - 16
    local sess = "Lock"
    local sess_x = right - sess:len() * 8
    gfx.draw_text(sess, sess_x, (bar_h - 16) // 2 + 1, theme.text_dim)
    session_btn.x = sess_x
    session_btn.w = sess:len() * 8
end

local function session_menu_render()
    local row_h = 20
    local w = 140
    local h = 8 + #session_items * row_h
    local x = session_btn.x
    local y = theme.bar.height + 2
    gfx.round_rect(x, y, w, h, 8, theme.surface)
    gfx.rect_border(x, y, w, h, 1, theme.accent)
    local ty = y + 4
    for i, it in ipairs(session_items) do
        local sel = (i == session_sel)
        gfx.draw_text(it.title, x + 8, ty, sel and theme.accent or theme.text_dim)
        ty = ty + row_h
    end
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
    gfx.draw_text(label, tx + 6, ty + (th - 16) // 2 + 1, active and theme.text or theme.text_dim)
end
