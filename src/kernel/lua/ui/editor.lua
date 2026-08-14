-- editor.lua - minimal in-memory file editor inside a shell window (M7.1.5).
-- Loads a file through the file.* bindings, edits it with the keyboard and
-- saves on ctrl+s. State is kept as globals so an F5 reload does not lose
-- the buffer.

ed_path = ed_path or "/theme.lua"
ed_lines = ed_lines or { "" }
ed_row = ed_row or 1
ed_col = ed_col or 0
ed_scroll_col = ed_scroll_col or 0
ed_dirty = ed_dirty or false
ed_open = ed_open or false
ed_glyph_w = 8
ed_row_h = 18

function editor_load(path)
    ed_path = path
    ed_open = true
    ed_row = 1
    ed_col = 0
    ed_scroll_col = 0
    ed_dirty = false
    local h = file.open(path)
    if not h then
        ed_lines = { "file.open failed: " .. path }
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
    gfx.invalidate()
end

function editor_save()
    -- Backups and the REPL history are read-only: you can view them in the
    -- file browser, but never overwrite them with Ctrl+S (.theme.bak must
    -- keep holding the last valid config).
    if ed_path == "/.theme.bak" or ed_path == "/.repl_history" then
        print("config error: " .. ed_path .. " is read-only (view only)")
        gfx.invalidate()
        return
    end
    local content = table.concat(ed_lines, "\n")
    -- Validate without writing: a broken config must not clobber the file.
    -- On success apply_theme_content already applied the new look live.
    local err = apply_theme_content(content)
    if err then
        -- Broken config: leave the working copy and the editor buffer as they
        -- are (the user keeps fixing), but do not touch .theme.bak — the live
        -- look stays on the last valid version.
        local h = file.open(ed_path)
        if h then
            file.truncate(h, 0)
            file.write(h, content)
            file.close(h)
        end
        ed_dirty = false
        print("theme.lua config error: " .. err)
        gfx.invalidate()
        return
    end
    -- Valid config: persist the new version and refresh the last-valid backup.
    local h = file.open(ed_path)
    if h then
        file.truncate(h, 0)
        file.write(h, content)
        file.close(h)
    end
    local b = file.open("/.theme.bak")
    if b then
        file.truncate(b, 0)
        file.write(b, content)
        file.close(b)
    end
    ed_dirty = false
end

local function editor_render()
    if not ed_open then return end
    local w = find_win("editor")
    if not w or w.ws ~= current_ws then return end
    local tx = w.x + theme.wm.border + 6
    local ty = w.y + theme.wm.border + theme.wm.title_h + 6
    -- Status line: path + dirty marker + save hint.
    local status = ed_path .. (ed_dirty and " *" or "") .. "  Ctrl+s save"
    gfx.draw_text(status, tx, ty, theme.text_dim)
    ty = ty + ed_row_h
    local content_rows = math.floor((w.h - theme.wm.title_h - 12) / ed_row_h) - 1
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
