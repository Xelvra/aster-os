-- repl.lua - REPL console state, evaluation and rendering inside the shell.

-- REPL state (kept as globals so hot reload works without the kernel knowing).
lines = lines or {}
current = current or ""
history = history or {}
hist_idx = hist_idx or 0
cursor = cursor or 0
glyph_w = 8
glyph_h = 16

-- The interactive banner is the bundled Lua's own startup line, exposed by
-- the kernel as the _COPYRIGHT global (LUA_COPYRIGHT in
-- libs/lua-5.4/src/lua.h) — no duplicated version string to keep in sync.
-- _VERSION is the stock fallback if the global is ever absent.
local function repl_banner()
    return _COPYRIGHT or _VERSION or "Lua"
end

-- UTF-8 helpers for cursor movement and editing: the cursor is a byte
-- offset into `current`, and code points are 1..4 bytes (continuation
-- bytes are 0x80..0xBF). Stepping over bytes alone would split a multi-byte
-- character (e.g. žluťoučký) when editing.

local function is_cont(b)
    return b ~= nil and b >= 0x80 and b < 0xC0
end

-- Byte offset of the code point start that contains `pos` (1-based) or just
-- before it. Returns the first byte of the code point ending at pos.
local function cp_start(s, pos)
    while pos > 1 and is_cont(string.byte(s, pos)) do
        pos = pos - 1
    end
    return pos
end

-- Byte offset just after the code point that starts at `pos` (1-based).
local function cp_end(s, pos)
    pos = pos + 1
    while pos <= #s and is_cont(string.byte(s, pos)) do
        pos = pos + 1
    end
    return pos
end

local function prev_cp(s, pos)
    -- pos is a byte offset (0..len); return the offset of the previous code
    -- point's start.
    if pos <= 0 then return 0 end
    return cp_start(s, pos) - 1
end

local function next_cp(s, pos)
    -- pos is a byte offset (0..len); return the offset just after the code
    -- point that starts at pos+1. cp_end returns the 1-based position after
    -- the code point, so it maps to the next 0-based offset as (cp_end - 1);
    -- returning it raw would step two code points for every one on ASCII
    -- (off-by-one: cursor, slices and wrapping all fell behind the text).
    if pos >= #s then return pos end
    return cp_end(s, pos + 1) - 1
end
local function add_line(s)
    table.insert(lines, s)
    if #lines > 200 then table.remove(lines, 1) end
end

add_line(repl_banner())
-- Header is empty: the label "~ repl" makes up the title bar — no double
-- space, no hints (help F1 lives in the bar, §7b).
set_window_header("repl", "")

-- Persistent command history (/.repl_history on the mounted filesystem).
-- The in-memory `history` table is rebuilt after boot and F5 hot reload,
-- mirroring .bash_history. Without a disk the session history is memory-only.
local history_path = "/.repl_history"
local history_max = 100

-- Reload the last commands from disk into the `history` table. Called once
-- after the shell loads (main.lua); no-op when the file is missing.
function repl_load_history()
    local h = file.open(history_path)
    if not h then return end
    local content = ""
    while true do
        local chunk = file.read(h, 4096)
        if not chunk or chunk == "" then break end
        content = content .. chunk
    end
    file.close(h)
    local loaded = {}
    for line in (content .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then loaded[#loaded + 1] = line end
    end
    if #loaded > history_max then
        local keep = {}
        for i = #loaded - history_max + 1, #loaded do keep[#keep + 1] = loaded[i] end
        loaded = keep
    end
    history = loaded
end

-- Persist the last commands (newest last, capped at history_max). Called
-- after every Enter; the file is created on first use and a missing disk
-- makes it a no-op (2026-08-15-self-audit: previously the file was never created).
function repl_save_history()
    local h = file.open(history_path)
    if not h then h = file.create(history_path) end
    if not h then return end
    file.truncate(h, 0)
    local start = math.max(1, #history - history_max + 1)
    local out = {}
    for i = start, #history do out[#out + 1] = history[i] end
    local content = table.concat(out, "\n")
    if content ~= "" then content = content .. "\n" end
    file.write(h, content)
    file.close(h)
end

function print(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    add_line(table.concat(parts, "\t"))
end

-- Unified shell error channel: every UI module reports failures through this
-- single formatter, so the REPL scrollback always shows "<source>: <message>".
-- Keeping one entry point guarantees a consistent format as the shell grows.
-- Errors are mirrored to the serial terminal (debug.write), so a headless
-- boot captures them in the boot log / QEMU serial output too.
function wm_error(source, message)
    local line = source .. ": " .. tostring(message)
    add_line(line)
    debug.write(line)
    gfx.invalidate()
end

-- Kernel → shell error hook: called by lua.zig when a frame-loop call
-- (update/render) fails, before the shell hot-reloads. Surfaces the error in
-- the REPL scrollback (the desktop has no terminal; the serial line stays as
-- the privileged kernel diagnostic sink).
function on_shell_error(message)
    wm_error("shell", message)
end

local function run(code)
    local chunk, err = load(code)
    if not chunk then
        wm_error("repl", err)
        return
    end
    local ok, res = pcall(chunk)
    if not ok then
        wm_error("repl", res)
    elseif res ~= nil then
        add_line(tostring(res))
    end
    gfx.invalidate()
end

local function repl_render()
    local w = find_win("repl")
    if not w or w.ws ~= current_ws then return end
    local tx = w.x + theme.wm.border + 6
    local ty = w.y + theme.wm.border + theme.wm.title_h + 6
    local row_h = 18
    local max_lines = math.floor((w.h - theme.wm.title_h - 12) / row_h)
    local max_chars = math.max(math.floor((w.w - 2 * theme.wm.border - 12) / glyph_w), 1)
    local col = tx

    -- Word-wrap a line into rows of at most max_chars code points, never
    -- splitting a multi-byte UTF-8 character.
    local function wrap(s)
        local rows = {}
        local i = 1
        while i <= #s do
            local row = 0
            local j = i
            while j <= #s and row < max_chars do
                j = cp_end(s, j)
                row = row + 1
            end
            rows[#rows + 1] = string.sub(s, i, j - 1)
            i = j
        end
        if #rows == 0 then rows[#rows + 1] = "" end
        return rows
    end

    -- Visible scrollback: wrap all history lines plus the prompt, then show
    -- the last max_lines rows (the prompt is always the last of them).
    local scroll = {}
    for _, line in ipairs(lines) do
        for _, row in ipairs(wrap(line)) do scroll[#scroll + 1] = row end
    end
    local prompt = "> " .. current
    local prompt_rows = wrap(prompt)
    for _, row in ipairs(prompt_rows) do scroll[#scroll + 1] = row end

    local first = math.max(1, #scroll - max_lines + 1)
    for i = first, #scroll do
        gfx.draw_text(scroll[i], col, ty, theme.text)
        ty = ty + row_h
    end

    -- Cursor position within the prompt: code points before the cursor,
    -- counting the "> " prompt prefix (2 code points) so the block lines up
    -- with the drawn text (the prompt is wrapped as a whole).
    local cursor_cp = 0
    local pos = 3 -- "> " ends at byte 2; current starts at byte 3
    while pos <= 2 + cursor do
        pos = cp_end(prompt, pos)
        cursor_cp = cursor_cp + 1
    end
    local cursor_at = 2 + cursor_cp
    local cursor_row = math.floor(cursor_at / max_chars)
    local cursor_col = cursor_at % max_chars
    local prompt_ty = w.y + theme.wm.border + theme.wm.title_h + 6 +
        (#scroll - first) * row_h - (#prompt_rows - 1 - cursor_row) * row_h
    gfx.draw_rect(col + cursor_col * glyph_w, prompt_ty, glyph_w, glyph_h, theme.accent)
end

local function sysmon_render()
    local w = find_win("sysmon")
    if not w or w.ws ~= current_ws then return end
    local tx = w.x + theme.wm.border + 6
    local ty = w.y + theme.wm.border + theme.wm.title_h + 6
    local total = sysmon.ram_total_mb()
    local free = sysmon.ram_free_mb()
    local used = math.max(total - free, 0)
    gfx.draw_text("ram " .. tostring(used) .. "M / " .. tostring(total) .. "M", tx, ty, theme.text)
    ty = ty + 18
    local pct = (total > 0) and math.floor(used * 100 / total) or 0
    gfx.draw_text("ram " .. tostring(pct) .. "%", tx, ty, theme.text_dim)
    ty = ty + 18
    gfx.draw_text("ticks " .. tostring(time.ticks()), tx, ty, theme.text_dim)
end
