--!nonstrict
local records = require("./records.luau")
local Module = {}

function Module.new(dataDir)
    local M = {}
    local validId = records.validId
    local validRecords, contains, without, record = records.validRecords, records.contains, records.without, records.record
    local libraryPath = dataDir and (dataDir .. "/library.json") or nil
    M.data = {version = 1, later = {}, history = {}, favorites = {}, channelPlays = {}}
    M.error = nil
    local HISTORY_LIMIT = 500
    local function validPlays(plays)
        if type(plays) ~= "table" then return false end
        for id, count in pairs(plays) do
            if not validId(id, true) or type(count) ~= "number" or count < 0
                or count >= math.huge or count % 1 ~= 0 then return false end
        end
        return true
    end
    local function validQueueEvents(events)
        if type(events) ~= "table" then return false end
        for id, token in pairs(events) do
            if not validId(id, false) or type(token) ~= "string" then return false end
        end
        return true
    end
    local function reloadLibrary()
        M.data = {version = 1, later = {}, history = {}, favorites = {}, channelPlays = {}}
        M.error = nil
        if libraryPath and noctalia.fileExists(libraryPath) then
            local body = noctalia.readFile(libraryPath)
            local ok, saved = pcall(noctalia.json.decode, body or "")
            if ok and type(saved) == "table" and saved.version == 1
                and validRecords(saved.later) and validRecords(saved.history)
                and (saved.favorites == nil or validRecords(saved.favorites, true))
                and (saved.channelPlays == nil or validPlays(saved.channelPlays))
                and (saved.queueEvents == nil or validQueueEvents(saved.queueEvents)) then
                -- Existing libraries acquire favorites without rewriting their video records.
                saved.favorites = saved.favorites or {}
                saved.channelPlays = saved.channelPlays or {}
                M.data = saved
            else
                -- Preserve unreadable or incompatible data instead of overwriting it.
                M.error = noctalia.tr("error.library_read")
            end
        end
    end
    reloadLibrary()
    local function saveLibrary(later, history, favorites, channelPlays, queueEvents)
        if M.error then noctalia.notifyError(M.error); return false end
        if not libraryPath or not noctalia.mkdirAll(dataDir) then
            noctalia.notifyError(noctalia.tr("error.library_storage")); return false
        end
        local receipts = {}
        for id, token in pairs(queueEvents or M.data.queueEvents or {}) do
            if contains(history, id) then receipts[id] = token end
        end
        local updated = {version = 1, later = later, history = history, favorites = favorites or M.data.favorites,
            channelPlays = channelPlays or M.data.channelPlays,
            queueEvents = receipts}
        local ok, body = pcall(noctalia.json.encode, updated)
        local temporary = libraryPath .. ".part"
        if ok and type(body) == "string" and noctalia.writeFile(temporary, body)
            and noctalia.renameFile(temporary, libraryPath) then
            M.data = updated
            return true
        end
        noctalia.removeFile(temporary)
        noctalia.notifyError(noctalia.tr("error.library_save"))
        return false
    end
    local function resetLibrary()
        if not M.error or not libraryPath then return false end
        local body = noctalia.readFile(libraryPath)
        if type(body) ~= "string" then noctalia.notifyError(noctalia.tr("library.backup_error")); return false end
        local base = libraryPath .. ".backup-" .. tostring(noctalia.nowMs())
        local backup, suffix = base, 0
        while noctalia.fileExists(backup) do
            suffix = suffix + 1
            backup = base .. "-" .. suffix
        end
        local temporary = backup .. ".part"
        if not noctalia.writeFile(temporary, body) or not noctalia.renameFile(temporary, backup) then
            noctalia.removeFile(temporary)
            noctalia.notifyError(noctalia.tr("library.backup_error")); return false
        end
        local previousError = M.error
        M.error = nil
        if not saveLibrary({}, {}, {}, {}, {}) then M.error = previousError; return false end
        noctalia.notify(noctalia.tr("library.reset_done"), backup)
        return true
    end
    local function sortedFavorites()
        local favorites = {}
        for _, item in ipairs(M.data.favorites) do table.insert(favorites, item) end
        table.sort(favorites, function(a, b)
            local ac, bc = M.data.channelPlays[a.id] or 0, M.data.channelPlays[b.id] or 0
            if ac ~= bc then return ac > bc end
            if a.title ~= b.title then return a.title < b.title end
            return a.id < b.id
        end)
        return favorites
    end
    local function rememberPlayed(item, eventToken)
        if not item then return end
        if eventToken and M.data.queueEvents and M.data.queueEvents[item.id] == eventToken then return true end
        local history = without(M.data.history, item.id)
        table.insert(history, 1, record(item))
        while #history > HISTORY_LIMIT do table.remove(history) end
        local plays = {}
        for id, count in pairs(M.data.channelPlays) do plays[id] = count end
        if item.channelId then plays[item.channelId] = (plays[item.channelId] or 0) + 1 end
        local later = {}
        for _, known in ipairs(M.data.later) do
            table.insert(later, known.id == item.id and record(item) or known)
        end
        local events = {}
        for id, token in pairs(M.data.queueEvents or {}) do events[id] = token end
        if eventToken then events[item.id] = eventToken end
        -- Keep receipts only for retained history entries so they cannot grow without bound.
        for id in pairs(events) do if not contains(history, id) then events[id] = nil end end
        return saveLibrary(later, history, nil, plays, events)
    end

    M.save, M.sortedFavorites, M.rememberPlayed = saveLibrary, sortedFavorites, rememberPlayed
    M.reload, M.reset = reloadLibrary, resetLibrary
    return M
end

return Module
