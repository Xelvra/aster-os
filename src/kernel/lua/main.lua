-- main.lua - Aster OS interactive Lua REPL (M4)
-- Type Lua code, Enter runs it. print() writes to the screen.
-- Character mapping is done by the kernel input layout, not here.

local lines = {}
local current = ""
local col = 8
local row_h = 18
local max_lines = 24

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
        return
    end
    local ok, res = pcall(chunk)
    if not ok then
        add_line("error: " .. tostring(res))
    elseif res ~= nil then
        add_line(tostring(res))
    end
end

function update()
    local ev = input.next_event()
    if not ev then return end
    if ev.type ~= "key" or not ev.pressed then return end
    local code = ev.code
    if code == "enter" then
        add_line("> " .. current)
        run(current)
        current = ""
    elseif code == "backspace" then
        if #current > 0 then
            current = string.sub(current, 1, #current - 1)
        end
    elseif ev.char then
        current = current .. ev.char
    end
end

function render()
    gfx.fill_screen(0x000000)
    local ty = 4
    for i = 1, #lines do
        gfx.draw_text(lines[i], col, ty, 0xFFFFFF)
        ty = ty + row_h
    end
    gfx.draw_text("> " .. current, col, ty, 0xFFFFFF)
end
