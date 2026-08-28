--!nonstrict

local entries = {}
local scanInFlight = false

local function publish()
    noctalia.state.set("entries", entries)
end

local function shellEscape(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function passwordStoreDir()
    local dir = noctalia.getenv("PASSWORD_STORE_DIR")

    if dir and dir ~= "" then
        return noctalia.expandPath(dir)
    end

    return noctalia.expandPath("~/.password-store")
end

local function rebuild()
    if scanInFlight then
        return
    end

    local root = passwordStoreDir()

    if not noctalia.fileExists(root) then
        noctalia.notifyError("Pass", noctalia.tr("notification.store_not_found"))
        return
    end

    -- Directory traversal can exceed Noctalia's callback CPU budget on large stores.
    -- Run it in a subprocess and only build the small launcher cache in Luau.
    local command = "cd " .. shellEscape(root)
        .. " && find . -mindepth 1"
        .. " \\( -type d -name '.*' -prune \\)"
        .. " -o \\( -name '*.gpg' ! -name '.*' -print0 \\)"

    scanInFlight = true

    local accepted = noctalia.runAsync(command, function(result)
        scanInFlight = false

        if result.exitCode ~= 0 then
            noctalia.log("Failed to scan " .. root .. ": " .. (result.stderr or "unknown error"))
            return
        end

        if result.stdoutTruncated then
            noctalia.log("Failed to scan " .. root .. ": command output was truncated")
            return
        end

        local nextEntries = {}

        for file in (result.stdout or ""):gmatch("([^%z]+)%z") do
            -- find returns paths as ./folder/entry.gpg.
            local path = file:sub(3, -5)
            local title = path
            local subtitle = ""
            local lastSlash = path:match("^.*()/")

            if lastSlash then
                subtitle = path:sub(1, lastSlash - 1)
                title = path:sub(lastSlash + 1)
            end

            table.insert(nextEntries, {
                id = path,
                path = path,
                title = title,
                subtitle = subtitle,
            })
        end

        table.sort(nextEntries, function(a, b)
            return a.title:lower() < b.title:lower()
        end)

        entries = nextEntries
        publish()
    end, 60000)

    if not accepted then
        scanInFlight = false
        noctalia.log("Failed to start password-store scan")
    end
end

function update()
    rebuild()
end

local refresh = noctalia.getConfig("refresh_interval") or 30

noctalia.setUpdateInterval(refresh * 1000)

rebuild()
