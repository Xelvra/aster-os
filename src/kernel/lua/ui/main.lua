-- main.lua - update/render entry points called by the kernel. Concatenated
-- after the other ui modules, so all their local state is in scope.

function update()
    if locked then
        -- Locked: ignore the mouse, any key unlocks (no auth yet).
        local ev = input.next_event()
        if ev and ev.type == "key" and ev.pressed then
            locked = false
            gfx.invalidate()
        end
        return
    end
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
    if locked then
        gfx.fill_screen(0x000000)
        gfx.draw_text("press any key to unlock", math.floor((SW - 23 * 8) / 2), math.floor(SH / 2), theme.text_dim)
        return
    end
    gfx.fill_screen(theme.background)
    layout_pass()
    bar_render()
    -- Fullscreen: only the fullscreen window is drawn (it covers everything);
    -- the bar is skipped by bar_render, and no other window is rendered.
    if fullscreen_win then
        local fs = find_win(fullscreen_win)
        if fs and fs.ws == current_ws then
            win_render(fs)
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
    if launcher_open then launcher_render() end
    if session_open then session_menu_render() end
end
