-- tests/lua/run.lua — Lua shell regression tests.
--
-- Concatenated AFTER the shell modules (stubs + theme + wm + repl + editor +
-- files + launcher + input + main), so every shell global and local is in
-- scope. Each test overrides the shared mocks as needed; the framework
-- reports pass/fail and exits nonzero when anything fails. Run through
-- `zig build shell-test` (tools/lua-shell-test.sh).

local passed, failed = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        _p("FAIL " .. name .. ": " .. tostring(err))
    end
end

local function set_disk(initial)
    local d = make_disk(initial)
    file = d.mock
    return d.files
end

-- ──────────────────────────────────────────────────────────────────────────

test("UTF-8 helpers step one code point per ASCII character", function()
    -- Regression for the next_cp off-by-one: it stepped two code points per
    -- ASCII char, misplacing the editor cursor and over-slicing lines.
    local s = "abshort line"
    for i = 0, 3 do
        assert(next_cp(s, i) == i + 1, "next_cp(" .. i .. ")")
        if i > 0 then assert(prev_cp(s, i) == i - 1, "prev_cp(" .. i .. ")") end
    end
    assert(cp_count(s, 0, 5) == 5, "cp_count")
    assert(cp_slice(s, 0, 3) == "abs", "cp_slice")
    local m = "\xc4\x9b" .. "b" -- 'ě' (2 bytes) + 'b'
    assert(next_cp(m, 0) == 2, "next_cp multi-byte")
    assert(cp_count(m, 0, 3) == 2, "cp_count multi-byte")
    assert(cp_slice(m, 0, 1) == "\xc4\x9b", "cp_slice multi-byte")
    assert(prev_cp(m, 3) == 2 and prev_cp(m, 2) == 0, "prev_cp multi-byte")
end)

test("editor inserts chars, comma and backspace correctly", function()
    local content = "a = 1\nb = 2\n"
    set_disk({ ["/t.txt"] = content })
    windows[#windows + 1] = window("editor", current_ws)
    set_focus("editor")
    editor_load("/t.txt")
    for _, c in ipairs({ "t", "h", "e", "m", "e", ".", "a", "c", "c", "e", "n", "t", " ", "=", " ", "0", "x", "F", "F", "5", "5", "4", "4", "," }) do
        handle_key({ type = "key", pressed = true, super = false, alt = false, ctrl = false, shift = false, code = nil, char = c })
    end
    assert(ed_lines[1] == "theme.accent = 0xFF5544,a = 1", "typing mismatch: " .. ed_lines[1])
    handle_key({ type = "key", pressed = true, super = false, alt = false, ctrl = false, shift = false, code = "backspace", char = nil })
    assert(ed_lines[1] == "theme.accent = 0xFF5544a = 1", "backspace mismatch")
end)

test("editor cursor sits right after the typed character", function()
    -- The solid block cursor must never cover the just-typed text (the
    -- "spaces instead of text" symptom of the next_cp off-by-one).
    local texts, rects = {}, {}
    gfx.draw_text = function(t, x, y, c) texts[#texts + 1] = { t = t } end
    gfx.draw_rect = function(x, y, w, h, c) rects[#rects + 1] = { x = x } end
    local content = "short line\n"
    set_disk({ ["/t.txt"] = content })
    windows[#windows + 1] = window("editor", current_ws)
    local w = find_win("editor")
    w.x, w.y, w.w, w.h = 100, 50, 400, 200
    set_focus("editor")
    editor_load("/t.txt")
    local tx = w.x + theme.wm.border + 6
    for _, c in ipairs({ "a", "b", "c", "," }) do
        handle_key({ type = "key", pressed = true, super = false, alt = false, ctrl = false, shift = false, code = nil, char = c })
        texts, rects = {}, {}
        editor_render()
        assert(texts[#texts].t == ed_lines[1]:sub(ed_scroll_col + 1), "render text != buffer")
        local off = (rects[#rects].x - tx) // 8
        assert(off == ed_col, "cursor col " .. off .. " != " .. ed_col)
    end
end)

test("editor mouse wheel scrolls the viewport, not the caret", function()
    local content = ""
    for i = 1, 30 do content = content .. "line " .. i .. "\n" end
    set_disk({ ["/t.txt"] = content })
    windows[#windows + 1] = window("editor", current_ws)
    local w = find_win("editor")
    w.x, w.y, w.w, w.h = 0, 0, 400, 100
    set_focus("editor")
    editor_load("/t.txt")
    ed_view_top = 1
    ed_row = 5
    w.y = theme.bar.height
    -- Positive delta (wheel down) scrolls toward the end — the standard
    -- Windows/Linux direction; the caret stays in place.
    _set_mouse(0, 0, false, 1)
    handle_mouse()
    assert(ed_view_top == 2, "wheel down scrolls the viewport down, got " .. ed_view_top)
    assert(ed_row == 5, "wheel leaves the caret in place, got " .. ed_row)
    -- Negative delta (wheel up) scrolls back toward the start.
    _set_mouse(0, 0, false, -1)
    handle_mouse()
    assert(ed_view_top == 1, "wheel up scrolls the viewport up, got " .. ed_view_top)
    assert(ed_row == 5, "caret still in place after wheel up")
    -- The viewport clamps at the first line.
    _set_mouse(0, 0, false, -1)
    handle_mouse()
    assert(ed_view_top == 1, "wheel up clamps at the first line, got " .. ed_view_top)
end)

test("editor mouse click places the caret at the clicked character", function()
    local content = "hello world\nsecond line\n"
    set_disk({ ["/t.txt"] = content })
    windows[#windows + 1] = window("editor", current_ws)
    local w = find_win("editor")
    w.x, w.y, w.w, w.h = 0, 0, 400, 100
    set_focus("editor")
    editor_load("/t.txt")
    ed_view_top = 1
    w.y = theme.bar.height
    local tx = w.x + theme.wm.border + 6
    local ty = w.y + theme.wm.border + theme.wm.title_h + 6
    -- Click on the second row at glyph index 6 ("second" -> ' ').
    mouse_was_down = false
    _set_mouse(tx + 6 * ed_glyph_w + 1, ty + ed_row_h + 1, true, 0)
    handle_mouse()
    assert(ed_row == 2, "click sets the caret row, got " .. ed_row)
    assert(ed_col == 6, "click sets the caret column, got " .. ed_col)
    -- Clicking past the end of the short first line clamps to the line end.
    mouse_was_down = false
    _set_mouse(tx + 30 * ed_glyph_w, ty + 1, true, 0)
    handle_mouse()
    assert(ed_row == 1, "click on the first row sets the caret row, got " .. ed_row)
    assert(ed_col == #ed_lines[1], "click past the line end clamps to it, got " .. ed_col)
    -- A click never splits a multi-byte UTF-8 sequence: 'ě' is 2 bytes, so
    -- glyph index 2 lands after it at byte offset 3.
    ed_lines[1] = "\xc4\x9bab"
    mouse_was_down = false
    _set_mouse(tx + 2 * ed_glyph_w, ty + 1, true, 0)
    handle_mouse()
    assert(ed_row == 1, "click on a utf-8 row sets the caret row")
    assert(ed_col == 3, "click lands on a code-point boundary, got byte " .. ed_col)
end)

test("editor keyboard caret movement keeps the caret visible", function()
    local content = ""
    for i = 1, 30 do content = content .. "line " .. i .. "\n" end
    set_disk({ ["/t.txt"] = content })
    windows[#windows + 1] = window("editor", current_ws)
    local w = find_win("editor")
    w.x, w.y, w.w, w.h = 0, 0, 400, 100
    set_focus("editor")
    editor_load("/t.txt")
    ed_view_top = 1
    w.y = theme.bar.height
    for _ = 1, 29 do
        handle_key({ type = "key", pressed = true, super = false, alt = false, ctrl = false, shift = false, code = "down", char = nil })
    end
    assert(ed_row == 30, "caret reaches the last line")
    local _, _, content_rows = editor_text_geometry(find_win("editor"))
    assert(ed_view_top == math.max(ed_row - content_rows + 1, 1), "viewport follows the caret to the bottom")
    assert(ed_view_top <= ed_row and ed_row < ed_view_top + content_rows, "caret row stays visible")
end)

test("files view mode wheel scrolls the viewport, not the cursor", function()
    local content = ""
    for i = 1, 30 do content = content .. "line " .. i .. "\n" end
    set_disk({ ["/t.txt"] = content })
    windows[#windows + 1] = window("files", current_ws)
    local w = find_win("files")
    w.x, w.y, w.w, w.h = 0, theme.bar.height, 400, 100
    set_focus("files")
    fs_viewing = true
    fs_view_content = content
    fs_view_row = 5
    fs_view_scroll = 0
    -- Positive delta (wheel down) scrolls toward the end — standard direction.
    _set_mouse(0, 0, false, 1)
    handle_mouse()
    assert(fs_view_scroll == 1, "view wheel down scrolls, got " .. fs_view_scroll)
    assert(fs_view_row == 5, "view wheel leaves the cursor in place, got " .. fs_view_row)
    -- Negative delta (wheel up) scrolls back toward the start.
    _set_mouse(0, 0, false, -1)
    handle_mouse()
    assert(fs_view_scroll == 0, "view wheel up scrolls back, got " .. fs_view_scroll)
    _set_mouse(0, 0, false, -1)
    handle_mouse()
    assert(fs_view_scroll == 0, "view wheel up clamps at the top, got " .. fs_view_scroll)
end)

test("files view mode click places the hollow cursor", function()
    local content = "hello view\nsecond line\nthird line\n"
    set_disk({ ["/t.txt"] = content })
    windows[#windows + 1] = window("files", current_ws)
    local w = find_win("files")
    w.x, w.y, w.w, w.h = 0, theme.bar.height, 400, 100
    set_focus("files")
    fs_viewing = true
    fs_view_content = content
    fs_view_row = 1
    fs_view_col = 0
    fs_view_scroll = 0
    local tx = w.x + theme.wm.border + 6
    local ty = w.y + theme.wm.border + theme.wm.title_h + 6
    mouse_was_down = false
    _set_mouse(tx + 6 * fs_glyph_w + 1, ty + fs_row_h + 1, true, 0)
    handle_mouse()
    assert(fs_view_row == 2, "view click sets the cursor row, got " .. fs_view_row)
    assert(fs_view_col == 6, "view click sets the cursor column, got " .. fs_view_col)
end)

test("files view mode keyboard movement keeps the cursor visible", function()
    local content = ""
    for i = 1, 30 do content = content .. "line " .. i .. "\n" end
    set_disk({ ["/t.txt"] = content })
    windows[#windows + 1] = window("files", current_ws)
    local w = find_win("files")
    w.x, w.y, w.w, w.h = 0, theme.bar.height, 400, 100
    set_focus("files")
    fs_viewing = true
    fs_view_content = content
    fs_view_row = 1
    fs_view_col = 0
    fs_view_scroll = 0
    for _ = 1, 29 do
        handle_key({ type = "key", pressed = true, super = false, alt = false, ctrl = false, shift = false, code = "down", char = nil })
    end
    assert(fs_view_row == 30, "view cursor reaches the last line, got " .. fs_view_row)
    local _, _, content_rows = files_view_geometry(find_win("files"))
    assert(fs_view_scroll + content_rows >= fs_view_row, "view cursor stays visible")
end)

test("double-click on the title bar toggles fullscreen", function()
    set_disk({ ["/t.txt"] = "x" })
    windows[#windows + 1] = window("editor", current_ws)
    local w = find_win("editor")
    w.x, w.y, w.w, w.h = 0, theme.bar.height, 400, 100
    set_focus("editor")
    editor_load("/t.txt")
    fullscreen_win = nil
    fullscreen_restore = nil
    local hy = w.y + theme.wm.border + 5 -- inside the title bar
    -- A single click on the title bar must not fullscreen.
    _set_ms(100)
    _set_mouse(40, hy, true, 0)
    mouse_was_down = false
    handle_mouse()
    assert(fullscreen_win == nil, "single title click does not fullscreen")
    -- A second click within the 300 ms threshold toggles fullscreen.
    _set_ms(200)
    _set_mouse(40, hy, true, 0)
    mouse_was_down = false
    handle_mouse()
    assert(fullscreen_win == "editor", "double-click enters fullscreen")
    -- Another double-click restores.
    _set_ms(300)
    _set_mouse(40, hy, true, 0)
    mouse_was_down = false
    handle_mouse()
    _set_ms(400)
    _set_mouse(40, hy, true, 0)
    mouse_was_down = false
    handle_mouse()
    assert(fullscreen_win == nil, "double-click exits fullscreen")
    -- A double-click far apart in time must not count.
    _set_ms(1000)
    _set_mouse(40, hy, true, 0)
    mouse_was_down = false
    handle_mouse()
    _set_ms(1500)
    _set_mouse(40, hy, true, 0)
    mouse_was_down = false
    handle_mouse()
    assert(fullscreen_win == nil, "slow clicks are not a double-click")
end)

test("files title bar double-click fullscreens, never navigates up", function()
    local d = set_disk({ ["/a/b.txt"] = "x" })
    file.dir = function(p)
        if p == "/a" then return { { name = "b.txt", dir = false } } end
        return { { name = "a", dir = true } }
    end
    windows[#windows + 1] = window("files", current_ws)
    local w = find_win("files")
    w.x, w.y, w.w, w.h = 0, theme.bar.height, 400, 100
    set_focus("files")
    files_open("/a")
    assert(fs_path == "/a", "opened the nested directory")
    fullscreen_win = nil
    local hy = w.y + theme.wm.border + 5
    -- A single click on the files title bar focuses only (no navigation).
    _set_ms(100)
    _set_mouse(40, hy, true, 0)
    mouse_was_down = false
    handle_mouse()
    assert(fs_path == "/a", "single title click does not navigate up")
    -- The double-click fullscreens instead of doing cd ..
    _set_ms(200)
    _set_mouse(40, hy, true, 0)
    mouse_was_down = false
    handle_mouse()
    assert(fullscreen_win == "files", "files title double-click fullscreens")
    assert(fs_path == "/a", "files double-click never navigates up")
end)

test("files .. entry goes up to the parent directory", function()
    local d = set_disk({ ["/a/b.txt"] = "x" })
    file.dir = function(p)
        if p == "/a" then return { { name = "b.txt", dir = false } } end
        if p == "/" then return { { name = "a", dir = true } } end
        return {}
    end
    windows[#windows + 1] = window("files", current_ws)
    local w = find_win("files")
    w.x, w.y, w.w, w.h = 0, theme.bar.height, 400, 100
    set_focus("files")
    files_open("/a")
    assert(fs_entries[1].name == "..", ".. is listed first in a nested dir")
    files_open_entry(fs_entries[1])
    assert(fs_path == "/", ".. opens the parent directory")
    assert(fs_entries[1].name ~= "..", "root listing has no parent entry")
end)

test("files_open_entry: file opens, read-only is refused (regression)", function()
    local disk = set_disk({ ["/a/note.txt"] = "hi", ["/a/old.bak"] = "backup" })
    file.dir = function(p)
        if p == "/a" then return {
            { name = "note.txt", dir = false },
            { name = "old.bak", dir = false },
        } end
        return {}
    end
    windows[#windows + 1] = window("files", current_ws)
    local w = find_win("files")
    w.x, w.y, w.w, w.h = 0, theme.bar.height, 400, 100
    set_focus("files")
    files_open("/a")
    -- A regular file opens in the editor (files_edit -> editor_load_safe).
    local file_entry = nil
    for _, e in ipairs(fs_entries) do if e.name == "note.txt" then file_entry = e end end
    files_open_entry(file_entry)
    assert(ed_path == "/a/note.txt", "editing a file loads it into the editor")
    -- A read-only .bak entry is refused without a nil-global call (regression:
    -- files_open_entry used to reference is_read_only before its declaration).
    local bak_entry = nil
    for _, e in ipairs(fs_entries) do if e.name == "old.bak" then bak_entry = e end end
    files_open_entry(bak_entry)
    assert(ed_path == "/a/note.txt", "read-only entry does not replace the buffer")
end)

test("directories render with a leading slash", function()
    local d = set_disk({ ["/a/b.txt"] = "x" })
    file.dir = function(p)
        if p == "/a" then return {
            { name = "sub", dir = true },
            { name = "b.txt", dir = false },
        } end
        return {}
    end
    windows[#windows + 1] = window("files", current_ws)
    local w = find_win("files")
    w.x, w.y, w.w, w.h = 0, theme.bar.height, 400, 100
    set_focus("files")
    files_open("/a")
    local texts = {}
    gfx.draw_text = function(t) texts[#texts + 1] = t end
    files_render()
    assert(texts[1] == "/..", "parent renders as /.., got " .. tostring(texts[1]))
    assert(texts[2] == "/sub", "dir renders with a leading slash, got " .. tostring(texts[2]))
    assert(texts[3] == "b.txt", "file renders without a slash, got " .. tostring(texts[3]))
end)

test("bar clock shows the RTC time of day", function()
    fullscreen_win = nil
    fullscreen_restore = nil
    _set_of_day_ms((14 * 3600 + 32 * 60) * 1000)
    local texts = {}
    gfx.draw_text = function(t) texts[#texts + 1] = t end
    bar_render()
    local found = false
    for _, t in ipairs(texts) do if t == "14:32" then found = true end end
    assert(found, "clock renders 14:32 from of_day_ms")
end)

test("the bar clock requests a redraw when the second changes", function()
    local invalidated = 0
    gfx.invalidate = function() invalidated = invalidated + 1 end
    _set_of_day_ms(60 * 60 * 1000) -- 01:00:00
    last_clock_sec = -1
    update()
    assert(invalidated >= 1, "clock change triggers a redraw")
    local before = invalidated
    update() -- same second: no redraw
    assert(invalidated == before, "no redraw within the same second")
    _set_of_day_ms(60 * 60 * 1000 + 1000) -- 01:00:01
    update()
    assert(invalidated > before, "a new second triggers a redraw")
end)

test("close button still closes the focused window", function()
    set_disk({ ["/t.txt"] = "x" })
    windows[#windows + 1] = window("editor", current_ws)
    local w = find_win("editor")
    w.x, w.y, w.w, w.h = 0, theme.bar.height, 400, 100
    set_focus("editor")
    editor_load("/t.txt")
    local cb = close_button_rect(w)
    _set_mouse(cb.x + cb.w / 2, cb.y + cb.h / 2, true, 0)
    mouse_was_down = false
    handle_mouse()
    local gone = true
    for _, w2 in ipairs(windows) do
        if w2 == w then gone = false end
    end
    assert(gone, "close button closes the window")
end)

test("every .lua file keeps a basename backup on save", function()
    local disk = set_disk({
        ["/test.lua"] = "v1",
        ["/foo/bar.lua"] = "old bar",
        ["/notes.txt"] = "notes",
        ["/wm/api.lua"] = "api v1",
        ["/wm/theme.lua"] = table.concat({
            "theme = {",
            "  background = 0x111826, surface = 0x182545, surface_alt = 0x223454,",
            "  text = 0xDDDDDD, text_dim = 0x798BB2, accent = 0x82DCCC,",
            "  accent_b = 0x00AA84, accent_dark = 0x007D6F, inactive = 0x798BB2,",
            "  red = 0xFF6B6B, trash = 0x4A90D9,",
            "  wm = { gap_out=0, gap_in=0, border=2, title_h=24, opacity_active=0.95, opacity_inactive=0.85 },",
            "  bar = { height = 35, radius = 0 }, ws = { \"1\",\"2\",\"3\" } }",
        }, "\n"),
    })
    windows[#windows + 1] = window("editor", current_ws)
    set_focus("editor")
    local function save_as(path, content)
        ed_path = path
        ed_lines = { content }
        editor_save()
    end
    save_as("/test.lua", "v2")
    assert(disk["/.test.bak"] == "v1", "test.lua backup")
    save_as("/foo/bar.lua", "new bar")
    assert(disk["/foo/.bar.bak"] == "old bar", "subdir backup")
    save_as("/notes.txt", "edited")
    assert(disk["/.notes.bak"] == nil, "non-lua must not get a backup")
    save_as("/brand-new.lua", "first")
    assert(disk["/.brand-new.bak"] == nil, "fresh file must not get a backup")
    save_as("/wm/api.lua", "api v2")
    assert(disk["/wm/.api.bak"] == "api v1", "api.lua backup")
    save_as("/wm/theme.lua", table.concat({
        "theme = {",
        "  background = 0x111826, surface = 0x182545, surface_alt = 0x223454,",
        "  text = 0xDDDDDD, text_dim = 0x798BB2, accent = 0xFF5544,",
        "  accent_b = 0x00AA84, accent_dark = 0x007D6F, inactive = 0x798BB2,",
        "  red = 0xFF6B6B, trash = 0x4A90D9,",
        "  wm = { gap_out=0, gap_in=0, border=2, title_h=24, opacity_active=0.95, opacity_inactive=0.85 },",
        "  bar = { height = 35, radius = 0 }, ws = { \"1\",\"2\",\"3\" } }",
    }, "\n"))
    assert(disk["/wm/.theme.bak"] ~= nil, "theme.lua backup")
    assert(is_read_only(".test.bak") and is_read_only(".bar.bak") and is_read_only(".api.bak"), "backups read-only")
    assert(is_read_only(".repl_history"), "repl history read-only")
end)

test("a broken theme cannot trap the editor (dirty buffer escapes)", function()
    local disk = set_disk({
        ["/wm/theme.lua"] = table.concat({
            "theme = { background = 0x111826, accent = 0x82DCCC,",
            "  wm = { gap_out=0, gap_in=0, border=2, title_h=24, opacity_active=0.95, opacity_inactive=0.85 },",
            "  bar = { height = 35, radius = 0 }, ws = { \"1\",\"2\",\"3\" } }",
        }, "\n"),
    })
    -- The theme is structurally invalid (missing required fields).
    local err = apply_disk_theme()
    assert(err ~= nil, "broken theme must be rejected at load")
    local api_read = false
    file.open = function(p)
        if p == "/wm/theme.lua" then return { p = p } end
        if p == "/wm/api.lua" then api_read = true return { p = p } end
        return nil
    end
    file.read = function(h)
        local c = disk[h.p]
        disk[h.p] = ""
        if c == nil then c = "api ref text" end
        return c
    end
    windows[#windows + 1] = window("editor", current_ws)
    set_focus("editor")
    editor_load_safe("/wm/theme.lua")
    handle_key({ type = "key", pressed = true, super = false, alt = false, ctrl = false, shift = false, code = nil, char = "x" })
    handle_key({ type = "key", pressed = true, super = false, alt = false, ctrl = true, shift = false, code = "s", char = nil })
    -- Saving a broken theme writes the working copy; the buffer must not stay
    -- dirty (that used to block Super+T and files-edit forever).
    assert(ed_dirty == false, "dirty stuck after saving broken theme")
    -- The editor must now be able to load another file.
    windows[#windows + 1] = window("files", current_ws)
    file.dir = function() return { { name = "api.lua", dir = false } } end
    files_open("/wm")
    files_edit("api.lua")
    assert(ed_path == "/wm/api.lua", "files edit stuck on theme.lua")
end)

test("trash and lost+found are protected via the wm_error channel", function()
    set_disk()
    local errs = {}
    local orig = wm_error
    wm_error = function(source, message)
        errs[#errs + 1] = source .. ": " .. tostring(message)
    end
    local removes, renames = {}, {}
    file = {
        open = function() return nil end, read = function() return nil end,
        write = noop, close = noop, truncate = noop,
        dir = function() return { { name = ".trash", dir = true }, { name = "lost+found", dir = true }, { name = "a.txt", dir = false } } end,
        remove = function(p) removes[#removes + 1] = p return 0 end,
        create = noop,
        rename = function(o, n) renames[#renames + 1] = o return 0 end,
    }
    files_open("/")
    local n0 = #errs
    files_remove(".trash")
    assert(errs[n0 + 1] == "files: .trash is protected", "delete .trash refused via wm_error")
    files_rename_start()
    assert(errs[n0 + 2] == "files: lost+found is protected", "rename protected via wm_error")
    files_remove("lost+found")
    assert(errs[n0 + 3] == "files: lost+found is protected", "delete lost+found refused via wm_error")
    files_remove("a.txt")
    assert(#removes == 0 and #renames == 1 and renames[1] == "/a.txt", "a.txt not moved to trash")
    wm_error = orig
end)

test("workspace switch is bounded to theme.ws", function()
    set_disk()
    local before = current_ws
    switch_workspace(99)
    switch_workspace(#theme.ws + 1)
    assert(current_ws == before, "out-of-range workspace moved")
    switch_workspace(1)
    assert(current_ws == 1, "switch_workspace(1) failed")
end)

test("bar geometry is shared and capsules fit the screen", function()
    set_disk()
    local caps = ws_capsules()
    assert(#caps == #theme.ws, "capsule count")
    for _, c in ipairs(caps) do
        assert(c.x > 0 and c.x + c.w <= SW, "capsule off-screen")
    end
    assert(caps[1].x == bar_capsules_x(), "capsule start drifts from bar layout")
    local lbr = launcher_button_rect()
    assert(lbr.x == 8 and lbr.w == 20, "launcher button rect")
end)

test("launcher row hit-test maps the mouse to an item", function()
    set_disk()
    launcher_open = true
    launcher_mode = "run"
    launcher_input = ""
    launcher_filtered = function()
        return { { id = "a", title = "alpha" }, { id = "b", title = "beta" } }
    end
    local lx, ly, lw, lh = launcher_popup()
    assert(launcher_item_at(ly + 35) == 1, "row 1")
    assert(launcher_item_at(ly + 55) == 2, "row 2")
    assert(launcher_item_at(ly + 5) == nil, "header must not be a row")
    assert(launcher_item_at(ly + lh + 10) == nil, "below the popup must be nil")
    launcher_open = false
end)

test("pending Esc resets on navigation inside the files view", function()
    set_disk()
    windows[#windows + 1] = window("files", current_ws)
    local fw = find_win("files")
    fw.x, fw.y, fw.w, fw.h = 0, 0, 600, 400
    set_focus("files")
    fs_viewing = true
    fs_view_content = "line one\nline two\nline three\n"
    fs_view_row = 1
    fs_view_col = 0
    fs_view_scroll = 0
    esc_pending = true
    handle_key({ type = "key", pressed = true, super = false, alt = false, ctrl = false, shift = false, code = "down", char = nil })
    assert(esc_pending == false, "esc_pending stale across navigation")
    assert(fs_view_row == 2, "down did not move the view row")
end)

test("repl_save_history creates the file on first save", function()
    local created = nil
    local written = nil
    file.open = function() return nil end
    file.create = function(p) created = p return { p = p } end
    file.write = function(h, data) written = data end
    file.truncate = function() end
    file.close = noop
    history = { "cmd1", "cmd2" }
    repl_save_history()
    assert(created == "/.repl_history", "history file not created")
    assert(written == "cmd1\ncmd2\n", "history content: " .. tostring(written))
end)

test("file entry colors: hidden/trash dim blue, read-only red outside trash", function()
    set_disk()
    windows[#windows + 1] = window("files", current_ws)
    files_open("/")
    -- Hidden non-read-only -> theme.text_dim (shared hidden/trash dim blue).
    assert(entry_color({ name = ".test", dir = false }, false) == theme.text_dim, "hidden file not dim")
    -- Hidden read-only outside the trash -> red (red wins over dim).
    assert(entry_color({ name = ".theme.bak", dir = false }, false) == theme.red, "hidden read-only not red")
    assert(entry_color({ name = ".repl_history", dir = false }, false) == theme.red, "repl_history not red")
    -- The .trash dir is a dot dir -> dim blue; normal file -> text; selection -> accent.
    assert(entry_color({ name = ".trash", dir = true }, false) == theme.text_dim, ".trash not dim")
    assert(entry_color({ name = "a.txt", dir = false }, false) == theme.text, "normal file not text")
    assert(entry_color({ name = "a.txt", dir = false }, true) == theme.accent, "selection not accent")
    -- Inside /.trash every entry is dim blue, even a read-only one (the red
    -- cue returns once the file is moved back out).
    files_open("/.trash")
    assert(entry_color({ name = "old.txt", dir = false }, false) == theme.text_dim, "trash content not dim")
    assert(entry_color({ name = ".theme.bak", dir = false }, false) == theme.text_dim, "read-only in trash must stay dim")
end)

-- ──────────────────────────────────────────────────────────────────────────

_p(string.format("lua shell: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
