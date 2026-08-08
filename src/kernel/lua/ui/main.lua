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
    if session_open then session_menu_render() end
end
