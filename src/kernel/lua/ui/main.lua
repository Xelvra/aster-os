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

-- Per-application contextual help (F1 inside a window shows that app's
-- keys). Each entry: { key, description, alt }; alt is the F-key duality.
-- A string entry is a section heading (e.g. view mode of the file manager).
register_app_help("files", {
    "listing",
    { "Arrow up / down", "select entry" },
    { "Enter / F4", "edit file" },
    { "Shift+F4", "new file (editor)" },
    { "Space / F3", "view file" },
    { "F2", "rename entry" },
    { "Delete", "move to trash" },
    { "Ctrl+Delete", "empty trash (in /.trash)" },
    { "Ctrl+H", "toggle hidden files" },
    { "Esc", "up a level" },
    { "click entry", "open (dir enter / file edit)" },
    { "click /..", "up a level" },
    "view mode",
    { "Arrow up / down", "move row" },
    { "Arrow left / right", "move column" },
    { "Home / End", "line start / end" },
    { "Page Up / Page Down", "page scroll" },
    { "Space / Enter", "exit view" },
    { "Esc Esc", "exit view" },
    { "Super+F1", "global help" },
})
register_app_help("editor", {
    { "mouse wheel", "scroll view" },
    { "click in text", "place cursor" },
    { "Ctrl+S", "save" },
    { "F2", "save as" },
    { "Esc Esc", "close editor" },
    { "Esc", "confirm close (clean buffer)" },
    "save-as prompt",
    { "Enter", "confirm path" },
    { "Esc", "cancel, back to buffer" },
    { "Super+F1", "global help" },
})
register_app_help("repl", {
    { "Enter", "run code" },
    { "Arrow up / down", "command history" },
    { "Arrow left / right", "move cursor" },
    { "Home / End", "line start / end" },
    { "Backspace / Delete", "delete char" },
    { "Super+F1", "global help" },
})

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
    if title == "repl" then
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
    -- window's content (REPL prompt, sysmon) is still drawn. An open scratchpad
    -- (Super+S) is drawn on top of the fullscreen window.
    if fullscreen_win then
        local fs = find_win(fullscreen_win)
        if fs and fs.ws == current_ws then
            render_window(fs)
            if scratchpad_open and scratchpad_app then
                local sp = find_win(scratchpad_app)
                if sp then render_window(sp) end
            end
            -- The launcher (and its help popup via F1) is an overlay that must
            -- stay visible over a fullscreen window too.
            if launcher_open then launcher_render() end
            return
        else
            -- The fullscreen window is gone or on another workspace: leave
            -- fullscreen through the shared path (clears the restore geometry
            -- too; audit 2026-08-15).
            exit_fullscreen()
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
