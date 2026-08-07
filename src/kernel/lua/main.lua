-- main.lua - Aster OS interactive Lua REPL (M4)
-- Type Lua code, Enter runs it. print() writes to the screen.
-- Character mapping is done by the kernel input layout, not here.
--
-- Declarative theme: colors are data, changed live from the REPL.
-- Assigning a new value repaints the shell without a key press.

theme = {
    background = 0x000000,
    text = 0xFFFFFF,
    accent = 0x82DCCC,
}

local lines = {}
local current = ""
local col = 8
local row_h = 18
local max_lines = 24
local glyph_w = 8
local glyph_h = 16

local history = {}
local hist_idx = 0
local cursor = 0

local function insert_char(ch)
    current = string.sub(current, 1, cursor) .. ch .. string.sub(current, cursor + 1)
    cursor = cursor + 1
end

local function delete_char()
    if cursor > 0 then
        current = string.sub(current, 1, cursor - 1) .. string.sub(current, cursor + 1)
        cursor = cursor - 1
    end
end

local function history_up()
    if #history == 0 then return end
    if hist_idx == 0 then hist_idx = #history end
    hist_idx = hist_idx - 1
    if hist_idx == 0 then hist_idx = #history end
    current = history[hist_idx]
    cursor = #current
end

local function history_down()
    if #history == 0 then return end
    hist_idx = hist_idx + 1
    if hist_idx > #history then hist_idx = 1 end
    current = history[hist_idx]
    cursor = #current
end

local function add_line(s)
    table.insert(lines, s)
    if #lines > max_lines then table.remove(lines, 1) end
end

add_line("Aster OS Lua 5.4  Copyright (C) 1994-2025 Lua.org, PUC-Rio")

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
function update()
    local ev = input.next_event()
    if not ev then return end
    if ev.type ~= "key" or not ev.pressed then return end
    local code = ev.code
    if code == "enter" or code == "numpad_enter" then
        add_line("> " .. current)
        if current ~= "" then
            table.insert(history, current)
        end
        run(current)
        current = ""
        cursor = 0
    elseif code == "backspace" then
        delete_char()
    elseif code == "left" then
        if cursor > 0 then cursor = cursor - 1 end
    elseif code == "right" then
        if cursor < #current then cursor = cursor + 1 end
    elseif code == "up" then
        history_up()
    elseif code == "down" then
        history_down()
    elseif code == "home" then
        cursor = 0
    elseif code == "end" then
        cursor = #current
    elseif code == "delete" then
        if cursor < #current then
            current = string.sub(current, 1, cursor) .. string.sub(current, cursor + 2)
        end
    elseif ev.char then
        insert_char(ev.char)
    end
end

function render()
    gfx.fill_screen(theme.background)
    local ty = 4
    for i = 1, #lines do
        gfx.draw_text(lines[i], col, ty, theme.text)
        ty = ty + row_h
    end
    gfx.draw_text("> " .. current, col, ty, theme.text)
    local cx = col + (2 + cursor) * glyph_w
    gfx.draw_rect(cx, ty, glyph_w, glyph_h, theme.accent)
end
