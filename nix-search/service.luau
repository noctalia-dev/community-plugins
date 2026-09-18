local REFRESH = 24 * 3600
local pending = false
local keysPath: string? = nil

local function shellQupte(s: string): string
    local q = s:gsub("'", "'\\''")
    return "'" .. q .. "'"
end

local function logX(s: string)
    noctalia.log("[INDEX_SERVICE] " .. s)
end

local function refresh()
    if keysPath == nil or pending then
        return
    end
    if noctalia.fileExists(keysPath .. ".tmp") then
        return
    end
    pending = true
    logX("refreshing nix-search-tv keys")
    noctalia.runAsync("setsid -f sh -c " .. shellQupte(
        "nix-search-tv print > " .. shellQupte(keysPath .. ".tmp")
        .. " && mv " .. shellQupte(keysPath .. ".tmp") .. " " .. shellQupte(keysPath)))
end

local function init()
    if not noctalia.commandExists("nix-search-tv") then
        noctalia.notifyError("Nix Search", "nix-search-tv is not installed")
        return
    end
    local dir = noctalia.pluginDataDir()
    if dir == nil then
        return
    end
    local path = dir .. "/keys.txt"
    keysPath = path
    local info = noctalia.fileInfo(path)
    if info == nil or info.size <= 2 or os.time() - info.mtime > REFRESH then
        refresh()
    else
        noctalia.state.set("keys-ready", info.mtime)
    end
end

function update()
    noctalia.setUpdateInterval(5000)
    if pending and keysPath ~= nil then
        local info = noctalia.fileInfo(keysPath)
        if info ~= nil and info.size > 2 and not noctalia.fileExists(keysPath .. ".tmp") then
            pending = false
            logX("keys ready, " .. info.size .. " bytes")
            noctalia.state.set("keys-ready", info.mtime)
        end
    end
end

function onIpc(event: string)
    if event == "refresh" then refresh() end
end

init()
