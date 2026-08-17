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
ed_view_top = ed_view_top or 1
ed_dirty = ed_dirty or false
ed_open = ed_open or false
ed_saveas = ed_saveas or false
ed_saveas_path = ed_saveas_path or ""
ed_esc_pending = ed_esc_pending or false
ed_saved = ed_saved or ""
ed_glyph_w = 8
ed_row_h = 18

-- Code-point aware helpers for horizontal scrolling: the cursor position and
-- the scroll offset are byte offsets, but the visible window is a character
-- count — mixing the two can split a multi-byte UTF-8 sequence and misplace
-- the cursor (2026-08-15-self-audit). The cp_* helpers live in repl.lua (shared
-- chunk scope).

-- Number of code points from 0-based byte offset `from` up to (not including)
-- `to` within `s`; both must be code-point boundaries.
local function cp_count(s, from, to)
    local n = 0
    local i = from
    while i < to do
        i = next_cp(s, i)
        n = n + 1
    end
    return n
end

-- Slice `s` starting at 0-based byte offset `from` (a code-point boundary) for
-- at most `count` code points; returns the substring and the 0-based end byte
-- offset.
local function cp_slice(s, from, count)
    local i = from
    for _ = 1, count do
        if i >= #s then break end
        i = next_cp(s, i)
    end
    return string.sub(s, from + 1, i), i
end

-- Content geometry of the editor window: the text origin, the number of fully
-- visible rows and the visible character count. Shared by the render and the
-- mouse hit-tests so a drawn glyph and a click always agree.
local function editor_text_geometry(w)
    local tx = w.x + theme.wm.border + 6
    local ty = w.y + theme.wm.border + theme.wm.title_h + 6
    local content_rows = math.floor((w.h - theme.wm.title_h - 12) / ed_row_h)
    if content_rows < 1 then content_rows = 1 end
    local max_chars = math.max(math.floor((w.w - 2 * theme.wm.border - 12) / ed_glyph_w), 1)
    return tx, ty, content_rows, max_chars
end

-- Keep the caret row inside the visible viewport after any caret movement
-- (keys, click). The wheel scrolls the viewport independently and may leave
-- the caret off-screen until the user clicks or navigates (editor convention).
local function editor_reveal_caret()
    local w = find_win("editor")
    if not w then return end
    local _, _, content_rows = editor_text_geometry(w)
    if ed_row < ed_view_top then
        ed_view_top = ed_row
    elseif ed_row >= ed_view_top + content_rows then
        ed_view_top = ed_row - content_rows + 1
    end
end

-- Mouse wheel: scroll the viewport. A positive delta scrolls toward the end
-- of the document, negative toward the start — the standard (Windows/Linux)
-- direction, where scrolling down moves the view down (QEMU's ps2 mouse sends
-- wheel-down as positive Z, real hardware sends wheel-up — the interpretation
-- lives here). The text caret stays in place — the GUI-editor convention (VS
-- Code, gedit, ...) is that the wheel scrolls the view and a click places the
-- caret.
local function editor_wheel(delta)
    if not ed_open or ed_saveas then return end
    local w = find_win("editor")
    if not w or w.ws ~= current_ws then return end
    local _, _, content_rows = editor_text_geometry(w)
    local max_top = math.max(#ed_lines - content_rows + 1, 1)
    ed_view_top = math.max(1, math.min(ed_view_top + delta, max_top))
end

-- Place the text caret at the clicked character (GUI-editor convention). The
-- column is code-point aware and clamps to the visible text / the line end; a
-- click outside the body (title bar, border) is ignored.
local function editor_click_at(mx, my)
    if not ed_open or ed_saveas then return end
    local w = find_win("editor")
    if not w or w.ws ~= current_ws then return end
    local tx, ty, content_rows, max_chars = editor_text_geometry(w)
    if my < ty then return end -- title bar / border, not the body
    local line_idx = ed_view_top + math.floor((my - ty) / ed_row_h)
    if line_idx < 1 then line_idx = 1 end
    if line_idx > #ed_lines then line_idx = #ed_lines end
    local col_cp = math.floor((mx - tx) / ed_glyph_w)
    if col_cp < 0 then col_cp = 0 end
    if col_cp > max_chars then col_cp = max_chars end
    -- Rows are drawn from the caret row's scroll offset (focused) or from the
    -- start (every other row); map the click against how the row was drawn.
    local line = ed_lines[line_idx]
    local start_byte = 0
    if line_idx == ed_row then start_byte = ed_scroll_col end
    local _, off = cp_slice(line, start_byte, col_cp)
    ed_row = line_idx
    ed_col = off
    editor_reveal_caret()
end

-- Header text shown in the window title bar: the context (path, dirty marker)
-- on the left; no key hints are stored here (help F1 lives in the bar, §7b).
-- The save-as prompt is functional (the cursor sits in it) but
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
    -- Read-only files (every `*.bak` backup plus /.repl_history) are view-only
    -- in the files browser (Space); the editor refuses to load them so they
    -- can never be overwritten with Ctrl+S. Checked first (guard nil/empty —
    -- a fresh untitled buffer) so a refused load leaves the current buffer
    -- untouched.
    if path ~= nil and path ~= "" and (path:sub(-4) == ".bak" or path == "/.repl_history") then
        wm_error("editor", path .. " is read-only (view only)")
        gfx.invalidate()
        return
    end
    if path == nil or path == "" then
        -- Fresh untitled buffer.
        ed_saveas = false
        ed_saveas_path = ""
        ed_open = true
        ed_path = nil
        ed_row = 1
        ed_col = 0
        ed_scroll_col = 0
        ed_view_top = 1
        ed_dirty = false
        ed_lines = { "" }
        ed_saved = ""
        update_editor_header()
        gfx.invalidate()
        return
    end
    -- Read the file first and commit the buffer only after a successful open,
    -- so a failed load never leaves stale content under the new path (audit
    -- 2026-08-15).
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
    ed_saveas = false
    ed_saveas_path = ""
    ed_open = true
    ed_path = path
    ed_row = 1
    ed_col = 0
    ed_scroll_col = 0
    ed_view_top = 1
    ed_dirty = false
    ed_lines = t
    ed_saved = table.concat(t, "\n")
    update_editor_header()
    gfx.invalidate()
end

-- Open a file in the editor, refusing to discard unsaved changes — the same
-- invariant Super+T keeps ("a dirty buffer is kept so unsaved edits are never
-- lost"). files_edit and Super+Z route through this so opening another file
-- cannot silently drop the buffer (2026-08-15-self-audit).
function editor_load_safe(path)
    if ed_open and ed_dirty then
        wm_error("editor", "unsaved changes — save first (Ctrl+S)")
        gfx.invalidate()
        return false
    end
    editor_load(path)
    return true
end

-- Basename backup path for a .lua file (ADR-025): theme.lua -> .theme.bak,
-- api.lua -> .api.bak, test.lua -> .test.bak — never "test.lua.bak"
-- concatenation. The backup lives next to the working copy as a hidden file.
local function lua_backup_path(path)
    local dir, name = path:match("^(.*)/([^/]+)$")
    if not dir then
        dir, name = "", path
    end
    local stem = name:sub(1, -5) -- strip the ".lua" suffix
    if dir == "" then return "/." .. stem .. ".bak" end
    return dir .. "/." .. stem .. ".bak"
end

-- Persist `content` to `path`. /wm/theme.lua is validated live; a broken
-- config is still written to the working copy (the user keeps fixing) while
-- /wm/.theme.bak stays at the last valid (previous) version. A valid config
-- backs up the PREVIOUS working copy to /wm/.theme.bak, then writes the new
-- version — the backup never mirrors the just-saved content. Every other
-- `.lua` file follows the same basename backup rule on save (test.lua ->
-- .test.bak), because Lua files carry the most valuable user work (config,
-- scripts); any other path is a plain rewrite; a missing file is created
-- (ext2 create). Returns nil on success or an error.
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
    -- Every other .lua file keeps a basename backup of its previous version
    -- on every save (a fresh file has no previous version, so nothing to back
    -- up on first save-as). The backup is created on demand like the theme
    -- one; read-only files (ending .bak) are never backed up again.
    if path:sub(-4) == ".lua" then
        local prev = read_file(path)
        if prev ~= nil then
            local bak = lua_backup_path(path)
            local b = file.open(bak)
            if not b then b = file.create(bak) end
            if b then
                file.truncate(b, 0)
                file.write(b, prev)
                file.close(b)
            end
        end
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
    if err and ed_path ~= "/wm/theme.lua" then
        -- The write failed outright (e.g. "cannot write /x"): keep the buffer
        -- dirty so the changes are never lost.
        wm_error("editor", err)
        update_editor_header()
        gfx.invalidate()
        return
    end
    -- /wm/theme.lua is always written to disk, even when the config is invalid
    -- (the error is only a validation warning — the previous look stays and
    -- the user keeps fixing the working copy). The on-disk copy matches the
    -- buffer now, so the buffer must not stay dirty: a dirty buffer would
    -- block Super+T and any files-edit forever (the editor could never escape
    -- an unsavable theme).
    if err then wm_error("editor", err) end
    ed_saved = table.concat(ed_lines, "\n")
    ed_dirty = false
    -- The file (or its *.bak backup) just landed on disk; refresh the file
    -- browser immediately so a new entry shows up without re-navigating
    -- (files_refresh keeps the selection and is a no-op when the files window
    -- is not showing the affected directory).
    files_refresh()
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
    if err and path ~= "/wm/theme.lua" then
        wm_error("editor", err)
        gfx.invalidate()
        return
    end
    -- /wm/theme.lua is written even when the config is invalid (validation
    -- warning only); the buffer adopts the path and is no longer dirty.
    if err then wm_error("editor", err) end
    -- The new file lands on disk; make it appear in the file browser right
    -- away if it is showing the directory (files_refresh keeps the selection).
    files_refresh()
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
    local tx, ty, content_rows, max_chars = editor_text_geometry(w)
    -- Keep the cursor visible horizontally: ed_scroll_col is the byte offset
    -- of the first visible code point; scroll it only when the cursor leaves
    -- the window (code-point aware, so a UTF-8 sequence is never split).
    local line_len = #ed_lines[ed_row]
    if ed_col < ed_scroll_col then
        ed_scroll_col = ed_col
    elseif cp_count(ed_lines[ed_row], ed_scroll_col, ed_col) >= max_chars then
        -- Walk the scroll forward so the cursor sits max_chars-1 code points
        -- from the left edge.
        local target = ed_col
        for _ = 1, max_chars - 1 do
            if target == 0 then break end
            target = prev_cp(ed_lines[ed_row], target)
        end
        ed_scroll_col = target
    end
    -- The viewport is an independent scroll offset (mouse wheel moves it); the
    -- caret row is kept visible by editor_reveal_caret whenever it moves.
    local first = ed_view_top
    for i = first, math.min(#ed_lines, first + content_rows - 1) do
        local text = ed_lines[i]
        -- Slice the visible part of the line by code points: the focused row
        -- starts at the scroll offset, every other row at the start; always
        -- capped to the window width so a long line never bleeds over the
        -- window edge or a neighbour (2026-08-15-self-audit).
        local shown
        if i == ed_row then
            shown = cp_slice(text, ed_scroll_col, max_chars)
        else
            shown = cp_slice(text, 0, max_chars)
        end
        gfx.draw_text(shown, tx, ty, theme.text)
        -- The solid block marks the text cursor — except during the save-as
        -- prompt, when the cursor moved to the title bar.
        if i == ed_row and not ed_saveas then
            gfx.draw_rect(tx + cp_count(text, ed_scroll_col, ed_col) * ed_glyph_w, ty, ed_glyph_w, 16, theme.accent)
        end
        ty = ty + ed_row_h
    end
end
