-- editor.lua - minimal in-memory file editor inside a shell window (M7.1.5).
-- Loads a file through the file.* bindings, edits it with the keyboard and
-- saves on ctrl+s. State is kept as globals so an F5 reload does not lose
-- the buffer.

-- Super+T opens a fresh (untitled) buffer; Super+Z opens the settings file
-- /wm/theme.lua. A buffer without a path saves through the "save as:" prompt.
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
ed_saved = ed_saved or ""
ed_glyph_w = 8
ed_row_h = 18

-- Header text shown in the window title bar: the context (path, dirty marker)
-- on the left; "help F1" is right-aligned by win_render, so no key hints are
-- stored here. The save-as prompt is functional (the cursor sits in it) but
-- carries no key hints either — how to save lives in the help popup (F1).
local function editor_header()
    if ed_saveas then
        return "save as: " .. ed_saveas_path
    end
    local path = ed_path or "untitled"
    if ed_dirty then
        return path .. "*"
    end
    return path
end

-- Mark the buffer as edited unless its content matches the last saved/loaded
-- text: reverting every change clears the dirty marker again, so a Ctrl+S is
-- only ever offered for a buffer that really differs.
local function editor_touch()
    ed_dirty = table.concat(ed_lines, "\n") ~= ed_saved
end

local function update_editor_header()
    set_window_header("editor", editor_header())
    -- During the save-as prompt the text cursor lives in the title bar after
    -- the typed path; otherwise the body cursor stays.
    if ed_saveas then
        set_window_cursor("editor", #"save as: " + #ed_saveas_path)
    else
        set_window_cursor("editor", nil)
    end
end

function editor_load(path)
    -- Read-only files (/wm/.theme.bak, /.repl_history) are view-only in the
    -- files browser (Space); the editor refuses to load them so they can never
    -- be overwritten with Ctrl+S. Checked first so a refused load leaves the
    -- current buffer untouched.
    if path == "/wm/.theme.bak" or path == "/.repl_history" then
        wm_error("editor", path .. " is read-only (view only)")
        gfx.invalidate()
        return
    end
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
        ed_saved = ""
        update_editor_header()
        gfx.invalidate()
        return
    end
    local h = file.open(path)
    if not h then
        wm_error("editor", "file.open failed: " .. path)
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
    ed_saved = table.concat(t, "\n")
    update_editor_header()
    gfx.invalidate()
end

-- Persist `content` to `path`. /wm/theme.lua is validated live; a broken
-- config is still written to the working copy (the user keeps fixing) while
-- /wm/.theme.bak stays at the last valid (previous) version. A valid config
-- backs up the PREVIOUS working copy to /wm/.theme.bak, then writes the new
-- version — the backup never mirrors the just-saved content. Any other path
-- is a plain rewrite; a missing file is created (ext2 create). Returns nil on
-- success or an error.
local function editor_write(path, content)
    if path == "/wm/theme.lua" then
        local err = apply_theme_content(content)
        if err then
            -- Broken config: keep the working copy editable, never touch the
            -- last-valid backup.
            local h = file.open(path)
            if h then
                file.truncate(h, 0)
                file.write(h, content)
                file.close(h)
            end
            return err
        end
        -- Valid config: /wm/.theme.bak gets the previous working copy (the
        -- manual backup of the last Ctrl+S — never loaded automatically,
        -- ADR-025), then /wm/theme.lua gets the new version. The backup is
        -- created on the first Ctrl+S (file.open fails on a missing file).
        local prev = read_file(path)
        if prev ~= nil then
            local b = file.open("/wm/.theme.bak")
            if not b then b = file.create("/wm/.theme.bak") end
            if b then
                file.truncate(b, 0)
                file.write(b, prev)
                file.close(b)
            end
        end
        local h = file.open(path)
        if h then
            file.truncate(h, 0)
            file.write(h, content)
            file.close(h)
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
    if ed_path == nil or ed_path == "" then
        -- New buffer: Ctrl+S switches into the "save as:" prompt.
        ed_saveas = true
        ed_saveas_path = ""
        update_editor_header()
        gfx.invalidate()
        return
    end
    local err = editor_write(ed_path, table.concat(ed_lines, "\n"))
    if err then
        wm_error("editor", err)
    else
        ed_saved = table.concat(ed_lines, "\n")
        ed_dirty = false
    end
    update_editor_header()
    gfx.invalidate()
end

-- F2: "save as" — open the save-as prompt prefilled with the current path
-- (or empty for a new buffer), so the user can save under a new name.
function editor_save_as()
    ed_saveas = true
    ed_saveas_path = ed_path or ""
    update_editor_header()
    gfx.invalidate()
end

-- Commit the "save as:" prompt (Enter): write to the typed path, creating the
-- file when it does not exist yet, and adopt the path as the active buffer.
function editor_saveas_commit()
    local path = ed_saveas_path
    if path == "" or path:sub(1, 1) ~= "/" or path:sub(-1) == "/" then
        wm_error("editor", "save: path must be absolute (e.g. /notes.txt)")
        gfx.invalidate()
        return
    end
    if path == "/wm/.theme.bak" or path == "/.repl_history" then
        wm_error("editor", path .. " is read-only (view only)")
        gfx.invalidate()
        return
    end
    local err = editor_write(path, table.concat(ed_lines, "\n"))
    if err then
        wm_error("editor", err)
        gfx.invalidate()
        return
    end
    ed_path = path
    ed_saved = table.concat(ed_lines, "\n")
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
        -- The solid block marks the text cursor — except during the save-as
        -- prompt, when the cursor moved to the title bar.
        if i == ed_row and not ed_saveas then
            gfx.draw_rect(tx + (ed_col - ed_scroll_col) * ed_glyph_w, ty, ed_glyph_w, 16, theme.accent)
        end
        ty = ty + ed_row_h
    end
end
