--!nonstrict

local toml = require("./toml.luau")

local M = {}

local PROFILE_DIR =
    noctalia.expandPath("~/.config/noctalia/profiles")


local function endsWith(value, suffix)
    return #value >= #suffix
        and value:sub(-#suffix) == suffix
end


local function loadFile(filename)
    local path =
        PROFILE_DIR .. "/" .. filename

    local raw, err =
        noctalia.readFile(path)

    if not raw then
        noctalia.log(
            "Could not read profile "
                .. filename
                .. ": "
                .. tostring(err)
        )
        return nil
    end

    local ok, profile =
        pcall(toml.parse, raw)

    if not ok then
        noctalia.log(
            "Could not parse profile "
                .. filename
                .. ": "
                .. tostring(profile)
        )
        return nil
    end

    profile.id =
        filename:gsub("%.toml$", "")

    profile.filename = filename
    profile.name = profile.name or profile.id
    profile.icon = profile.icon or "palette"

    -- Backward compatibility:
    -- Existing profiles which already have a [schedule] section
    -- but no enabled flag remain automatic.
    if profile.schedule
        and profile.schedule.enabled == nil
    then
        profile.schedule.enabled =
            true
    end

    return profile
end


local function quote(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\")
    value = value:gsub('"', '\\"')
    value = value:gsub("\n", "\\n")
    value = value:gsub("\t", "\\t")

    return '"' .. value .. '"'
end


local function bool(value)
    return value and "true" or "false"
end


local function sortedKeys(t)
    local keys = {}

    for key, _ in pairs(t or {}) do
        table.insert(keys, key)
    end

    table.sort(keys)
    return keys
end


local function daysString(days)
    local parts = {}

    for _, day in ipairs(days or {}) do
        table.insert(parts, tostring(day))
    end

    return "[" .. table.concat(parts, ", ") .. "]"
end


function M.directory()
    return PROFILE_DIR
end


function M.ensureDirectory()
    local ok, err =
        noctalia.mkdirAll(PROFILE_DIR)

    if not ok then
        noctalia.log(
            "Could not create profile directory: "
                .. tostring(err)
        )
    end

    return ok
end


function M.loadAll()
    M.ensureDirectory()

    local result = {}

    local files, err =
        noctalia.listDir(PROFILE_DIR)

    if not files then
        noctalia.log(
            "Could not list profile directory: "
                .. tostring(err)
        )
        return result
    end

    table.sort(files)

    for _, filename in ipairs(files) do
        if endsWith(filename, ".toml") then
            local profile =
                loadFile(filename)

            if profile then
                table.insert(result, profile)
            end
        end
    end

    return result
end


function M.find(id)
    for _, profile in ipairs(M.loadAll()) do
        if profile.id == id then
            return profile
        end
    end

    return nil
end


function M.exists(id)
    if not id or id == "" then
        return false
    end

    return M.find(id) ~= nil
end


function M.save(profile)
    if not profile or not profile.id then
        return false, "Profile has no id"
    end

    M.ensureDirectory()

    local lines = {}

    table.insert(lines, "name = " .. quote(profile.name or profile.id))
    table.insert(lines, "icon = " .. quote(profile.icon or "palette"))
    table.insert(lines, "")
    table.insert(lines, "theme_mode = " .. quote(profile.theme_mode or "dark"))

    if profile.palette then
        table.insert(lines, "")
        table.insert(lines, "[palette]")
        table.insert(lines, "source = " .. quote(profile.palette.source or "wallpaper"))
        table.insert(lines, "name = " .. quote(profile.palette.name or "m3-content"))
    end

    if profile.wallpapers then
        table.insert(lines, "")
        table.insert(lines, "[wallpapers]")

        table.insert(
            lines,
            "directory = "
                .. quote(
                    profile.wallpapers.directory
                    or ""
                )
        )

        table.insert(
            lines,
            "default = "
                .. quote(
                    profile.wallpapers.default
                    or ""
                )
        )

        local monitors =
            profile.wallpapers.monitors or {}

        local monitorKeys =
            sortedKeys(monitors)

        if #monitorKeys > 0 then
            table.insert(lines, "")
            table.insert(lines, "[wallpapers.monitors]")

            for _, connector in ipairs(monitorKeys) do
                table.insert(
                    lines,
                    quote(connector)
                        .. " = "
                        .. quote(monitors[connector])
                )
            end
        end
    end

    if profile.schedule then
        table.insert(lines, "")
        table.insert(lines, "[schedule]")

        table.insert(
            lines,
            "enabled = "
                .. bool(
                    profile.schedule.enabled
                    == true
                )
        )

        table.insert(
            lines,
            "from = "
                .. quote(
                    profile.schedule.from
                    or ""
                )
        )

        table.insert(
            lines,
            "until = "
                .. quote(
                    profile.schedule["until"]
                    or ""
                )
        )

        table.insert(
            lines,
            "days = "
                .. daysString(
                    profile.schedule.days
                    or {}
                )
        )
    end

    table.insert(lines, "")

    local path =
        PROFILE_DIR
        .. "/"
        .. profile.id
        .. ".toml"

    return noctalia.writeFile(
        path,
        table.concat(lines, "\n")
    )
end


return M
