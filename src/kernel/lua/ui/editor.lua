-- editor.lua - minimal in-memory file editor inside a shell window (M7.1.5).
-- Loads a file through the file.* bindings, edits it with the keyboard and
-- saves on ctrl+s. State is kept as globals so an F5 reload does not lose
-- the buffer.

-- Super+T opens a fresh (untitled) buffer; Super+Z opens the settings file
-- /theme.lua. A buffer without a path saves through the "save as:" prompt.
ed_path = ed_path or nil
ed_lines = ed_lines or { "" }
ed_row = ed_row or 1
ed_col = ed_col or 0
ed_scroll_col = ed_scroll_col or 0
ed_dirty = ed_dirty or false
ed_open = ed_open or false
ed_saveas = ed_saveas or false
ed_saveas_path = ed_saveas_path or ""
ed_esc_pending = ed_esc_pending or false
ed_glyph_w = 8
ed_row_h = 18

-- Header text shown in the window title bar (two-space-separated segments).
-- A new/untitled buffer reads as "untitled", the dirty marker is a suffix on
-- the save hint ("Ctrl+s save*") while there are unsaved changes, and the
-- save-as prompt replaces the path and hint while it is active.
local function editor_header()
    if ed_saveas then
        return "save as: " .. ed_saveas_path .. "  Enter save  Esc cancel"
    end
    local path = ed_path or "untitled"
    return path .. "  Ctrl+s save" .. (ed_dirty and "*" or "")
end

local function update_editor_header()
    set_window_header("editor", editor_header())
end

function editor_load(path)
    ed_saveas = false
    ed_saveas_path = ""
    ed_open = true
    ed_path = path
    ed_row = 1
    ed_col = 0
    ed_scroll_col = 0
    ed_dirty = false
    if path == nil or path == "" then
        ed_lines = { "" }
        update_editor_header()
        gfx.invalidate()
        return
    end
    local h = file.open(path)
    if not h then
        ed_lines = { "file.open failed: " .. path }
        update_editor_header()
        gfx.invalidate()
        return
    end
    -- Read the whole file (loop until EOF: file.read returns "" at EOF).
    local content = ""
    while true do
        local chunk = file.read(h, 4096)
        if not chunk or chunk == "" then break end
        content = content .. chunk
    end
    file.close(h)
    -- Split into lines; a trailing newline must not add an empty line.
    local body = content
    if body:sub(-1) == "\n" then body = body:sub(1, -2) end
    local t = {}
    for line in (body .. "\n"):gmatch("(.-)\n") do
        t[#t + 1] = line
    end
    if #t == 0 then t = { "" } end
    ed_lines = t
    update_editor_header()
    gfx.invalidate()
end

-- Persist `content` to `path`. /theme.lua is validated live and refreshes the
-- .theme.bak backup (a broken config is still written to the working copy, but
-- the backup keeps the last valid look). Any other path is a plain rewrite; a
-- missing file is created (ext2 create). Returns nil on success or an error.
local function editor_write(path, content)
    if path == "/theme.lua" then
        local err = apply_theme_content(content)
        local h = file.open(path)
        if h then
            file.truncate(h, 0)
            file.write(h, content)
            file.close(h)
        end
        if err then return "theme.lua config error: " .. err end
        local b = file.open("/.theme.bak")
        if b then
            file.truncate(b, 0)
            file.write(b, content)
            file.close(b)
        end
        return nil
    end
    local h = file.open(path)
    if not h then h = file.create(path) end
    if not h then return "cannot write " .. path end
    file.truncate(h, 0)
    file.write(h, content)
    file.close(h)
    return nil
end

function editor_save()
    -- Backups and the REPL history are read-only: you can view them in the
    -- file browser, but never overwrite them with Ctrl+S (.theme.bak must
    -- keep holding the last valid config).
    if ed_path == nil or ed_path == "" then
        -- New buffer: Ctrl+S switches into the "save as:" prompt.
        ed_saveas = true
        ed_saveas_path = ""
        update_editor_header()
        gfx.invalidate()
        return
    end
    if ed_path == "/.theme.bak" or ed_path == "/.repl_history" then
        print("config error: " .. ed_path .. " is read-only (view only)")
        gfx.invalidate()
        return
    end
    local err = editor_write(ed_path, table.concat(ed_lines, "\n"))
    if err then
        print(err)
    else
        ed_dirty = false
    end
    update_editor_header()
    gfx.invalidate()
end

-- Commit the "save as:" prompt (Enter): write to the typed path, creating the
-- file when it does not exist yet, and adopt the path as the active buffer.
function editor_saveas_commit()
    local path = ed_saveas_path
    if path == "" or path:sub(1, 1) ~= "/" or path:sub(-1) == "/" then
        print("save error: path must be absolute (e.g. /notes.txt)")
        gfx.invalidate()
        return
    end
    if path == "/.theme.bak" or path == "/.repl_history" then
        print("config error: " .. path .. " is read-only (view only)")
        gfx.invalidate()
        return
    end
    local err = editor_write(path, table.concat(ed_lines, "\n"))
    if err then
        print(err)
        gfx.invalidate()
        return
    end
    ed_path = path
    ed_dirty = false
    ed_saveas = false
    ed_saveas_path = ""
    update_editor_header()
    gfx.invalidate()
end

function editor_saveas_cancel()
    ed_saveas = false
    ed_saveas_path = ""
    update_editor_header()
    gfx.invalidate()
end

local function editor_render()
    if not ed_open then return end
    local w = find_win("editor")
    if not w or w.ws ~= current_ws then return end
    local tx = w.x + theme.wm.border + 6
    local ty = w.y + theme.wm.border + theme.wm.title_h + 6
    local content_rows = math.floor((w.h - theme.wm.title_h - 12) / ed_row_h)
    if content_rows < 1 then content_rows = 1 end
    local max_chars = math.max(math.floor((w.w - 2 * theme.wm.border - 12) / ed_glyph_w), 1)
    -- Keep the cursor visible horizontally: ed_scroll_col is the byte offset
    -- of the first visible column; scroll it only when the cursor leaves the
    -- window (like vertical scrolling, but along the line).
    local line_len = #ed_lines[ed_row]
    if ed_col < ed_scroll_col then
        ed_scroll_col = ed_col
    elseif ed_col - ed_scroll_col >= max_chars then
        ed_scroll_col = ed_col - max_chars + 1
    end
    -- Scroll so the cursor row is always visible.
    local first = 1
    if ed_row > content_rows then first = ed_row - content_rows + 1 end
    for i = first, math.min(#ed_lines, first + content_rows - 1) do
        local text = ed_lines[i]
        -- Slice the visible part of the line when horizontally scrolled.
        local shown = text
        if ed_scroll_col > 0 and i == ed_row then
            shown = string.sub(text, ed_scroll_col + 1)
        elseif i ~= ed_row then
            shown = string.sub(text, 1, max_chars)
        end
        gfx.draw_text(shown, tx, ty, theme.text)
        if i == ed_row then
            gfx.draw_rect(tx + (ed_col - ed_scroll_col) * ed_glyph_w, ty, ed_glyph_w, 16, theme.accent)
        end
        ty = ty + ed_row_h
    end
end
