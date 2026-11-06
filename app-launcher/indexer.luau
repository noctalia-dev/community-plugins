--!nonstrict
-- Background indexer for the App Launcher panel.
-- Reading .desktop files and resolving icons inside the panel blows the per-call CPU
-- budget, so this service does it a few apps per tick and shares the result through
-- plugin state:  "pinned" (list), "all" (list), "ready" (bool).
-- Entry shape: { id, name, exec, terminal, icon }

local SCAN_PER_TICK = 3
local TICK_MS = 20

-- Pinned apps: desktop entry ids (file name without .desktop). Edit this list.
local PINNED = {
    "org.gnome.DiskUtility",
    "com.shellyorg.shelly",
    "btrfs-assistant",
    "net.lutris.Lutris",
    "pacman-gui",
    "nm-connection-editor",
    "portmaster",
    "net.sonobus.SonoBus",
    "com.github.tchx84.Flatseal",
    "org.kde.filelight",
    "org.kde.kcalc",
    "io.gitlab.librewolf-community",
    "org.gnome.TextEditor",
    "org.gnome.Terminal",
    "org.gnome.Nautilus",
    "md.obsidian.Obsidian",
}

local DESKTOP_DIRS = {
    "~/.local/share/applications/",
    "~/.local/share/flatpak/exports/share/applications/",
    "/usr/local/share/applications/",
    "/usr/share/applications/",
    "/var/lib/flatpak/exports/share/applications/",
}

-- Directories that hold Flatpak exports: an app found there is a Flatpak app.
local FLATPAK_DIRS = {
    ["~/.local/share/flatpak/exports/share/applications/"] = true,
    ["/var/lib/flatpak/exports/share/applications/"] = true,
}

-- ----------------------------------------------------------------- parsing

local function langKeys()
    local lang = noctalia.getenv("LC_MESSAGES") or noctalia.getenv("LANG") or ""
    local full = lang:match("^([%w_]+)")
    local short = lang:match("^(%a+)")
    local keys = {}
    if full and full ~= "" then
        table.insert(keys, "Name[" .. full .. "]")
    end
    if short and short ~= "" and short ~= full then
        table.insert(keys, "Name[" .. short .. "]")
    end
    return keys
end

local LANG_KEYS = langKeys()

local function stripFieldCodes(exec)
    local result = exec:gsub("%%(.?)( ?)", function(nextChar, trailingSpace)
        if nextChar:match("[fFuUdDnNickvm]") then
            return ""
        elseif nextChar == "%" then
            return "%" .. trailingSpace
        else
            return "%" .. nextChar .. trailingSpace
        end
    end)
    result = result:gsub(" +$", "")
    result = result:gsub("@@u *@@", "")
    return result
end

local function parseDesktop(content, appid, dir)
    local fields = {}
    local localized = {}
    local inEntry = false
    for line in content:gmatch("[^\r\n]+") do
        local section = line:match("^%s*%[(.-)%]%s*$")
        if section then
            if inEntry then
                break
            end
            inEntry = (section == "Desktop Entry")
        elseif inEntry then
            local key, value = line:match("^([^=]+)=(.*)$")
            if key then
                key = key:gsub("%s+$", "")
                if key:sub(1, 5) == "Name[" then
                    localized[key] = value
                elseif fields[key] == nil then
                    fields[key] = value
                end
            end
        end
    end

    if fields.Type ~= nil and fields.Type ~= "Application" then
        return nil
    end
    if fields.Exec == nil then
        return nil
    end

    local name = fields.Name
    for _, k in ipairs(LANG_KEYS) do
        if localized[k] then
            name = localized[k]
            break
        end
    end
    if name == nil or name == "" then
        name = appid
    end

    -- Flatpak: found in a flatpak exports directory, or the file says so itself.
    local flatpak = (dir ~= nil and FLATPAK_DIRS[dir] == true)
        or fields["X-Flatpak"] ~= nil
        or fields.Exec:find("flatpak run", 1, true) ~= nil

    return {
        id = appid,
        name = name,
        exec = stripFieldCodes(fields.Exec),
        terminal = (fields.Terminal == "true"),
        hidden = (fields.NoDisplay == "true" or fields.Hidden == "true"),
        flatpak = flatpak,
    }
end

local function withIcon(entry)
    local icon = noctalia.appIconPath(entry.id)
    entry.icon = icon or ""
    return entry
end

-- ----------------------------------------------------------------- indexing

local phase = "pinned" -- pinned -> scan -> done
local pIdx = 1
local pinnedList = {}
local cache = {} -- appid -> entry (so pinned apps are not parsed twice)
local queue = nil
local qIdx = 1
local allList = {}
local iconTodo = {}
local iIdx = 1

local pinIds = {} -- desktop ids of the pinned apps, in display order
local PIN_FILE = "pinned.json" -- relative to the plugin directory

-- Pinned ids come from pinned.json when it exists, otherwise from the PINNED defaults.
local function loadPinIds()
    pinIds = {}
    local content = noctalia.readFile(PIN_FILE)
    if content and content ~= "" then
        local data = noctalia.json.decode(content)
        if type(data) == "table" then
            for _, id in ipairs(data) do
                if type(id) == "string" then
                    table.insert(pinIds, id)
                end
            end
            return
        end
    end
    for _, id in ipairs(PINNED) do
        table.insert(pinIds, id)
    end
end

local function resetState()
    loadPinIds()
    phase = "pinned"
    pIdx = 1
    pinnedList = {}
    cache = {}
    queue = nil
    qIdx = 1
    allList = {}
    iconTodo = {}
    iIdx = 1
    noctalia.setUpdateInterval(TICK_MS)
end

local function buildQueue()
    local seen = {}
    local q = {}
    for _, dir in ipairs(DESKTOP_DIRS) do
        local files = noctalia.listDir(dir)
        if files then
            for _, file in ipairs(files) do
                if file:sub(-8) == ".desktop" then
                    local appid = file:sub(1, -9)
                    if not seen[appid] then
                        seen[appid] = true -- earlier directories win
                        table.insert(q, { dir = dir, file = file, id = appid })
                    end
                end
            end
        end
    end
    queue = q
    qIdx = 1
end

local function stepPinned()
    local appid = pinIds[pIdx]
    pIdx = pIdx + 1
    for _, dir in ipairs(DESKTOP_DIRS) do
        local content = noctalia.readFile(dir .. appid .. ".desktop")
        if content then
            local entry = parseDesktop(content, appid, dir)
            if entry then
                entry.icon = ""
                cache[appid] = entry
                table.insert(pinnedList, entry)
                -- Icon lookup can be slow. The entry is already stored, so even if this
                -- call fails the app just keeps the glyph fallback.
                entry.icon = noctalia.appIconPath(appid) or ""
            end
            return
        end
    end
    noctalia.log("app-launcher: no desktop entry for pinned app " .. appid)
end

-- Scan step: read + parse only. Icons are resolved afterwards, one per tick.
local function stepScan()
    local item = queue[qIdx]
    qIdx = qIdx + 1
    local entry = cache[item.id]
    local fresh = false
    if entry == nil then
        local content = noctalia.readFile(item.dir .. item.file)
        if content then
            entry = parseDesktop(content, item.id, item.dir)
            if entry then
                entry.icon = ""
                fresh = true
            end
        end
    end
    if entry and not entry.hidden then
        table.insert(allList, entry)
        if fresh then
            table.insert(iconTodo, entry)
        end
    end
end

function update()
    if phase == "done" then
        return
    end

    if phase == "pinned" then
        if pIdx > #pinIds then
            noctalia.state.set("pinned", pinnedList)
            phase = "scan"
        else
            stepPinned()
        end
        return
    end

    if phase == "scan" then
        if queue == nil then
            buildQueue()
            return
        end
        for _ = 1, SCAN_PER_TICK do
            if qIdx > #queue then
                table.sort(allList, function(a, b)
                    return a.name:lower() < b.name:lower()
                end)
                noctalia.state.set("all", allList) -- first publish: names, no icons yet
                phase = "icons"
                return
            end
            stepScan()
        end
        return
    end

    -- phase "icons": one icon lookup per tick, each in its own CPU budget
    if iIdx > #iconTodo then
        noctalia.state.set("all", allList) -- final publish, with icons
        noctalia.state.set("pinned", pinnedList) -- icons of freshly pinned apps
        noctalia.state.set("ready", true)
        noctalia.log("app-launcher: indexed " .. #allList .. " apps")
        phase = "done"
        noctalia.setUpdateInterval(600000)
        return
    end
    local entry = iconTodo[iIdx]
    iIdx = iIdx + 1
    entry.icon = noctalia.appIconPath(entry.id) or ""
end

-- ---------------------------------------------------------------- pin / unpin

local lastPinRequest = nil

noctalia.state.watch("pin_request", function(req)
    if type(req) ~= "table" or req.id == nil then
        return
    end
    if phase == "pinned" then
        return -- the pinned list is still being built
    end
    local stamp = tostring(req.seq) .. ":" .. tostring(req.t)
    if stamp == lastPinRequest then
        return
    end
    lastPinRequest = stamp

    local at = nil
    for i, id in ipairs(pinIds) do
        if id == req.id then
            at = i
            break
        end
    end

    if req.action == "unpin" then
        if at then
            table.remove(pinIds, at)
            for i, entry in ipairs(pinnedList) do
                if entry.id == req.id then
                    table.remove(pinnedList, i)
                    break
                end
            end
        end
    elseif at == nil then
        local entry = cache[req.id]
        if entry == nil then
            for _, e in ipairs(allList) do
                if e.id == req.id then
                    entry = e
                    break
                end
            end
        end
        if entry then
            table.insert(pinIds, req.id)
            table.insert(pinnedList, entry)
        end
    end

    noctalia.writeFile(PIN_FILE, noctalia.json.encode(pinIds))
    noctalia.state.set("pinned", pinnedList)
end)

-- ------------------------------------------------------------------ refresh

-- "ready" = false tells the panel that a rebuild is running (the Refresh button shows
-- "Refreshing…"); it goes back to true when the icons phase finishes.
local function startReindex()
    noctalia.state.set("ready", false)
    resetState()
end

-- Refresh button in the panel: it publishes "refresh_request" through plugin state.
local lastRefreshRequest = nil

noctalia.state.watch("refresh_request", function(req)
    if type(req) ~= "table" then
        return
    end
    local stamp = tostring(req.seq) .. ":" .. tostring(req.t)
    if stamp == lastRefreshRequest then
        return
    end
    lastRefreshRequest = stamp
    startReindex()
end)

-- Re-index on demand: noctalia msg plugin xrtsx/app-launcher:indexer all refresh
function onIpc(event, payload)
    if event == "refresh" then
        startReindex()
    end
end

resetState()
