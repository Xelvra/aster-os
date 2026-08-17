-- input.lua - mouse and keyboard handling for the shell.

-- Double-Esc (Esc Esc) exits the files view mode back to the listing —
-- a single Esc is the "are you sure" press, the second one leaves the view.
-- Only applies to file viewing; window close stays Super+Q (Hyprland).
local esc_pending = false

-- Double-click on a window's title bar toggles fullscreen (standard WM
-- gesture). Two fresh clicks on the title bar within `double_click_ms` at
-- nearly the same spot count as a double-click. time.ms() is real wall-clock
-- milliseconds (PIT-calibrated), independent of the APIC tick rate, so the
-- threshold works on any machine / in QEMU.
local double_click_ms = 300
-- Sentinel in the far past so the very first title-bar click (or a click
-- right after a consumed double-click) can never be a false double-click.
local last_title_click = { t = -math.huge, x = 0, y = 0 }

-- Switch to another workspace (Super+1/2/3 and the bar capsules). Clearing a
-- fullscreen window that belongs to a different workspace is done here, not
-- left to the render path as a side effect, so the state is always coherent.
local function switch_workspace(ws)
    -- The workspace count comes from theme.ws, so a hardcoded Super+digit
    -- must never reach past it (2026-08-15-self-audit: unbounded index).
    if ws < 1 or ws > #theme.ws then return end
    current_ws = ws
    local fs = find_win(fullscreen_win or "")
    if fs and fs.ws ~= ws then exit_fullscreen() end
    focus_topmost(ws)
    layout_pass()
    gfx.invalidate()
end

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

-- Open the help that F1 would: the focused app's own cheat sheet (files,
-- editor, repl) inside a window, the global WM help elsewhere. Shared by the
-- F1 key and a click on the bar's "Help F1" hint, so both always agree.
local function open_contextual_help()
    if find_win(focused) and (focused == "files" or focused == "editor" or focused == "repl") then
        launcher_open_app_help(focused)
    else
        launcher_open_mode("help")
    end
end

local function handle_mouse()
    local mx = input.mouse_x()
    local my = input.mouse_y()
    local left = input.mouse_left()
    -- Wheel is an edge (drained per read); read it every frame so a scroll
    -- while another window is focused cannot leak into the editor later.
    local wheel = input.mouse_wheel()

    if launcher_open then
        if left and not mouse_was_down then
            -- The close "x" (top-right of the popup) closes the launcher by
            -- mouse, so the help sheet never forces an Esc.
            local cr = launcher_close_rect()
            if mx >= cr.x and mx <= cr.x + cr.w and my >= cr.y and my <= cr.y + cr.h then
                launcher_open = false
                gfx.invalidate()
                mouse_was_down = left
                return
            end
            -- Clicking an item runs it; click outside closes. Help switches to
            -- the cheat sheet instead of closing the launcher.
            if launcher_mode == "help" then
                mouse_was_down = left
                return
            end
            -- Cheat sheets never close on an item click (they are not item
            -- lists); only run mode maps a row to an app/action. A click on
            -- the popup header/padding keeps the launcher open; only a click
            -- outside the popup closes it.
            local idx = launcher_item_at(my)
            if idx then
                local items = launcher_filtered()
                if items[idx] then
                    launcher_run(items[idx].id)
                    -- Clicking "help" switches to the cheat sheet instead of
                    -- closing, exactly like the Enter key (the mouse path must
                    -- not diverge from the keyboard one).
                    if launcher_mode ~= "help" then launcher_open = false end
                    gfx.invalidate()
                end
            else
                local lx, ly, lw, lh = launcher_popup()
                if mx < lx or mx > lx + lw or my < ly or my > ly + lh then
                    launcher_open = false
                    gfx.invalidate()
                end
            end
        end
        mouse_was_down = left
        return
    end

    -- Mouse wheel: scroll the focused editor's viewport (GUI-editor
    -- convention — the text caret does not follow the wheel); in the files
    -- view mode it scrolls the viewed content the same way.
    if wheel ~= 0 then
        if focused == "editor" and find_win("editor") then
            editor_wheel(wheel)
            gfx.invalidate()
        elseif focused == "files" and find_win("files") and fs_viewing then
            files_view_wheel(wheel)
            gfx.invalidate()
        end
    end

    if left then
        if not mouse_was_down then
            -- Find the window under the cursor: the visible (highest z) window
            -- first. The windows list is the tiling order, not the z-order
            -- (set_focus bumps z without reordering it), so a floating window
            -- overlapping a later tiled one would be mis-hit without the sort
            -- (2026-08-15-self-audit).
            local z_order = {}
            for _, w in ipairs(windows) do
                if w.ws == current_ws then z_order[#z_order + 1] = w end
            end
            table.sort(z_order, function(a, b) return a.z > b.z end)
            for _, w in ipairs(z_order) do
                if is_in_window(w) then
                    -- The close "x" is drawn only on the focused window and
                    -- only when a long header does not collide, so the hit
                    -- test must match the drawn button exactly.
                    local was_focused = (w.title == focused)
                    set_focus(w.title)
                    local cb = close_button_rect(w)
                    if was_focused and cb.x > header_content_end(w) and mx >= cb.x and mx <= cb.x + cb.w and my >= cb.y and my <= cb.y + cb.h then
                        close_window(w.title)
                        gfx.invalidate()
                        -- Consume the click: without this, the held button is
                        -- re-processed next frame — after the tiled neighbour
                        -- expands into the freed space, the cursor would land
                        -- on its close "x" and close that window too.
                        mouse_was_down = left
                        return
                    end
                    -- Double-click on the title bar toggles fullscreen for
                    -- every window, including files (its title bar is no
                    -- longer a navigation target — the ".." listing entry goes
                    -- up). A single click just focuses; a floating header
                    -- still starts a drag on the first click.
                    local now = time.ms()
                    if is_in_header(w) and now - last_title_click.t <= double_click_ms
                        and math.abs(mx - last_title_click.x) <= 4
                        and math.abs(my - last_title_click.y) <= 4 then
                        last_title_click = { t = -math.huge, x = 0, y = 0 }
                        toggle_fullscreen(w.title)
                        gfx.invalidate()
                        mouse_was_down = left
                        return
                    end
                    if is_in_header(w) then
                        last_title_click = { t = now, x = mx, y = my }
                    end
                    -- Only floating windows can be dragged; a click on a
                    -- tiled window's header only focuses it.
                    if is_in_header(w) and w.floating then
                        drag = { title = w.title, dx = mx - w.x, dy = my - w.y }
                    end
                    -- A click in the editor body places the text caret; a
                    -- click in the files view mode places the hollow cursor
                    -- (foundation for the future clipboard selection). The
                    -- title bar was excluded above (header drags a floating
                    -- window, otherwise the click only focuses), and the
                    -- click handlers themselves ignore clicks outside the
                    -- body.
                    if w.title == "editor" then
                        editor_click_at(mx, my)
                        gfx.invalidate()
                    elseif w.title == "files" and fs_viewing then
                        files_view_click_at(mx, my)
                        gfx.invalidate()
                    end
                    break
                end
            end
            -- Clicking a workspace capsule switches workspace and focuses its
            -- topmost window, so typing works right away. The bar owns rows
            -- 0..bar_h-1; the first window row starts at bar_h, so the strict
            -- upper bound keeps a boundary click from hitting both the bar
            -- and a window (2026-08-15-self-audit: y == bar_h double-hit).
            for _, c in ipairs(ws_capsules()) do
                if mx >= c.x and mx <= c.x + c.w and my >= 0 and my < theme.bar.height then
                    switch_workspace(c.i)
                end
            end
            -- Clicking an entry in the files listing opens it (Enter agrees):
            -- ".." goes up, a directory is entered, a file is edited in the
            -- editor (read-only files are refused). The title bar is a plain
            -- window title now — double-click there toggles fullscreen; going
            -- up lives in the ".." listing entry and Escape.
            local fw = find_win("files")
            -- The listing click must stay inside the files window: without an
            -- x-range check, a click on a tiled neighbour (e.g. the editor on
            -- the same row) fell through to the files row under the cursor and
            -- opened whatever entry it hit (e.g. ".trash", then ".keep").
            if fw and fw.ws == current_ws and not fs_viewing
                and mx >= fw.x and mx <= fw.x + fw.w then
                local rows = math.max(math.floor((fw.h - theme.wm.title_h - 12) / fs_row_h), 1)
                local list_ty = fw.y + theme.wm.border + theme.wm.title_h + 6
                if my >= list_ty then
                    local row = math.floor((my - list_ty) / fs_row_h) + 1
                    local scroll_offset = math.max(fs_sel - rows, 0)
                    local e = fs_entries[scroll_offset + row]
                    if e then
                        files_open_entry(e)
                        gfx.invalidate()
                    end
                end
            end
            -- Clicking the launcher button (the ">" chevron) opens the launcher.
            local lbr = launcher_button_rect()
            if mx >= lbr.x and mx <= lbr.x + lbr.w and my >= 0 and my < theme.bar.height then
                launcher_open_mode("run")
                gfx.invalidate()
            end
            -- Clicking the bar's "Help F1" hint opens the contextual help
            -- (the focused window's cheat sheet, or the global WM help) —
            -- the same action as the F1 key.
            local hr = help_f1_rect()
            if mx >= hr.x and mx <= hr.x + hr.w and my >= hr.y and my < hr.y + hr.h then
                open_contextual_help()
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
    --   Super+Z         settings (/wm/theme.lua)
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
    --   Super+S         app picker (launcher run)

    -- Function keys: familiar F-key conventions as a design duality with the
    -- Hyprland Super+... shortcuts (same action, second way in). F1 (help)
    -- is global; F2 (save-as in the editor / rename in the file manager),
    -- F3 (view, like Space in files), F4 (edit) and Shift+F4 (new file,
    -- like Super+T) act on the focused window. F6..F10 and F12 are reserved;
    -- F11 is fullscreen (same as Super+F/D). Reusing a reserved key requires
    -- re-evaluating it (Hyprland reserved-slot pattern).
    if ev.pressed then
        if code == "f1" then
            -- Contextual help: F1 inside a window shows that app's own cheat
            -- sheet (files/editor/repl); F1 elsewhere shows the global WM
            -- help. Super+F1 always shows the global WM help, so any app help
            -- can point the user to it (e.g. "how do I kill the REPL?").
            if ev.super then
                launcher_open_mode("help")
            else
                open_contextual_help()
            end
            return
        elseif code == "f11" then
            -- Fullscreen toggle, same as Super+F/D.
            if find_win(focused) then toggle_fullscreen(focused) end
            return
        elseif code == "f3" and focused == "files" and find_win("files") then
            local e = fs_entries[fs_sel]
            if e and not e.dir then files_view(e.name) end
            return
        elseif code == "f2" and focused == "files" and find_win("files") then
            -- F2 in the file manager is rename (Windows/Total Commander
            -- convention); F2 in the editor stays save-as — same key, per-window
            -- action, consistent with the F-key duality (§7).
            files_rename_start()
            return
        elseif code == "f2" and focused == "editor" and find_win("editor") then
            editor_save_as()
            return
        elseif code == "f4" and ev.shift and focused == "files" and find_win("files") then
            -- Shift+F4: new file (Midnight Commander convention) — open the
            -- editor with a fresh untitled buffer; Ctrl+S then prompts save-as.
            local w = find_win("editor")
            if not w then
                windows[#windows + 1] = window("editor", current_ws)
            else
                w.ws = current_ws
            end
            if not ed_open or not ed_dirty then editor_load(nil) end
            set_focus("editor")
            return
        elseif code == "f4" and focused == "files" and find_win("files") then
            local e = fs_entries[fs_sel]
            if e and not e.dir then files_edit(e.name) end
            return
        end
    end

    if ev.super and ev.pressed then
        if not ev.shift and code == "digit_1" then
            switch_workspace(1)
        elseif not ev.shift and code == "digit_2" then
            switch_workspace(2)
        elseif not ev.shift and code == "digit_3" then
            switch_workspace(3)
        elseif code == "enter" then
            -- Terminal: show the REPL on the current workspace and focus it.
            -- The window is recreated if it was closed (Super+Q). This is a
            -- regular tiled terminal: if the REPL window was used as the
            -- scratchpad (floating), return it to the tiling layout and clear
            -- the scratchpad state, so Super+Enter never reopens a floating
            -- "always on top" terminal by accident.
            local w = find_win("repl")
            if not w then
                windows[#windows + 1] = window("repl", current_ws)
            else
                w.ws = current_ws
                if w.floating then
                    w.floating = false
                    w.x, w.y, w.w, w.h = 0, 0, 0, 0
                end
            end
            if scratchpad_app == "repl" then
                scratchpad_app = nil
                scratchpad_open = false
            end
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
            -- config lives in /wm/theme.lua, opened in the editor. Unsaved
            -- editor changes are never discarded.
            local w = find_win("editor")
            if not w then
                windows[#windows + 1] = window("editor", current_ws)
            else
                w.ws = current_ws
            end
            editor_load_safe("/wm/theme.lua")
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
                        local g = centered_rect(0.5, 0.6)
                        w.x, w.y, w.w, w.h = g.x, g.y, g.w, g.h
                    end
                end
            else
                launcher_open_mode("run")
            end
        elseif code == "f" or code == "d" then
            -- Fullscreen toggle.
            if find_win(focused) then toggle_fullscreen(focused) end
        elseif code == "j" then
            -- Toggle between side-by-side and stacked layout.
            layout_mode = (layout_mode == "splith") and "splitv" or "splith"
        elseif code == "s" then
            -- Real scratchpad (Hyprland convention): Super+S toggles a
            -- dedicated window over anything — a fullscreen window or an empty
            -- workspace. The first Super+S picks which application becomes the
            -- scratchpad; afterwards Super+S only shows/hides that window.
            -- This is a stateful toggle, not an alias of Super+Space
            -- (launcher) or Super+Alt+Space (float).
            if not scratchpad_app then
                -- Pick which application becomes the scratchpad: the launcher
                -- opens in scratchpad mode (applications only, labelled
                -- "scratchpad:"), not in run mode (which also lists actions).
                launcher_open_mode("scratchpad")
            elseif scratchpad_open then
                -- Hide: park the window off-screen (workspace 0 is never shown).
                local w = find_win(scratchpad_app)
                if w then
                    w.ws = 0
                    w.floating = false
                    w.x, w.y, w.w, w.h = 0, 0, 0, 0
                end
                scratchpad_open = false
                focus_topmost(current_ws)
            else
                -- Show: place on the current workspace, centered, floating.
                local w = find_win(scratchpad_app)
                if not w then
                    windows[#windows + 1] = window(scratchpad_app, current_ws)
                    w = windows[#windows]
                else
                    w.ws = current_ws
                end
                w.floating = true
                local g = centered_rect(0.6, 0.6)
                w.x, w.y, w.w, w.h = g.x, g.y, g.w, g.h
                scratchpad_open = true
                set_focus(scratchpad_app)
            end
        elseif ev.shift then
            -- Super+Shift+1/2/3 moves the focused window to that workspace;
            -- Super+Shift+arrows swaps it with its neighbour in the layout.
            local w = find_win(focused)
            if w then
                if code == "digit_1" or code == "digit_2" or code == "digit_3" then
                    local target = tonumber(code:sub(-1))
                    if target < 1 or target > #theme.ws then return end
                    w.ws = target
                    w.floating = false
                    w.x, w.y, w.w, w.h = 0, 0, 0, 0
                    -- Moving a fullscreen window to another workspace exits
                    -- fullscreen deterministically (it no longer covers the
                    -- current one); the render path must not clean this up
                    -- as a side effect.
                    if fullscreen_win == w.title then exit_fullscreen() end
                    -- A window that leaves the workspace can no longer be the
                    -- active scratchpad; reset the state like close_window does.
                    if scratchpad_app == w.title then
                        scratchpad_app = nil
                        scratchpad_open = false
                    end
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
            -- Floating windows are not addressed by arrows (Alt+Tab / click
            -- cycle them), so if the focused window is floating, do nothing.
            local tiled = {}
            for _, w in ipairs(ws_windows(current_ws)) do
                if not w.floating then tiled[#tiled + 1] = w end
            end
            if #tiled > 0 then
                local idx = nil
                for i, w in ipairs(tiled) do if w.title == focused then idx = i break end end
                if idx ~= nil then
                    local dir = (code == "right" or code == "down") and 1 or -1
                    local nxt = tiled[((idx - 1 + dir) % #tiled) + 1]
                    if nxt then set_focus(nxt.title) end
                end
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
    if find_win(focused) and focused == "repl" then
        if code == "enter" then
            add_line("> " .. current)
            if current ~= "" then
                -- Cap the in-memory history at history_max so a long session
                -- cannot grow it without bound (repl_save_history already
                -- caps what it writes to disk; 2026-08-15-self-audit).
                table.insert(history, current)
                if #history > history_max then table.remove(history, 1) end
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
                -- The key that closed the editor must not be processed further:
                -- focus moves to the next window here (focus_topmost inside
                -- close_window), so a trailing files/repl handler would consume
                -- this same Esc (e.g. files_up -> root) and surprise the user.
                return
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
        -- Keyboard caret movement keeps the caret row visible (the wheel
        -- scrolls the viewport independently and may leave it off-screen).
        if not ed_saveas then editor_reveal_caret() end
        update_editor_header()
        gfx.invalidate()
    end

    -- File browser input goes to the focused window when it is the files.    -- Conventions (Aster WM, Hyprland-flavoured): up/down select; enter opens
    -- (dir = navigate in, file = edit in the editor); space = quick view of
    -- the file content; escape goes up one level / exits a view; clicking the
    -- path header also goes up.
    if focused == "files" and find_win("files") then
        -- Rename mode (F2): text edits the new name in the title-bar header,
        -- Enter commits, Esc cancels. Navigation keys are disabled.
        if fs_renaming then
            if code == "enter" then
                files_rename_commit()
            elseif code == "escape" then
                files_rename_cancel()
            elseif code == "backspace" then
                fs_rename_name = string.sub(fs_rename_name, 1, -2)
                update_files_header()
            elseif ev.char then
                fs_rename_name = fs_rename_name .. ev.char
                update_files_header()
            end
            gfx.invalidate()
            return
        end
        if fs_viewing then
            -- View mode: navigate the hollow cursor like the editor, but with
            -- no editing. Up/Down move rows (and scroll), Left/Right columns,
            -- Home/End line ends, PgUp/PgDn page up/down. Pressing Esc twice
            -- (Esc Esc) exits back to the listing; space/enter exit at once.
            -- Any non-Esc key cancels a pending first Esc, so navigating after
            -- the "are you sure" press does not let the next Esc exit straight
            -- away (2026-08-15-self-audit: esc_pending was stale across keys).
            if code ~= "escape" then esc_pending = false end
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
            -- Keyboard movement keeps the hollow cursor visible (the wheel
            -- scrolls the viewport independently and may leave it off-screen).
            files_view_reveal()
        else
            if code == "up" then
                fs_sel = math.max(fs_sel - 1, 1)
            elseif code == "down" then
                fs_sel = math.min(fs_sel + 1, math.max(#fs_entries, 1))
            elseif code == "enter" then
                local e = fs_entries[fs_sel]
                if e then files_open_entry(e) end
            elseif code == "space" then
                local e = fs_entries[fs_sel]
                if e and not e.dir then files_view(e.name) end
            elseif code == "delete" and ev.ctrl then
                -- Ctrl+Delete inside /.trash empties the whole trash.
                files_empty_trash()
            elseif code == "h" and ev.ctrl then
                -- Ctrl+H toggles hidden (dot) files.
                fs_show_hidden = not fs_show_hidden
                files_open(fs_path)
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
