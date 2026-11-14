--!nonstrict
-- Read os-release as data, never as a shell script. No subprocesses or downloads.
local M = {}

local function releaseFields(contents)
    local fields = {}
    for line in (contents or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([A-Z_]+)%s*=%s*(.-)%s*$")
        if key then
            local quote = value:sub(1, 1)
            if quote == '"' or quote == "'" then
                if value:sub(-1) == quote then
                    value = value:sub(2, -2)
                    if quote == '"' then value = value:gsub('\\(["\\$`])', '%1') end
                    fields[key] = value
                end
            else
                fields[key] = value
            end
        end
    end
    return fields
end

function M.path(size)
    -- /etc takes precedence; /usr/lib is the os-release specification's fallback.
    local contents = noctalia.readFile("/etc/os-release")
    if contents == nil then contents = noctalia.readFile("/usr/lib/os-release") end
    local release = releaseFields(contents)
    local names, seen = {}, {}
    local function add(name)
        if name and name ~= "" and not seen[name] and name:match("^[%w_.-]+$") then
            seen[name] = true
            table.insert(names, name)
        end
    end
    local function distro(id)
        if not id or not id:match("^[a-z0-9_.-]+$") then return end
        add(id)
        add("distributor-logo-" .. id)
        add(id .. "-logo")
        -- os-release uses arch/artix, while icon packages often spell out Linux.
        if id == "arch" or id == "artix" then
            add(id .. "linux")
            add(id .. "linux-logo")
            add("distributor-logo-" .. id .. "linux")
        end
    end
    add(release.LOGO)
    distro(release.ID)
    for id in (release.ID_LIKE or ""):gmatch("%S+") do distro(id) end
    add("distributor-logo")
    add("system-logo")

    for _, name in ipairs(names) do
        local path = noctalia.appIconPath(name, size)
        if path and path ~= "" and noctalia.fileExists(path) then return path end
        -- Some distributions ship a top-level icon outside indexed icon themes.
        for _, directory in ipairs({ "/usr/share/icons/", "/usr/share/pixmaps/" }) do
            for _, extension in ipairs({ ".svg", ".png", ".xpm" }) do
                path = directory .. name .. extension
                if noctalia.fileExists(path) then return path end
            end
        end
    end
    return nil
end

return M
