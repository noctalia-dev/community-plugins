--!nonstrict
-- storage — todo.json persistence, shared with panel.luau via require()
-- (relative same-plugin import, plugin_api >= 22). Pure(ish) module: no UI
-- state, no closures over the caller's `items`/`sortMode` — every call takes
-- and returns plain values, so panel.luau's rendering/editing state can never
-- drift from what actually got written to disk.
--
-- File format is an object { version, sort, hideCompleted, showCount, tasks }:
-- `tasks` is the array, ALWAYS in manual order, `sort` records the chosen
-- display mode, `hideCompleted` the header toggle that hides done rows, and
-- `showCount` the header toggle for the bar widget's task-count label. A
-- legacy plain-array file (no `tasks` key) is still read, treated as manual
-- order with sort defaulting to "priority", hideCompleted to false and
-- showCount to true.

local RANK = { important = 1, medium = 2, low = 3 }

local function isBlank(text)
    return noctalia.string.trim(text or "") == ""
end

local function normalizePriority(value)
    return RANK[value] ~= nil and value or "medium"
end

local storage = {}

-- Reads filePath and returns { items, sortMode, nextId, hideCompleted,
-- showCount }. Never errors on a missing/empty/malformed file — callers get a
-- fresh empty list instead.
function storage.load(filePath)
    local items = {}
    local nextId = 1
    local sortMode = "priority"
    local hideCompleted = false
    local showCount = true
    local raw = noctalia.readFile(filePath)
    if raw ~= nil and raw ~= "" then
        local decoded = noctalia.json.decode(raw)
        local list = nil
        if type(decoded) == "table" then
            if decoded.tasks ~= nil then
                if decoded.sort == "manual" or decoded.sort == "priority" then
                    sortMode = decoded.sort
                end
                hideCompleted = decoded.hideCompleted == true
                showCount = decoded.showCount ~= false
                list = decoded.tasks
            else
                list = decoded
            end
        end
        if type(list) == "table" then
            for _, entry in ipairs(list) do
                if type(entry) == "table" then
                    local id = tonumber(entry.id) or nextId
                    table.insert(items, {
                        id = id,
                        text = type(entry.text) == "string" and entry.text or "",
                        priority = normalizePriority(entry.priority),
                        done = entry.done == true,
                    })
                    if id >= nextId then
                        nextId = id + 1
                    end
                end
            end
        end
    end
    return {
        items = items,
        sortMode = sortMode,
        nextId = nextId,
        hideCompleted = hideCompleted,
        showCount = showCount,
    }
end

-- Writes filePath. Blank (in-progress) tasks are dropped before they ever
-- reach disk. Returns ok, err — the caller decides how to surface a failure.
function storage.save(filePath, items, sortMode, hideCompleted, showCount)
    local toStore = {}
    for _, item in ipairs(items) do
        if not isBlank(item.text) then
            table.insert(toStore, item)
        end
    end
    local encoded = noctalia.json.encode({
        version = 2,
        sort = sortMode,
        hideCompleted = hideCompleted == true,
        showCount = showCount ~= false,
        tasks = toStore,
    }, true)
    if encoded == nil then
        return false, nil
    end
    return noctalia.writeFile(filePath, encoded)
end

return storage
