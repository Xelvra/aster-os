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
fs_view_scroll_col = fs_view_scroll_col or 0
fs_renaming = fs_renaming or false
fs_rename_orig = fs_rename_orig or ""
fs_rename_name = fs_rename_name or ""
-- Show hidden (dot) files; Ctrl+H toggles.
fs_show_hidden = fs_show_hidden or true
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

-- Window title-bar header: the current path (or full file path while viewing)
-- on the left; no key hints are stored here (help F1 lives in the bar, §7b).
-- The path doubles as the click-to-go-up pointer.
local function update_files_header()
    if fs_renaming then
        set_window_header("files", "rename: " .. fs_rename_name)
        -- The text cursor lives in the title-bar header, following the typed
        -- name (same pattern as the editor's save-as prompt).
        set_window_cursor("files", #"rename: " + #fs_rename_name)
    elseif fs_viewing then
        set_window_header("files", join_path(fs_path, fs_view_name))
        set_window_cursor("files", nil)
    else
        set_window_header("files", fs_path)
        set_window_cursor("files", nil)
    end
end

-- Read and sort a directory listing: the ext2 `lost+found` directory always
-- comes first, then directories, then files; each group alphabetically by
-- name. ext2 returns direntries in on-disk order, which is not user-facing.
-- Hidden (dot) files are filtered out unless fs_show_hidden is set (Ctrl+H).
-- Returns nil when the directory cannot be read.
local function load_listing(path)
    local entries = file.dir(path)
    if not entries then return nil end
    local shown = {}
    for _, e in ipairs(entries) do
        if fs_show_hidden or e.name:sub(1, 1) ~= "." then
            shown[#shown + 1] = e
        end
    end
    table.sort(shown, function(a, b)
        local a_lf = a.name == "lost+found"
        local b_lf = b.name == "lost+found"
        if a_lf ~= b_lf then return a_lf end
        if a.dir ~= b.dir then return a.dir end
        return a.name < b.name
    end)
    return shown
end

function files_open(path)
    fs_path = norm_path(path)
    fs_viewing = false
    fs_sel = 1
    local entries = load_listing(fs_path)
    if not entries then
        fs_entries = {}
        wm_error("files", "cannot read " .. fs_path)
        update_files_header()
        gfx.invalidate()
        return
    end
    fs_entries = entries
    update_files_header()
    gfx.invalidate()
end

-- Re-read the current directory without leaving a view or the rename prompt,
-- keeping the selection. Called when the editor saves a file into the shown
-- directory (e.g. save-as), so a new entry appears immediately instead of on
-- the next navigation.
function files_refresh()
    if fs_viewing or fs_renaming then return end
    local w = find_win("files")
    if not w or w.ws ~= current_ws then return end
    local entries = load_listing(fs_path)
    if not entries then return end
    local was_idx = fs_sel
    fs_entries = entries
    fs_sel = math.max(1, math.min(was_idx, #fs_entries))
    update_files_header()
    gfx.invalidate()
end

function files_view(name)
    local full = join_path(fs_path, name)
    local h = file.open(full)
    if not h then
        wm_error("files", "cannot open " .. name)
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
    fs_view_scroll_col = 0
    update_files_header()
    gfx.invalidate()
end

-- Edit an entry in the editor window (Enter on a file). The editor window is
-- created/raised like Super+T, then loaded with the selected file. Unsaved
-- editor changes are never discarded (editor_load_safe).
function files_edit(name)
    local w = find_win("editor")
    if not w then
        windows[#windows + 1] = window("editor", current_ws)
    else
        w.ws = current_ws
    end
    if not editor_load_safe(join_path(fs_path, name)) then return end
    set_focus("editor")
end

function files_up()
    if fs_viewing then
        fs_viewing = false
        update_files_header()
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

-- Files the editor refuses to overwrite: read-only. Matched by name so it
-- works wherever they live — every `*.bak` backup (basename + .bak, e.g.
-- .theme.bak and .api.bak from theme.lua/api.lua, .test.bak from test.lua —
-- never "theme.lua.bak"/"api.lua.bak", ADR-025) plus
-- the persistent /.repl_history. They are red in the browser, deletable, but
-- never editable — only viewable.
local function is_read_only(name)
    return name:sub(-4) == ".bak" or name == ".repl_history"
end

-- System directories that must never be deleted, moved or renamed: the trash
-- itself (moving /.trash into itself makes no sense) and ext2's lost+found
-- (fsck scratch space). Matched by name (they only exist at the root).
local function is_protected(name)
    return name == ".trash" or name == "lost+found"
end

-- Delete the selected entry (Delete key). Outside the trash this MOVES the
-- file into /.trash (ext2 rename — no data copy, the trash is the undo zone);
-- inside /.trash it permanently deletes the selected item. Ctrl+Delete empties
-- the whole trash. The system never depends on the disk config: if
-- /wm/theme.lua and /wm/.theme.bak are gone, the built-in defaults (initrd)
-- are used, so any file can be moved/removed freely.
function files_remove(name)
    if is_protected(name) then
        wm_error("files", name .. " is protected")
        gfx.invalidate()
        return
    end
    local full = join_path(fs_path, name)
    local removed
    if fs_path == "/.trash" then
        removed = file.remove(full)
    else
        removed = file.rename(full, "/.trash/" .. name)
        if not removed then
            wm_error("files", "cannot move " .. name .. " to trash (name in use?)")
            gfx.invalidate()
            return
        end
    end
    if not removed then
        wm_error("files", "cannot delete " .. name)
        gfx.invalidate()
        return
    end
    -- Refresh the listing after the entry is gone, keeping the selection
    -- roughly at the removed row (clamped to the new list length) so deleting
    -- several files in a row does not jump the cursor back to the top.
    local removed_idx = fs_sel
    local was_viewing = fs_viewing
    files_open(fs_path)
    fs_sel = math.max(1, math.min(removed_idx, #fs_entries))
    if was_viewing and fs_view_name == name then fs_viewing = false end
end

-- Empty the whole trash (Ctrl+Delete inside /.trash): permanently remove every
-- entry in the current listing.
function files_empty_trash()
    if fs_path ~= "/.trash" then return end
    for _, e in ipairs(fs_entries) do
        file.remove(join_path(fs_path, e.name))
    end
    files_open(fs_path)
end

-- F2: rename the selected entry. The title-bar header turns into a
-- "rename: <name>" prompt (text cursor follows); Enter commits, Esc cancels.
-- Renaming a file relinks its inode under the new name (file.rename) — the
-- old name disappears, nothing is copied. Read-only files are refused, like
-- the editor refuses to load them.
function files_rename_start()
    if fs_renaming or fs_viewing then return end
    local e = fs_entries[fs_sel]
    if not e then return end
    if is_protected(e.name) then
        wm_error("files", e.name .. " is protected")
        gfx.invalidate()
        return
    end
    if is_read_only(e.name) then
        wm_error("files", e.name .. " is read-only (view with Space)")
        gfx.invalidate()
        return
    end
    fs_renaming = true
    fs_rename_orig = e.name
    fs_rename_name = e.name
    update_files_header()
    gfx.invalidate()
end

function files_rename_cancel()
    fs_renaming = false
    update_files_header()
    gfx.invalidate()
end

-- Commit the rename prompt (Enter): rename within the current directory and
-- refresh the listing, keeping the selection on the renamed entry. A name
-- equal to the original just leaves the prompt.
function files_rename_commit()
    local name = fs_rename_name
    local orig = fs_rename_orig
    if name == "" then
        wm_error("files", "name cannot be empty")
        gfx.invalidate()
        return
    end
    if name == "." or name == ".." or name:find("/") then
        wm_error("files", "invalid name")
        gfx.invalidate()
        return
    end
    if name == orig then
        fs_renaming = false
        update_files_header()
        gfx.invalidate()
        return
    end
    if not file.rename(join_path(fs_path, orig), join_path(fs_path, name)) then
        wm_error("files", "cannot rename " .. orig .. " (name already in use?)")
        gfx.invalidate()
        return
    end
    fs_renaming = false
    local was_idx = fs_sel
    files_open(fs_path)
    local found = false
    for i, e in ipairs(fs_entries) do
        if e.name == name then
            fs_sel = i
            found = true
            break
        end
    end
    if not found then fs_sel = math.max(1, math.min(was_idx, #fs_entries)) end
end

-- Entry text color: selection highlight first, then read-only red, then the
-- trash (the /.trash directory and everything inside it) in blue, then hidden
-- files dim, regular files normal.
local function entry_color(e, selected)
    if selected then return theme.accent end
    if is_read_only(e.name) then return theme.red end
    if fs_path == "/.trash" or (fs_path == "/" and e.name == ".trash") then return theme.trash end
    if e.name:sub(1, 1) == "." then return theme.text_dim end
    return theme.text
end

local function files_render()
    local w = find_win("files")
    if not w or w.ws ~= current_ws then return end
    local tx = w.x + theme.wm.border + 6
    local ty = w.y + theme.wm.border + theme.wm.title_h + 6
    local rows = math.floor((w.h - theme.wm.title_h - 12) / fs_row_h)
    if rows < 1 then rows = 1 end
    if fs_viewing then
        -- The full path + cancel hint live in the window title bar (header);
        -- the content area is pure file content with a hollow cursor marking
        -- read-only viewing.
        local lines = {}
        for line in (fs_view_content .. "\n"):gmatch("(.-)\n") do
            lines[#lines + 1] = line
        end
        local content_rows = rows
        if content_rows < 1 then content_rows = 1 end
        local max_chars = math.max(math.floor((w.w - 2 * theme.wm.border - 12) / fs_glyph_w), 1)
        -- Keep the cursor visible horizontally (code-point aware, so a UTF-8
        -- sequence is never split; audit 2026-08-15).
        if fs_view_col < fs_view_scroll_col then
            fs_view_scroll_col = fs_view_col
        elseif cp_count(lines[fs_view_row], fs_view_scroll_col, fs_view_col) >= max_chars then
            local target = fs_view_col
            for _ = 1, max_chars - 1 do
                if target == 0 then break end
                target = prev_cp(lines[fs_view_row], target)
            end
            fs_view_scroll_col = target
        end
        -- Scroll so the cursor row is always visible. Rows are always capped
        -- to the window width by code points so a long line cannot bleed over
        -- a neighbour (audit 2026-08-15).
        local first = fs_view_scroll + 1
        for i = first, math.min(#lines, first + content_rows - 1) do
            local shown
            if i == fs_view_row then
                shown = cp_slice(lines[i], fs_view_scroll_col, max_chars)
            else
                shown = cp_slice(lines[i], 0, max_chars)
            end
            gfx.draw_text(shown, tx, ty, theme.text)
            if i == fs_view_row then
                -- Hollow cursor (outline only) marks view mode — the solid
                -- accent block is reserved for the editor.
                gfx.rect_border(tx + cp_count(lines[i], fs_view_scroll_col, fs_view_col) * fs_glyph_w, ty, fs_glyph_w, 16, 1, theme.accent)
            end
            ty = ty + fs_row_h
        end
        return
    end
    -- List mode: the path lives in the window title bar (header), the scrollable
    -- entries follow. Read-only files (.theme.bak, .repl_history) are red so it
    -- is clear they cannot be edited; other hidden files are dim.
    local first = 1
    if fs_sel > rows then first = fs_sel - rows + 1 end
    for i = first, math.min(#fs_entries, first + rows - 1) do
        local e = fs_entries[i]
        local color = entry_color(e, i == fs_sel)
        local label = e.name
        if e.dir then label = label .. "/" end
        gfx.draw_text(label, tx, ty, color)
        ty = ty + fs_row_h
    end
end
