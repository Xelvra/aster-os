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
-- Geometry of the window before it entered fullscreen, restored on exit so a
-- floating window (e.g. the scratchpad) returns to its previous size/position.
-- Tiled windows are repositioned by layout_pass, so only floating ones need
-- the restore.
local fullscreen_restore = nil

local function find_win(title)
    for _, w in ipairs(windows) do
        if w.title == title then return w end
    end
    return nil
end

-- Leave fullscreen and give a floating window its geometry back (tiled windows
-- are repositioned by layout_pass). Shared by toggle_fullscreen, workspace
-- switches and window move — every place that clears fullscreen_win.
local function exit_fullscreen()
    if fullscreen_win then
        local w = find_win(fullscreen_win)
        if fullscreen_restore and w and w.floating then
            w.x, w.y, w.w, w.h = fullscreen_restore.x, fullscreen_restore.y, fullscreen_restore.w, fullscreen_restore.h
        end
        fullscreen_win = nil
    end
    fullscreen_restore = nil
end

-- Toggle fullscreen for a window (Super+F/D, F11, launcher "fullscreen"
-- action). Stores the geometry before entering so exiting restores it — this
-- is what keeps a floating scratchpad window from staying fullscreen-sized
-- after the second Super+F/D.
local function toggle_fullscreen(title)
    if fullscreen_win == title then
        exit_fullscreen()
    else
        local w = find_win(title)
        if w then
            fullscreen_restore = { x = w.x, y = w.y, w = w.w, h = w.h }
            fullscreen_win = title
        end
    end
end
local z_counter = 0
-- Real scratchpad state: Super+S toggles a dedicated window over anything
-- (a fullscreen window or an empty workspace). The first Super+S picks which
-- application becomes the scratchpad (launcher scratchpad mode — applications
-- only); afterwards Super+S only shows/hides that window — a stateful toggle,
-- not an alias of another keybinding. Parked on workspace 0 when hidden.
scratchpad_app = scratchpad_app or nil
scratchpad_open = scratchpad_open or false

-- Per-window header text drawn after the title (separated by two spaces, the
-- §7b convention): the app sets context, and the header points to the help
-- popup (F1) instead of listing key hints (e.g. "editor /wm/theme.lua |
-- help F1"). `local` here is visible across the whole concatenated shell chunk
-- (wm.lua loads first).
local win_headers = {}

local function set_window_header(title, text)
    win_headers[title] = text
end

-- Optional text cursor inside the title-bar header (glyph offset within the
-- header text; nil hides it). The editor uses it for the "save as:" prompt so
-- the cursor follows the typed path in the header instead of the body.
local win_cursors = {}

local function set_window_cursor(title, glyph_offset)
    win_cursors[title] = glyph_offset
end

local function window(title, ws)
    z_counter = z_counter + 1
    return { title = title, ws = ws, x = 0, y = 0, w = 0, h = 0, floating = false, z = z_counter }
end

-- The REPL console lives as a window so it survives focus switches.
windows[#windows + 1] = window("repl", 1)
windows[#windows + 1] = window("sysmon", 1)
local repl_visible = true

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

-- Close a window: drop it from the list and refocus the topmost window on the
-- current workspace. Shared by Super+Q, the launcher's "close" action and the
-- editor's double-Esc exit.
local function close_window(title)
    for i, w in ipairs(windows) do
        if w.title == title then table.remove(windows, i) break end
    end
    if fullscreen_win == title then exit_fullscreen() end
    -- Closing the scratchpad window resets its state, so the next Super+S
    -- picks a new application instead of toggling a gone window.
    if scratchpad_app == title then
        scratchpad_app = nil
        scratchpad_open = false
    end
    focus_topmost(current_ws)
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
            local gap = inner
            local w1, w2 = math.floor(area_w * 0.6), math.floor(area_w * 0.4)
            if n == 2 then
                -- Side by side; the focused window gets the wider split (60/40)
                -- and the positions stay stable (first window left). The rects
                -- overlap by the border width so the active window (drawn last)
                -- shows its own 2px border at the shared edge, never a gap or a
                -- double border.
                local f = (focused == w.title)
                if i == 1 then
                    w.x = area_x
                    w.y = area_y
                    w.w = (f and w1 or w2) - gap
                    w.h = area_h
                else
                    w.x = area_x + (f and w2 or w1) - gap - border
                    w.y = area_y
                    w.w = area_x + area_w - w.x
                    w.h = area_h
                end
            else
                -- Master-stack: the first window is the master (left, wider),
                -- the rest stack in the right column (spec/lua-wm.md §6.3).
                -- Neighbouring rects overlap by the border width as above.
                local stack_n = n - 1
                local row_h = math.floor((area_h + (stack_n - 1) * border) / stack_n)
                if i == 1 then
                    w.x = area_x
                    w.y = area_y
                    w.w = w1 - gap
                    w.h = area_h
                else
                    w.x = area_x + w1 - gap - border
                    w.w = area_x + area_w - w.x
                    w.y = area_y + (i - 2) * (row_h - border)
                    if i == n then
                        w.h = area_y + area_h - w.y
                    else
                        w.h = row_h
                    end
                end
            end
        else
            -- splitv: stack vertically, rows overlapping by the border width.
            local gap = inner
            local row_h = math.floor((area_h + (n - 1) * border) / n)
            w.x = area_x
            w.w = area_w
            w.y = area_y + (i - 1) * (row_h - border)
            if i == n then
                w.h = area_y + area_h - w.y
            else
                w.h = row_h
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Bar (Noctalia-style): launcher + clock + workspace capsules left,
-- volume right.
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
    -- Launcher button (a square with a double chevron, evokes "open menu").
    local bx = x
    gfx.draw_rect(bx, (bar_h - 20) // 2, 20, 20, theme.accent)
    gfx.draw_text(">>", bx + 2, (bar_h - 16) // 2 + 1, theme.background)
    x = x + 20 + 8
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
        gfx.draw_rect(c.x, (bar_h - 20) // 2, c.w, 20, color)
        gfx.draw_text(theme.ws[c.i], c.x + 4, (bar_h - 16) // 2 + 1, text_color)
    end

    -- Active window title (bar center, the Noctalia active_window widget).
    local win_label = focused or ""
    gfx.draw_text(win_label, math.floor((SW - win_label:len() * 8) / 2), (bar_h - 16) // 2 + 1, theme.text_dim)

    -- Right side: volume placeholder.
    local right = SW - 8
    local vol = "Vol 100%"
    gfx.draw_text(vol, right - vol:len() * 8, (bar_h - 16) // 2 + 1, theme.text)
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
    -- Fullscreen covers everything and is fully opaque (decorations.lua
    -- fullscreen_opacity = 1).
    if fullscreen_win == w.title then opacity = 1 end

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

    -- Title text: the window label plus its status header (two-space gap).
    -- The label keeps the window name; the header (path, dirty marker, key
    -- hints) is app-provided via set_window_header and dimmed.
    local label = w.title
    if w.title == "repl" then
        label = "~ repl"
    elseif w.title == "sysmon" then
        label = "sysmon"
    end
    local title_color = active and theme.text or theme.text_dim
    gfx.draw_text(label, tx + 6, ty + (th - 16) // 2 + 1, title_color)
    local hdr = win_headers[w.title]
    if hdr then
        -- Context (path, dirty marker) on the left, right after the label.
        local hx = tx + 6 + (label:len() + 1) * 8
        gfx.draw_text(hdr, hx, ty + (th - 16) // 2 + 1, theme.text_dim)
        local cur = win_cursors[w.title]
        if cur then
            gfx.draw_rect(hx + cur * 8, ty + (th - 16) // 2 + 1, 8, 16, theme.accent)
        end
        -- "help F1" always right-aligned at the end of the title bar, so every
        -- window points to the same help popup in the same place (no pipe, no
        -- per-window key hints — see spec/desktop-ui.md §5). It is dimmed like
        -- the rest of the header text.
        local help_x = tx + w.w - 2 * theme.wm.border - 6 - ("help F1"):len() * 8
        if help_x > hx + hdr:len() * 8 then
            gfx.draw_text("help F1", help_x, ty + (th - 16) // 2 + 1, theme.text_dim)
        end
    end
end

-- The initially focused window must also be the topmost (highest z), so its
-- active border covers the shared edge with its neighbour. set_focus() bumps
-- z; a plain `focused = windows[1].title` above would leave the first window
-- at the bottom of the z-order and the shared border would show the inactive
-- neighbour after an F5 reload.
set_focus(windows[1].title)
