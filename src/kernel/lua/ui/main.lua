-- main.lua - update/render entry points called by the kernel. Concatenated
-- after the other ui modules, so all their local state is in scope.

-- Apply the persistent disk config once the whole shell (incl. repl print)
-- is loaded. Any config error is reported in the REPL scrollback, so a
-- broken /wm/theme.lua is visible after boot and after F5.
local config_error = apply_disk_theme()
if config_error then
    wm_error("theme", config_error)
end

-- Restore the persistent REPL command history (/.repl_history), so Up/Down
-- recall commands across F5 reloads and reboots.
repl_load_history()

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

-- Draw the content of a window whose frame was just rendered. Every content
-- function resolves its own window (find_win) and returns early when the
-- window is absent or on another workspace, so calling it per-window in
-- z-order keeps each content on top of the windows below it (a stacked window
-- must not show through the one above).
local function render_window_content(title)
    if title == "repl" and repl_visible then
        repl_render()
    elseif title == "sysmon" then
        sysmon_render()
    elseif title == "editor" then
        editor_render()
    elseif title == "files" then
        files_render()
    end
end

-- Draw a window frame and its content together, so content cannot leak out
-- of z-order (a lower window's text must never paint over a higher one).
local function render_window(w)
    win_render(w)
    render_window_content(w.title)
end

function render()
    gfx.fill_screen(theme.background)
    layout_pass()
    bar_render()
    -- Fullscreen: only the fullscreen window is drawn (it covers everything);
    -- the bar is skipped by bar_render, and no other window is rendered. The
    -- window's content (REPL prompt, sysmon) is still drawn. An open
    -- scratchpad (Super+S) is drawn on top of the fullscreen window.
    if fullscreen_win then
        local fs = find_win(fullscreen_win)
        if fs and fs.ws == current_ws then
            render_window(fs)
            if scratchpad_open then
                local sp = find_win("repl")
                if sp then render_window(sp) end
            end
            return
        else
            fullscreen_win = nil
        end
    end
    -- Draw windows bottom-to-top by z (tiling order first, floating on top).
    local tiled, floating = {}, {}
    for _, w in ipairs(windows) do
        if w.ws == current_ws then
            if w.floating then floating[#floating + 1] = w else tiled[#tiled + 1] = w end
        end
    end
    table.sort(tiled, function(a, b) return a.z < b.z end)
    table.sort(floating, function(a, b) return a.z < b.z end)
    for _, w in ipairs(tiled) do render_window(w) end
    for _, w in ipairs(floating) do render_window(w) end
    if launcher_open then launcher_render() end
end
