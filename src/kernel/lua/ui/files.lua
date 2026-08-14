-- files.lua - minimal file browser inside a shell window (M7.1.5). Lists a
-- directory through file.dir, navigates into subdirectories and views file
-- contents through file.open/read. State is kept as globals so an F5 reload
-- does not lose the current directory.

fs_path = fs_path or "/"
fs_entries = fs_entries or {}
fs_sel = fs_sel or 1
fs_viewing = fs_viewing or false
fs_view_name = fs_view_name or ""
fs_view_content = fs_view_content or ""
fs_view_row = fs_view_row or 1
fs_view_col = fs_view_col or 0
fs_view_scroll = fs_view_scroll or 0
fs_error = fs_error or ""
fs_row_h = 18
fs_glyph_w = 8

-- Normalize a directory path: the root is "/", everything else has no
-- trailing slash. Used for display and for building child paths.
local function norm_path(p)
    if p == "" or p == "/" then return "/" end
    if p:sub(-1) == "/" then return p:sub(1, -2) end
    return p
end

-- Join a directory path and an entry name into a full path.
local function join_path(p, name)
    local base = norm_path(p)
    if base == "/" then return "/" .. name end
    return base .. "/" .. name
end

function files_open(path)
    fs_path = norm_path(path)
    fs_viewing = false
    fs_sel = 1
    local entries = file.dir(fs_path)
    if not entries then
        fs_entries = {}
        fs_error = "cannot read " .. fs_path
        gfx.invalidate()
        return
    end
    fs_error = ""
    fs_entries = entries
    gfx.invalidate()
end

function files_view(name)
    local full = join_path(fs_path, name)
    local h = file.open(full)
    if not h then
        fs_error = "cannot open " .. name
        gfx.invalidate()
        return
    end
    local content = ""
    while true do
        local chunk = file.read(h, 4096)
        if not chunk or chunk == "" then break end
        content = content .. chunk
    end
    file.close(h)
    fs_viewing = true
    fs_view_name = name
    fs_view_content = content
    fs_view_row = 1
    fs_view_col = 0
    fs_view_scroll = 0
    fs_error = ""
    gfx.invalidate()
end

-- Edit an entry in the editor window (Enter on a file). The editor window is
-- created/raised like Super+T, then loaded with the selected file.
function files_edit(name)
    local w = find_win("editor")
    if not w then
        windows[#windows + 1] = window("editor", current_ws)
    else
        w.ws = current_ws
    end
    editor_load(join_path(fs_path, name))
    set_focus("editor")
end

function files_up()
    if fs_viewing then
        fs_viewing = false
        gfx.invalidate()
        return
    end
    local t = fs_path
    if t == "/" or t == "" then return end
    if t:sub(-1) == "/" then t = t:sub(1, -2) end
    local parent = t:match("^(.*)/[^/]*$")
    if parent == nil or parent == "" then parent = "/" end
    files_open(parent)
end

-- Delete the selected file (Delete key). The system never depends on the
-- disk config: if /theme.lua and .theme.bak are gone, the built-in defaults
-- (initrd) are used, so any file can be removed freely.
function files_remove(name)
    local full = join_path(fs_path, name)
    if not file.remove(full) then
        fs_error = "cannot delete " .. name
        gfx.invalidate()
        return
    end
    -- Refresh the listing after the entry is gone.
    local was_viewing = fs_viewing
    files_open(fs_path)
    if was_viewing and fs_view_name == name then fs_viewing = false end
end

local function files_render()
    local w = find_win("files")
    if not w or w.ws ~= current_ws then return end
    local tx = w.x + theme.wm.border + 6
    local ty = w.y + theme.wm.border + theme.wm.title_h + 6
    local rows = math.floor((w.h - theme.wm.title_h - 12) / fs_row_h) - 1
    if rows < 1 then rows = 1 end
    if fs_error ~= "" then
        gfx.draw_text(fs_error, tx, ty, theme.accent)
        return
    end
    if fs_viewing then
        -- Single header: the full file path + cancel hint, like the editor
        -- status line ("/theme.lua  Esc cancel"). Clicking it exits the view.
        local header = join_path(fs_path, fs_view_name) .. "  Esc cancel"
        gfx.draw_text(header, tx, ty, theme.text_dim)
        ty = ty + fs_row_h
        local lines = {}
        for line in (fs_view_content .. "\n"):gmatch("(.-)\n") do
            lines[#lines + 1] = line
        end
        local content_rows = rows - 1
        if content_rows < 1 then content_rows = 1 end
        -- Scroll so the cursor row is always visible.
        local first = fs_view_scroll + 1
        for i = first, math.min(#lines, first + content_rows - 1) do
            gfx.draw_text(lines[i], tx, ty, theme.text)
            if i == fs_view_row then
                -- Hollow cursor (outline only) marks view mode — the solid
                -- accent block is reserved for the editor.
                gfx.rect_border(tx + fs_view_col * fs_glyph_w, ty, fs_glyph_w, 16, 1, theme.accent)
            end
            ty = ty + fs_row_h
        end
        return
    end
    -- List mode: header is the directory path (root is "/"), then the
    -- scrollable entries. Hidden files (leading dot, e.g. the .theme.bak
    -- config backup) are shown in the dim color so it is visually clear they
    -- are not regular editable files.
    gfx.draw_text(fs_path, tx, ty, theme.text_dim)
    ty = ty + fs_row_h
    local first = 1
    if fs_sel > rows then first = fs_sel - rows + 1 end
    for i = first, math.min(#fs_entries, first + rows - 1) do
        local e = fs_entries[i]
        local color
        if i == fs_sel then
            color = theme.accent
        elseif e.name:sub(1, 1) == "." then
            color = theme.text_dim
        else
            color = theme.text
        end
        local label = e.name
        if e.dir then label = label .. "/" end
        gfx.draw_text(label, tx, ty, color)
        ty = ty + fs_row_h
    end
end
