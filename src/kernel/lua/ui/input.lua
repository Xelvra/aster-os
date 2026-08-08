-- input.lua - mouse and keyboard handling for the shell.

local session_was_down = false

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

local function handle_mouse()
    local mx = input.mouse_x()
    local my = input.mouse_y()
    local left = input.mouse_left()

    if session_open then
        if left and not session_was_down then
            -- Clicking an item runs it; click outside closes.
            local row_h = 20
            local w, h = 140, 8 + #session_items * row_h
            local x, y = session_btn.x, theme.bar.height + 2
            if mx >= x and mx <= x + w and my >= y and my <= y + h then
                local idx = math.floor((my - y - 4) / row_h) + 1
                session_open = false
                if session_items[idx] then session_run(session_items[idx].id) end
            else
                session_open = false
            end
            gfx.invalidate()
        end
        session_was_down = left
        return
    end

    if launcher_open then
        if left and not launcher_was_down then
            -- Clicking an item runs it; click outside closes.
            local items = launcher_filtered()
            local row_h = 20
            local lw, lh = 320, 40 + math.max(#items, 1) * row_h
            local lx = math.floor((SW - lw) / 2)
            local ly = theme.bar.height + 8 + math.max(math.floor((SH - theme.bar.height - 8 - lh) / 2), 0)
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
                if mx >= x and mx <= x + ww and my >= 0 and my <= theme.bar.height then
                    current_ws = i
                    layout_pass()
                    gfx.invalidate()
                end
                x = x + ww + 6
            end
            -- Clicking the session button opens the session menu.
            if mx >= session_btn.x and mx <= session_btn.x + session_btn.w and my >= 0 and my <= theme.bar.height then
                session_open = true
                session_sel = 1
                gfx.invalidate()
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
    if session_open then
        if code == "escape" then
            session_open = false
        elseif code == "enter" then
            session_open = false
            session_run(session_items[session_sel].id)
        elseif code == "up" then
            session_sel = math.max(session_sel - 1, 1)
        elseif code == "down" then
            session_sel = math.min(session_sel + 1, #session_items)
        else
            session_open = false
        end
        gfx.invalidate()
        return
    end

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
