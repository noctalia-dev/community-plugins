--!nonstrict
-- Single owner of the calendar data. The panel and bar widget run in separate
-- VMs, so they never touch the file: the panel sends commands through
-- noctalia.state ("command"), this service validates them, updates the JSON
-- file in the plugin data dir, and publishes the result as state ("calendar").

local store = require("./store.luau")

local data = nil
local serial = 0
local rev = 0
local lastNonce = nil

local function dataPath()
    local dir = noctalia.pluginDataDir()
    if dir == nil or dir == "" then
        return nil
    end
    return dir .. "/calendar.json"
end

local function publish()
    rev += 1
    noctalia.state.set("calendar", {
        rev = rev,
        categories = data.categories,
        events = data.events,
    })
end

local function save()
    local path = dataPath()
    if path == nil then
        noctalia.notifyError("Calendar", "No plugin data directory; changes are not saved")
        return
    end
    local encoded, encodeErr = noctalia.json.encode({
        version = 1,
        categories = data.categories,
        events = data.events,
    }, true)
    if encoded == nil then
        noctalia.notifyError("Calendar", "Could not encode data: " .. tostring(encodeErr))
        return
    end
    local ok, err = noctalia.writeFile(path, encoded)
    if not ok then
        noctalia.notifyError("Calendar", "Could not save calendar.json: " .. tostring(err))
    end
end

local function load()
    local path = dataPath()
    if path ~= nil and noctalia.fileExists(path) then
        local raw = noctalia.readFile(path)
        if type(raw) == "string" and raw ~= "" then
            local decoded = noctalia.json.decode(raw)
            if type(decoded) == "table"
                and type(decoded.categories) == "table"
                and #decoded.categories > 0
            then
                if type(decoded.events) ~= "table" then
                    decoded.events = {}
                end
                return decoded
            end
            -- Unreadable file: keep a copy instead of silently overwriting it.
            noctalia.writeFile(path .. ".corrupt-" .. noctalia.formatTime("%s"), raw)
            noctalia.notifyError("Calendar", "calendar.json was unreadable; started fresh (copy kept)")
        end
    end
    return store.defaultData()
end

local function newId(prefix)
    serial += 1
    return prefix .. tostring(noctalia.nowMs()) .. "-" .. tostring(serial)
end

local function findCategory(id)
    for _, cat in ipairs(data.categories) do
        if cat.id == id then
            return cat
        end
    end
    return nil
end

local function validColor(color)
    return type(color) == "string" and string.match(color, "^#%x%x%x%x%x%x$") ~= nil
end

local handlers = {}

function handlers.add_event(a)
    local title = string.sub(store.trim(a.title), 1, 120)
    if title == "" then
        return false
    end
    if type(a.date) ~= "string" or string.match(a.date, "^%d%d%d%d%-%d%d%-%d%d$") == nil then
        return false
    end
    local cat = findCategory(a.cat) or data.categories[1]
    local allDay = a.allDay == true
    local start = math.floor(tonumber(a.start) or 0)
    local duration = math.floor(tonumber(a.duration) or 60)
    if allDay then
        start, duration = 0, 0
    else
        start = math.max(0, math.min(1439, start))
        duration = math.max(1, math.min(1440, duration))
    end
    table.insert(data.events, {
        id = newId("e"),
        title = title,
        date = a.date,
        start = start,
        duration = duration,
        allDay = allDay,
        cat = cat.id,
    })
    return true
end

function handlers.delete_event(a)
    for i, ev in ipairs(data.events) do
        if ev.id == a.id then
            table.remove(data.events, i)
            return true
        end
    end
    return false
end

function handlers.add_category(a)
    local name = string.sub(store.trim(a.name), 1, 40)
    if name == "" then
        return false
    end
    local color = store.PALETTE[(#data.categories % #store.PALETTE) + 1]
    table.insert(data.categories, {
        id = newId("c"),
        name = name,
        color = color,
        visible = true,
    })
    return true
end

function handlers.rename_category(a)
    local cat = findCategory(a.id)
    local name = string.sub(store.trim(a.name), 1, 40)
    if cat == nil or name == "" or cat.name == name then
        return false
    end
    cat.name = name
    return true
end

function handlers.set_color(a)
    local cat = findCategory(a.id)
    if cat == nil or not validColor(a.color) or cat.color == a.color then
        return false
    end
    cat.color = a.color
    return true
end

function handlers.set_visible(a)
    local cat = findCategory(a.id)
    if cat == nil then
        return false
    end
    cat.visible = a.visible == true
    return true
end

function handlers.delete_category(a)
    if #data.categories <= 1 then
        return false
    end
    for i, cat in ipairs(data.categories) do
        if cat.id == a.id then
            table.remove(data.categories, i)
            -- Events of the removed category move to the first remaining one.
            local fallback = data.categories[1].id
            for _, ev in ipairs(data.events) do
                if ev.cat == a.id then
                    ev.cat = fallback
                end
            end
            return true
        end
    end
    return false
end

local function onCommand(cmd)
    if type(cmd) ~= "table" or cmd.nonce == nil or cmd.nonce == lastNonce then
        return
    end
    lastNonce = cmd.nonce
    local handler = handlers[cmd.action]
    if handler == nil then
        return
    end
    if handler(cmd) then
        save()
        publish()
    end
end

data = load()
-- Ignore a command left over in shared state from before this (re)load.
local previous = noctalia.state.get("command")
if type(previous) == "table" then
    lastNonce = previous.nonce
end
noctalia.state.watch("command", onCommand)
publish()
