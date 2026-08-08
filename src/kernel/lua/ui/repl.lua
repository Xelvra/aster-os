-- repl.lua - REPL console state, evaluation and rendering inside the shell.

-- REPL state (kept as globals so hot reload works without the kernel knowing).
lines = lines or {}
current = current or ""
history = history or {}
hist_idx = hist_idx or 0
cursor = cursor or 0
glyph_w = 8
glyph_h = 16
bar_height = theme.bar.height

local function add_line(s)
    table.insert(lines, s)
    if #lines > 200 then table.remove(lines, 1) end
end

add_line("shell  F5")

function print(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    add_line(table.concat(parts, "\t"))
end

local function run(code)
    local chunk, err = load(code)
    if not chunk then
        add_line("error: " .. tostring(err))
        gfx.invalidate()
        return
    end
    local ok, res = pcall(chunk)
    if not ok then
        add_line("error: " .. tostring(res))
    elseif res ~= nil then
        add_line(tostring(res))
    end
    gfx.invalidate()
end

local function repl_render()
    if not repl_visible then return end
    local w = find_win("repl")
    if not w or w.ws ~= current_ws then return end
    local tx = w.x + theme.wm.border + 6
    local ty = w.y + theme.wm.border + theme.wm.title_h + 6
    local row_h = 18
    local max_lines = math.floor((w.h - theme.wm.title_h - 12) / row_h)
    local col = tx
    local i = math.max(1, #lines - max_lines + 1)
    while i <= #lines do
        gfx.draw_text(lines[i], col, ty, theme.text)
        ty = ty + row_h
        i = i + 1
    end
    local prompt = "> " .. current
    gfx.draw_text(prompt, col, ty, theme.text)
    local cx = col + (2 + cursor) * glyph_w
    gfx.draw_rect(cx, ty, glyph_w, glyph_h, theme.accent)
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
