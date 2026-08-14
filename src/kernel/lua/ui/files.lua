-- files.lua - minimal file browser inside a shell window (M7.1.5). Lists a
-- directory through file.dir, navigates into subdirectories and views file
-- contents through file.open/read. State is kept as globals so an F5 reload
-- does not lose the current directory.

fs_path = fs_path or "/"
fs_entries = fs_entries or {}
fs_sel = fs_sel or 1
fs_viewing = fs_viewing or false
fs_view_name = fs_view_name or ""
fs_view_content = fs_view_content or ""
fs_error = fs_error or ""
fs_row_h = 18

function files_open(path)
    fs_path = path
    fs_viewing = false
    fs_sel = 1
    local entries = file.dir(path)
    if not entries then
        fs_entries = {}
        fs_error = "cannot read " .. path
        gfx.invalidate()
        return
    end
    fs_error = ""
    fs_entries = entries
    gfx.invalidate()
end

function files_view(name)
    local full = fs_path .. name
    if fs_path:sub(-1) ~= "/" then full = fs_path .. "/" .. name end
    local h = file.open(full)
    if not h then
        fs_error = "cannot open " .. name
        gfx.invalidate()
        return
    end
    local content = ""
    while true do
        local chunk = file.read(h, 4096)
        if not chunk or chunk == "" then break end
        content = content .. chunk
    end
    file.close(h)
    fs_viewing = true
    fs_view_name = name
    fs_view_content = content
    fs_error = ""
    gfx.invalidate()
end

function files_up()
    if fs_viewing then
        fs_viewing = false
        return
    end
    local t = fs_path
    if t == "/" or t == "" then return end
    if t:sub(-1) == "/" then t = t:sub(1, -2) end
    local parent = t:match("^(.*)/[^/]*$")
    if parent == nil or parent == "" then parent = "/" end
    files_open(parent)
end

local function files_render()
    local w = find_win("files")
    if not w or w.ws ~= current_ws then return end
    local tx = w.x + theme.wm.border + 6
    local ty = w.y + theme.wm.border + theme.wm.title_h + 6
    gfx.draw_text("files  " .. fs_path, tx, ty, theme.text_dim)
    ty = ty + fs_row_h
    local rows = math.floor((w.h - theme.wm.title_h - 12) / fs_row_h) - 1
    if rows < 1 then rows = 1 end
    if fs_error ~= "" then
        gfx.draw_text(fs_error, tx, ty, theme.accent)
        return
    end
    if fs_viewing then
        gfx.draw_text(fs_view_name, tx, ty, theme.text)
        ty = ty + fs_row_h
        local lines = {}
        for line in (fs_view_content .. "\n"):gmatch("(.-)\n") do
            lines[#lines + 1] = line
        end
        for i = 1, math.min(#lines, rows - 1) do
            gfx.draw_text(lines[i], tx, ty, theme.text)
            ty = ty + fs_row_h
        end
        return
    end
    -- List mode: scroll so the selected entry stays visible. Hidden files
    -- (leading dot, e.g. the .theme.bak config backup) are shown in the dim
    -- color so it is visually clear they are not regular editable files.
    local first = 1
    if fs_sel > rows then first = fs_sel - rows + 1 end
    for i = first, math.min(#fs_entries, first + rows - 1) do
        local e = fs_entries[i]
        local color
        if i == fs_sel then
            color = theme.accent
        elseif e.name:sub(1, 1) == "." then
            color = theme.text_dim
        else
            color = theme.text
        end
        local label = e.name
        if e.dir then label = label .. "/" end
        gfx.draw_text(label, tx, ty, color)
        ty = ty + fs_row_h
    end
end
