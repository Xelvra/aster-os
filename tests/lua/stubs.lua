-- tests/lua/stubs.lua — host-test stubs for the Lua shell.
--
-- The kernel shell (src/kernel/lua/ui/*.lua) talks to the kernel through
-- globals (gfx.*, input.*, file.*, time, debug, sysmon, runtime). This file
-- replaces those with in-memory mocks so the shell logic can be exercised on
-- the host with a plain Lua interpreter. It is concatenated BEFORE the shell
-- modules (which run top-level code at load, so gfx.width/height must work
-- right away and the file mock must be an empty disk).
--
-- Window registry, SW/SH, window(), set_window_header/cursor and the launcher
-- are all declared by the shell modules themselves (locals in the same
-- concatenated chunk), so only the kernel-binding globals live here. Each
-- test scenario in run.lua overrides `file` with its own in-memory disk.

local function noop() end

_p = print

gfx = {
    width = function() return 1280 end,
    height = function() return 720 end,
    draw_rect = noop, round_rect = noop, rect_border = noop,
    gradient_border = noop, draw_text = noop, fill_screen = noop,
    present = noop, invalidate = noop,
}

local evq = {}
-- Settable mouse state: tests position the cursor and press buttons/wheel via
-- _set_mouse before calling handle_mouse. mouse_wheel drains like the kernel.
local mx, my, mleft, mwheel = 0, 0, false, 0
input = {
    next_event = function() return table.remove(evq, 1) end,
    mouse_x = function() return mx end,
    mouse_y = function() return my end,
    mouse_left = function() return mleft end,
    mouse_right = function() return false end,
    mouse_middle = function() return false end,
    mouse_wheel = function() local v = mwheel; mwheel = 0; return v end,
    set_layout = noop, layout_name = function() return "us" end,
}

-- Position the mouse and set the left button / a wheel notch for the next
-- handle_mouse() call (wheel is drained on read).
function _set_mouse(x, y, left, wheel)
    mx, my = x, y
    mleft = left or false
    mwheel = wheel or 0
end

-- Settable clock for the double-click / fullscreen / bar tests. `ticks` is the
-- APIC tick counter (its rate differs per machine), `ms` the PIT-calibrated
-- real wall-clock milliseconds, `of_day_ms` the RTC-seeded time of day.
local _ticks = 0
local _ms = 0
local _of_day_ms = 0
function _set_ticks(n) _ticks = n end
function _set_ms(n) _ms = n end
function _set_of_day_ms(n) _of_day_ms = n end
time = {
    ticks = function() return _ticks end,
    ms = function() return _ms end,
    of_day_ms = function() return _of_day_ms end,
}
debug = { write = function() end }
sysmon = { ram_total_mb = function() return 512 end, ram_free_mb = function() return 300 end }
runtime = { reload = function() error("shell hot reload (F5)") end }

file = {
    open = function() return nil end, read = function() return nil end,
    write = noop, close = noop, truncate = noop, dir = function() return nil end,
    remove = noop, create = noop, rename = noop,
}

-- Helpers for the tests.
function keys_of(t)
    local r = {}
    for k in pairs(t) do r[#r + 1] = k end
    table.sort(r)
    return r
end
function _push_key(code, super, alt, shift, ctrl, char)
    evq[#evq + 1] = { type = "key", code = code, pressed = true,
        super = super or false, alt = alt or false, shift = shift or false,
        ctrl = ctrl or false, char = char }
end

-- In-memory disk for the file mock: a per-handle read cursor returns the
-- content once, then "" (the kernel file.read does the same at EOF), and
-- writes land in the table so a test can assert the on-disk state.
function make_disk(initial)
    local disk = initial or {}
    local reads = {}
    return {
        files = disk,
        mock = {
            open = function(p)
                if disk[p] ~= nil then return { p = p } end
                return nil
            end,
            read = function(h, n)
                if reads[h] == nil then reads[h] = 0 end
                reads[h] = reads[h] + 1
                if reads[h] == 1 then return disk[h.p] end
                return ""
            end,
            write = function(h, data) disk[h.p] = data end,
            truncate = function() end,
            close = noop,
            create = function(p) disk[p] = "" return { p = p } end,
            dir = function() return {} end,
            remove = noop,
            rename = noop,
        },
    }
end
