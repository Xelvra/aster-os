-- Lua side of the M7 Fáze C benchmark (spec/roadmap.md): the identical
-- Mandelbrot escape-time grid as the wasm twin (src/kernel/apps/bench.zig).
-- Runs once at spawn (top-level code, no update/render) under the normal
-- instruction budget (lua.zig, 10M VM instructions) — the timing is measured
-- by the kernel around the spawn call, not in here.
local width = 64
local height = 64
local max_iter = 50

local checksum = 0
for py = 0, height - 1 do
    local cy = -1.5 + py * (3.0 / height)
    for px = 0, width - 1 do
        local cx = -2.0 + px * (3.0 / width)
        local x, y = 0.0, 0.0
        local iter = 0
        while x * x + y * y <= 4.0 and iter < max_iter do
            local x_temp = x * x - y * y + cx
            y = 2.0 * x * y + cy
            x = x_temp
            iter = iter + 1
        end
        checksum = checksum + iter
    end
end

debug.write("BENCH LUA CHECKSUM " .. checksum)
