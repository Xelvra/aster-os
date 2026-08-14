-- main.lua - update/render entry points called by the kernel. Concatenated
-- after the other ui modules, so all their local state is in scope.

-- Apply the persistent disk config once the whole shell (incl. repl print)
-- is loaded. Any config error is reported in the REPL scrollback, so a
-- broken /theme.lua is visible after boot and after F5.
local config_error = apply_disk_theme()
if config_error then
    print("theme.lua config error: " .. config_error)
end

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
    -- Fullscreen: only the fullscreen window is drawn (it covers everything);
    -- the bar is skipped by bar_render, and no other window is rendered. The
    -- window's content (REPL prompt, sysmon) is still drawn.
    if fullscreen_win then
        local fs = find_win(fullscreen_win)
        if fs and fs.ws == current_ws then
            win_render(fs)
            if fs.title == "repl" and repl_visible then
                repl_render()
            elseif fs.title == "sysmon" then
                sysmon_render()
            elseif fs.title == "editor" then
                editor_render()
            elseif fs.title == "files" then
                files_render()
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
    for _, w in ipairs(tiled) do win_render(w) end
    for _, w in ipairs(floating) do win_render(w) end
    if repl_visible then repl_render() end
    sysmon_render()
    editor_render()
    files_render()
    if launcher_open then launcher_render() end
end
