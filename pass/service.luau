--!nonstrict

local entries = {}

local function publish()
    noctalia.state.set("entries", entries)
end

local function passwordStoreDir()
    local dir = noctalia.getenv("PASSWORD_STORE_DIR")

    if dir and dir ~= "" then
        return noctalia.expandPath(dir)
    end

    return noctalia.expandPath("~/.password-store")
end

local function scan(dir, prefix)
    prefix = prefix or ""

    local names, err = noctalia.listDir(dir)

    if not names then
        noctalia.log("Failed to list " .. dir .. ": " .. tostring(err))
        return
    end

    for _, name in ipairs(names) do
        -- Ignore hidden files/directories (.git, .extensions, .gpg-id, ...)
        if name:sub(1, 1) ~= "." then
            local full = dir .. "/" .. name
            local info = noctalia.fileInfo(full)

            if info then
                if info.isDir then
                    scan(full, prefix .. name .. "/")

                elseif name:sub(-4) == ".gpg" then
                    local path = prefix .. name:sub(1, -5)

                    local title = path
                    local subtitle = ""

                    local lastSlash = path:match("^.*()/")

                    if lastSlash then
                        subtitle = path:sub(1, lastSlash - 1)
                        title = path:sub(lastSlash + 1)
                    end

                    table.insert(entries, {
                        id = path,
                        path = path,
                        title = title,
                        subtitle = subtitle,
                    })
                end
            end
        end
    end
end

local function rebuild()
    entries = {}

    local root = passwordStoreDir()

    if not noctalia.fileExists(root) then
        noctalia.notifyError("Pass", noctalia.tr("notification.store_not_found"))
        return
    end

    scan(root)

    table.sort(entries, function(a, b)
        return a.title:lower() < b.title:lower()
    end)

    publish()
end

function update()
    rebuild()
end

local refresh = noctalia.getConfig("refresh_interval") or 30

noctalia.setUpdateInterval(refresh * 1000)

rebuild()
