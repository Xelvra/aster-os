-- input.lua - mouse and keyboard handling for the shell.

-- Double-Esc (Esc Esc) exits the files view mode back to the listing —
-- a single Esc is the "are you sure" press, the second one leaves the view.
-- Only applies to file viewing; window close stays Super+Q (Hyprland).
local esc_pending = false

local function is_in_header(w)
    local mx = input.mouse_x()
    local my = input.mouse_y()
    -- The title bar starts below the border and spans title_h rows; the
    -- border itself is not part of the draggable header.
    return mx >= w.x and mx <= w.x + w.w and
           my >= w.y + theme.wm.border and my <= w.y + theme.wm.border + theme.wm.title_h
end

local function is_in_window(w)
    if w.ws ~= current_ws then return false end
    local mx = input.mouse_x()
    local my = input.mouse_y()
    return mx >= w.x and mx <= w.x + w.w and my >= w.y and my <= w.y + w.h
end

local function handle_mouse()
    local mx = input.mouse_x()
    local my = input.mouse_y()
    local left = input.mouse_left()

    if launcher_open then
        if left and not mouse_was_down then
            -- Clicking an item runs it; click outside closes. Help switches to
            -- the cheat sheet instead of closing the launcher.
            if launcher_mode == "help" then
                mouse_was_down = left
                return
            end
            local items = launcher_filtered()
            local row_h = 20
            local lw, lh = 320, 40 + math.max(#items, 1) * row_h
            local lx = math.floor((SW - lw) / 2)
            local ly = theme.bar.height + 8 + math.max(math.floor((SH - theme.bar.height - 8 - lh) / 2), 0)
            if mx >= lx and mx <= lx + lw and my >= ly and my <= ly + lh then
                local idx = math.floor((my - ly - 30) / row_h) + 1
                if items[idx] then
                    launcher_run(items[idx].id)
                    if launcher_mode ~= "help" then launcher_open = false end
                    gfx.invalidate()
                end
            else
                launcher_open = false
                gfx.invalidate()
            end
        end
        mouse_was_down = left
        return
    end

    if left then
        if not mouse_was_down then
            -- Find window under the cursor (topmost first).
            for i = #windows, 1, -1 do
                local w = windows[i]
                if is_in_window(w) then
                    set_focus(w.title)
                    -- Only floating windows can be dragged; a click on a
                    -- tiled window's header only focuses it.
                    if is_in_header(w) and w.floating then
                        drag = { title = w.title, dx = mx - w.x, dy = my - w.y }
                    end
                    break
                end
            end
            -- Clicking a workspace capsule switches workspace and focuses its
            -- topmost window, so typing works right away.
            for _, c in ipairs(ws_capsules()) do
                if mx >= c.x and mx <= c.x + c.w and my >= 0 and my <= theme.bar.height then
                    current_ws = c.i
                    focus_topmost(c.i)
                    layout_pass()
                    gfx.invalidate()
                end
            end
            -- Clicking the files title bar (the path header) navigates up one
            -- level — or exits the current view — the header mirrors the path.
            local fw = find_win("files")
            if fw and fw.ws == current_ws then
                local hy = fw.y + theme.wm.border
                if mx >= fw.x + theme.wm.border and mx <= fw.x + fw.w - theme.wm.border and
                   my >= hy and my <= hy + theme.wm.title_h then
                    files_up()
                    gfx.invalidate()
                end
            end
            -- Clicking an entry in the files listing opens it: a directory is
            -- entered, a file is edited (same as Enter). Clicking the header
            -- above already handled going up.
            if fw and fw.ws == current_ws and not fs_viewing then
                local rows = math.max(math.floor((fw.h - theme.wm.title_h - 12) / fs_row_h), 1)
                local list_ty = fw.y + theme.wm.border + theme.wm.title_h + 6
                if my >= list_ty then
                    local row = math.floor((my - list_ty) / fs_row_h) + 1
                    local scroll_offset = math.max(fs_sel - rows, 0)
                    local e = fs_entries[scroll_offset + row]
                    if e then
                        if e.dir then
                            files_open(join_path(fs_path, e.name))
                        else
                            files_edit(e.name)
                        end
                        gfx.invalidate()
                    end
                end
            end
            -- Clicking the launcher button (the ">" chevron) opens the launcher.
            if mx >= 8 and mx <= 28 and my >= 0 and my <= theme.bar.height then
                launcher_open_mode("run")
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
    mouse_was_down = left
end

local function handle_key(ev)
    local code = ev.code
    if launcher_open then
        -- Help mode: Esc closes the launcher entirely; no typing/navigation.
        if launcher_mode == "help" then
            if code == "escape" then
                launcher_open = false
            end
            gfx.invalidate()
            return
        end
        local items = launcher_filtered()
        -- Keep the selection valid after filtering changed the list size.
        launcher_sel = math.max(1, math.min(launcher_sel, math.max(#items, 1)))
        if code == "escape" then
            launcher_open = false
            esc_pending = false
        elseif code == "enter" then
            if items[launcher_sel] then launcher_run(items[launcher_sel].id) end
            if launcher_mode ~= "help" then launcher_open = false end
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
    --   Super+T         editor (untitled buffer)
    --   Super+Z         settings (/theme.lua)
    --   Super+E         file manager
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
            focus_topmost(1)
        elseif code == "digit_2" then
            current_ws = 2
            focus_topmost(2)
        elseif code == "digit_3" then
            current_ws = 3
            focus_topmost(3)
        elseif code == "enter" then
            -- Terminal: show the REPL on the current workspace and focus it.
            -- The window is recreated if it was closed (Super+Q).
            local w = find_win("repl")
            if not w then
                windows[#windows + 1] = window("repl", current_ws)
            else
                w.ws = current_ws
            end
            repl_visible = true
            set_focus("repl")
        elseif code == "t" then
            -- Editor (spec/lua-wm.md: Super+T -> editor). Super+T always
            -- starts a fresh untitled document: a clean buffer is reset to
            -- empty, a dirty buffer is kept so unsaved edits are never lost.
            local w = find_win("editor")
            if not w then
                windows[#windows + 1] = window("editor", current_ws)
            else
                w.ws = current_ws
            end
            if not ed_open or not ed_dirty then editor_load(nil) end
            set_focus("editor")
        elseif code == "z" then
            -- Settings (spec/lua-wm.md: Super+Z -> settings): the theme
            -- config lives in /theme.lua, opened in the editor.
            local w = find_win("editor")
            if not w then
                windows[#windows + 1] = window("editor", current_ws)
            else
                w.ws = current_ws
            end
            editor_load("/theme.lua")
            set_focus("editor")
        elseif code == "e" then
            -- File manager (spec/lua-wm.md: Super+E -> files), opened at root.
            local w = find_win("files")
            if not w then
                windows[#windows + 1] = window("files", current_ws)
            else
                w.ws = current_ws
            end
            files_open("/")
            set_focus("files")
        elseif code == "q" then
            if find_win(focused) then close_window(focused) end
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
                launcher_open_mode("run")
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
            -- Super+Shift+1/2/3 moves the focused window to that workspace;
            -- Super+Shift+arrows swaps it with its neighbour in the layout.
            local w = find_win(focused)
            if w then
                if code == "digit_1" or code == "digit_2" or code == "digit_3" then
                    w.ws = tonumber(code:sub(-1))
                    w.floating = false
                    w.x, w.y, w.w, w.h = 0, 0, 0, 0
                    current_ws = w.ws
                    set_focus(w.title)
                elseif code == "right" or code == "left" or code == "down" or code == "up" then
                    -- Swap the focused window with its neighbour in tiling
                    -- order on this workspace (left/up = toward the start,
                    -- right/down = toward the end).
                    local list = {}
                    for _, x in ipairs(windows) do
                        if x.ws == current_ws and not x.floating then list[#list + 1] = x end
                    end
                    local idx = nil
                    for i, x in ipairs(list) do if x.title == focused then idx = i break end end
                    if idx then
                        local nxt = idx + ((code == "right" or code == "down") and 1 or -1)
                        if nxt >= 1 and nxt <= #list then
                            local a, b = list[idx], list[nxt]
                            local ia, ib = nil, nil
                            for i, x in ipairs(windows) do
                                if x == a then ia = i elseif x == b then ib = i end
                            end
                            if ia and ib then
                                windows[ia], windows[ib] = windows[ib], windows[ia]
                            end
                        end
                    end
                end
                layout_pass()
            end
        elseif code == "left" or code == "right" or code == "up" or code == "down" then
            -- Focus in a direction among tiled windows on this workspace.
            local tiled = {}
            for _, w in ipairs(ws_windows(current_ws)) do
                if not w.floating then tiled[#tiled + 1] = w end
            end
            if #tiled > 0 then
                local idx = 1
                for i, w in ipairs(tiled) do if w.title == focused then idx = i break end end
                local dir = (code == "right" or code == "down") and 1 or -1
                local nxt = tiled[((idx - 1 + dir) % #tiled) + 1]
                if nxt then set_focus(nxt.title) end
            end
        end
        layout_pass()
        gfx.invalidate()
        return
    end

    if ev.alt and ev.pressed and code == "tab" then
        local list = ws_windows(current_ws)
        if #list > 0 then
            local idx = 1
            for i, w in ipairs(list) do if w.title == focused then idx = i break end end
            local nxt = list[(idx % #list) + 1]
            if nxt then set_focus(nxt.title) end
        end
        return
    end

    -- REPL input goes to the focused window when it is the REPL.
    if find_win(focused) and focused == "repl" and repl_visible then
        if code == "enter" then
            add_line("> " .. current)
            if current ~= "" then
                table.insert(history, current)
                repl_save_history()
            end
            run(current)
            current = ""
            cursor = 0
            hist_idx = 0
        elseif code == "backspace" then
            if cursor > 0 then
                local start = prev_cp(current, cursor)
                current = string.sub(current, 1, start) .. string.sub(current, cursor + 1)
                cursor = start
            end
        elseif code == "left" then
            cursor = prev_cp(current, cursor)
        elseif code == "right" then
            cursor = next_cp(current, cursor)
        elseif code == "up" then
            if #history > 0 then
                -- First Up shows the newest command (the one just entered);
                -- subsequent Ups walk further back.
                if hist_idx == 0 then hist_idx = #history end
                if hist_idx > 1 then hist_idx = hist_idx - 1 end
                current = history[hist_idx]
                cursor = #current
            end
        elseif code == "down" then
            if #history > 0 then
                if hist_idx == #history then
                    -- Down at the newest entry returns to the draft line.
                    hist_idx = 0
                    current = ""
                else
                    hist_idx = hist_idx + 1
                    current = history[hist_idx]
                end
                cursor = #current
            end
        elseif code == "home" then
            cursor = 0
        elseif code == "end" then
            cursor = #current
        elseif code == "delete" then
            if cursor < #current then
                local after = next_cp(current, cursor)
                current = string.sub(current, 1, cursor) .. string.sub(current, after + 1)
            end
        elseif ev.char then
            current = string.sub(current, 1, cursor) .. ev.char .. string.sub(current, cursor + 1)
            cursor = cursor + #ev.char
        end
        gfx.invalidate()
    end

    -- Editor input goes to the focused window when it is the editor.
    if focused == "editor" and find_win("editor") then
        -- Any non-Esc key cancels a pending editor exit. Esc is only a two-
        -- step exit (like the files viewer) while the buffer is clean: with
        -- unsaved changes it is blocked so edits can never be lost by it.
        if code ~= "escape" and not ed_saveas then ed_esc_pending = false end
        if ed_saveas then
            -- Save-as prompt: text edits the target path, Enter commits, Esc
            -- cancels back to the buffer. Navigation keys are disabled.
            if code == "enter" then
                editor_saveas_commit()
            elseif code == "escape" then
                editor_saveas_cancel()
            elseif code == "backspace" then
                ed_saveas_path = string.sub(ed_saveas_path, 1, -2)
                update_editor_header()
            elseif ev.char then
                ed_saveas_path = ed_saveas_path .. ev.char
                update_editor_header()
            end
            gfx.invalidate()
        elseif code == "escape" then
            if ed_dirty then
                ed_esc_pending = false
            elseif ed_esc_pending then
                close_window("editor")
                ed_esc_pending = false
            else
                ed_esc_pending = true
            end
        elseif ev.ctrl and code == "s" then
            editor_save()
        elseif code == "enter" then
            local line = ed_lines[ed_row]
            ed_lines[ed_row] = string.sub(line, 1, ed_col)
            table.insert(ed_lines, ed_row + 1, string.sub(line, ed_col + 1))
            ed_row = ed_row + 1
            ed_col = 0
            editor_touch()
        elseif code == "backspace" then
            if ed_col > 0 then
                local s = prev_cp(ed_lines[ed_row], ed_col)
                ed_lines[ed_row] = string.sub(ed_lines[ed_row], 1, s) .. string.sub(ed_lines[ed_row], ed_col + 1)
                ed_col = s
            elseif ed_row > 1 then
                local prev = ed_lines[ed_row - 1]
                ed_col = #prev
                ed_lines[ed_row - 1] = prev .. ed_lines[ed_row]
                table.remove(ed_lines, ed_row)
                ed_row = ed_row - 1
            end
            editor_touch()
        elseif code == "left" then
            ed_col = prev_cp(ed_lines[ed_row], ed_col)
        elseif code == "right" then
            ed_col = next_cp(ed_lines[ed_row], ed_col)
        elseif code == "up" then
            if ed_row > 1 then
                ed_row = ed_row - 1
                ed_col = math.min(ed_col, #ed_lines[ed_row])
            end
        elseif code == "down" then
            if ed_row < #ed_lines then
                ed_row = ed_row + 1
                ed_col = math.min(ed_col, #ed_lines[ed_row])
            end
        elseif code == "home" then
            ed_col = 0
        elseif code == "end" then
            ed_col = #ed_lines[ed_row]
        elseif code == "delete" then
            if ed_col < #ed_lines[ed_row] then
                local after = next_cp(ed_lines[ed_row], ed_col)
                ed_lines[ed_row] = string.sub(ed_lines[ed_row], 1, ed_col) .. string.sub(ed_lines[ed_row], after + 1)
            elseif ed_row < #ed_lines then
                ed_lines[ed_row] = ed_lines[ed_row] .. ed_lines[ed_row + 1]
                table.remove(ed_lines, ed_row + 1)
            end
            editor_touch()
        elseif ev.char then
            local line = ed_lines[ed_row]
            ed_lines[ed_row] = string.sub(line, 1, ed_col) .. ev.char .. string.sub(line, ed_col + 1)
            ed_col = ed_col + #ev.char
            editor_touch()
        end
        update_editor_header()
        gfx.invalidate()
    end

    -- File browser input goes to the focused window when it is the files.    -- Conventions (Aster WM, Hyprland-flavoured): up/down select; enter opens
    -- (dir = navigate in, file = edit in the editor); space = quick view of
    -- the file content; escape goes up one level / exits a view; clicking the
    -- path header also goes up.
    if focused == "files" and find_win("files") then
        if fs_viewing then
            -- View mode: navigate the hollow cursor like the editor, but with
            -- no editing. Up/Down move rows (and scroll), Left/Right columns,
            -- Home/End line ends, PgUp/PgDn page up/down. Pressing Esc twice
            -- (Esc Esc) exits back to the listing; space/enter exit at once.
            if code == "escape" then
                if esc_pending then
                    files_up()
                    esc_pending = false
                else
                    esc_pending = true
                end
            elseif code == "space" or code == "enter" then
                files_up()
                esc_pending = false
            elseif code == "up" then
                if fs_view_row > 1 then
                    fs_view_row = fs_view_row - 1
                    if fs_view_row <= fs_view_scroll then fs_view_scroll = fs_view_scroll - 1 end
                end
            elseif code == "down" then
                local lines = {}
                for line in (fs_view_content .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
                local visible = math.max(math.floor((find_win("files").h - theme.wm.title_h - 12) / fs_row_h), 1)
                if fs_view_row < #lines then
                    fs_view_row = fs_view_row + 1
                    if fs_view_row > fs_view_scroll + visible then fs_view_scroll = fs_view_scroll + 1 end
                end
            elseif code == "left" then
                if fs_view_col > 0 then fs_view_col = fs_view_col - 1 end
            elseif code == "right" then
                fs_view_col = fs_view_col + 1
            elseif code == "home" then
                fs_view_col = 0
            elseif code == "end" then
                local line = {}
                for l in (fs_view_content .. "\n"):gmatch("(.-)\n") do line[#line + 1] = l end
                if line[fs_view_row] then fs_view_col = #line[fs_view_row] end
            elseif code == "page_up" then
                local visible = math.max(math.floor((find_win("files").h - theme.wm.title_h - 12) / fs_row_h), 1)
                fs_view_row = math.max(fs_view_row - visible, 1)
                fs_view_scroll = math.max(fs_view_scroll - visible, 0)
            elseif code == "page_down" then
                local lines = {}
                for line in (fs_view_content .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
                local visible = math.max(math.floor((find_win("files").h - theme.wm.title_h - 12) / fs_row_h), 1)
                fs_view_row = math.min(fs_view_row + visible, #lines)
                fs_view_scroll = math.min(fs_view_scroll + visible, math.max(#lines - visible, 0))
            else
                -- Any other key in view mode resets the pending Esc.
                esc_pending = false
            end
        else
            if code == "up" then
                fs_sel = math.max(fs_sel - 1, 1)
            elseif code == "down" then
                fs_sel = math.min(fs_sel + 1, math.max(#fs_entries, 1))
            elseif code == "enter" then
                local e = fs_entries[fs_sel]
                if e then
                    if e.dir then
                        files_open(join_path(fs_path, e.name))
                    else
                        files_edit(e.name)
                    end
                end
            elseif code == "space" then
                local e = fs_entries[fs_sel]
                if e and not e.dir then files_view(e.name) end
            elseif code == "delete" then
                local e = fs_entries[fs_sel]
                if e then files_remove(e.name) end
            elseif code == "escape" then
                files_up()
                esc_pending = false
            end
        end
        gfx.invalidate()
    end
end
