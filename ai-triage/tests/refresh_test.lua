-- Small host harness for the poller state machine and provider visual metadata.

local function read(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local values, watchers = {}, {}
local commands, callbacks = {}, {}
local notifications = {}
local decodedReport = { entries = {} }
local now = 5000
local intervals = {}
local savedHistory, corruptHistory = nil, false
local encodedValues, files, logs = {}, {}, {}
local archiveWrites = 0
local failArchive, failRename = false, false
local wallTime = os.time()
local function clone(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do copy[k] = clone(v) end
    return copy
end

local state = {
    get = function(key) return values[key] end,
    set = function(key, value)
        values[key] = value
        if watchers[key] then watchers[key](value) end
    end,
    watch = function(key, callback) watchers[key] = callback end,
}

local noctalia = {
    state = state,
    nowMs = function() return now end,
    getConfig = function(key) return key == "refresh_minutes" and 5 or nil end,
    setUpdateInterval = function(ms) intervals[#intervals + 1] = ms end,
    runAsync = function(command, callback)
        commands[#commands + 1] = command
        callbacks[#callbacks + 1] = callback
        return true
    end,
    pluginDataDir = function() return "/test" end,
    readFile = function() return savedHistory and "history" or "" end,
    writeFile = function(path, value)
        if path:find("weekly-reset-event-", 1, true) then
            if failArchive then return nil, "disk full" end
            archiveWrites = archiveWrites + 1
        end
        files[path] = value
        return true
    end,
    renameFile = function(from, to)
        if failRename and to:find("weekly-reset-event-", 1, true) then return false, "rename failed" end
        files[to], files[from] = files[from], nil
        if to == "/test/weekly-resets.json" then savedHistory = clone(encodedValues[files[to]]) end
        return true
    end,
    log = function(message) logs[#logs + 1] = message end,
    json = {
        decode = function(raw)
            if raw == "history" then
                if corruptHistory then error("invalid JSON") end
                return clone(savedHistory)
            end
            return decodedReport
        end,
        encode = function(value)
            local key = "encoded-" .. tostring(#encodedValues + 1)
            encodedValues[#encodedValues + 1] = key
            encodedValues[key] = clone(value)
            return key
        end,
    },
    notify = function(title, message)
        notifications[#notifications + 1] = { title = title, message = message }
    end,
    tr = function(key) return key end,
    string = { trim = function(value) return value end },
}

local env = setmetatable({ noctalia = noctalia }, { __index = _G })
env.os = setmetatable({ time = function(t) return t and os.time(t) or wallTime end }, { __index = os })
env.require = function(path)
    assert(path == "./shared.luau")
    return assert(load(read("shared.luau"), "shared", "t", env))()
end
local service = assert(load(read("service.luau"), "service", "t", env))
service()

assert(#callbacks == 1, "service should start one initial refresh")
env.onIpc("refresh")
assert(#callbacks == 1, "refresh while busy should be coalesced")
assert(values.refresh_queued == true, "coalesced refresh should be visible as queued")

now = 7000
callbacks[1]({ exitCode = 0, stdout = "{}", stderr = "" })
assert(#callbacks == 2, "queued refresh should start after the first callback")
assert(values.refresh_queued == false, "queued state should clear when refresh starts")
assert(values.polling == true, "queued refresh should become the active poll")
assert(intervals[#intervals] == 5 * 60 * 1000, "active refresh should restore the configured interval")

callbacks[2]({ timedOut = true, exitCode = 0, stdout = '{"entries":[]}', stderr = "" })
assert(values.error.code == "timed_out", "a timed-out command must not publish valid-looking stdout")

decodedReport = { entries = { { id = "antigravity", status = "error",
    error = "credentials error: Antigravity: no local server found.", metrics = {} } } }
now = 9000
env.onIpc("refresh")
callbacks[3]({ exitCode = 0, stdout = "{}", stderr = "" })
assert(values.report.entries[1].status == "error"
    and values.report.entries[1].stale ~= true,
    "Antigravity without an earlier reading must stay unavailable")

decodedReport = { entries = { { id = "openai", display_name = "Codex api_key=topsecret123", status = "ready",
    metrics = { { label = "Session", percent = 10 },
        { label = "Weekly", percent = 100 } } } } }
now = 11000
env.onIpc("refresh")
callbacks[4]({ exitCode = 0, stdout = "{}", stderr = "" })
assert(#notifications == 0, "quota changes must not send notifications")

decodedReport = { entries = {
    { id = "antigravity", display_name = "Antigravity", status = "ready",
      fetched_at = "2026-09-24T12:00:00Z", metrics = { { label = "Gemini", percent = 42 } } },
    { id = "openai", display_name = "Codex", status = "ready", metrics = {} },
} }
now = 13000
env.onIpc("refresh")
callbacks[5]({ exitCode = 0, stdout = "{}", stderr = "" })

decodedReport = { entries = {
    { id = "antigravity", display_name = "Antigravity", status = "error",
      error = "credentials error: Antigravity: no local server found.", metrics = {} },
    { id = "openai", display_name = "Codex", status = "ready", metrics = {} },
} }
now = 15000
env.onIpc("refresh")
callbacks[6]({ exitCode = 0, stdout = "{}", stderr = "" })
local cached = values.report.entries[1]
assert(cached.id == "antigravity" and cached.metrics[1].percent == 42
    and cached.fetched_at == "2026-09-24T12:00:00Z" and cached.stale == true,
    "a transient Antigravity failure should retain the dated last reading")
assert(values.report.entries[2].id == "openai", "other providers should keep fresh readings")

decodedReport = { entries = { { id = "antigravity", status = "error",
    error = "credentials error: Antigravity: no local server found.", metrics = {} } } }
now = 17000
env.onIpc("refresh")
callbacks[7]({ exitCode = 0, stdout = "{}", stderr = "" })
assert(values.report.entries[1].metrics[1].percent == 42
    and values.report.entries[1].stale == true,
    "consecutive local-server failures should not make Antigravity disappear")

decodedReport = { entries = {
    { id = "antigravity", display_name = "Antigravity", status = "ready",
      fetched_at = "2026-09-24T12:05:00Z", metrics = { { label = "Gemini", percent = 35 } } },
} }
now = 19000
env.onIpc("refresh")
callbacks[8]({ exitCode = 0, stdout = "{}", stderr = "" })
assert(values.report.entries[1].metrics[1].percent == 35
    and values.report.entries[1].stale ~= true,
    "the next healthy Antigravity reading should replace the cached one")

local function quota(reset, percent)
    return { entries = { { id = "openai", status = "ready", metrics = {
        { label = "Weekly", percent = percent, window_secs = 604800,
            reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", reset) },
    } } } }
end
local function complete(report, result)
    now = now + 2000
    decodedReport = report
    env.onIpc("refresh")
    callbacks[#callbacks](result or { exitCode = 0, stdout = "{}" })
end
local deadline = wallTime + 120
complete(quota(deadline, 50))
assert(intervals[#intervals] == 120000, "check at the weekly deadline rather than waiting five minutes")
assert(savedHistory.samples.openai["Weekly/604800"].percent == 50, "persist the weekly baseline")
wallTime = deadline
complete(nil, { timedOut = true })
assert(intervals[#intervals] == 60000, "failed deadline reads retry without a tight loop")
complete(quota(deadline, 50))
assert(intervals[#intervals] == 60000, "an unconfirmed expired date retries once a minute")
wallTime = wallTime + 1
complete(quota(wallTime + 604800, 0))
assert(savedHistory.events[#savedHistory.events].change.kind == "renewal")
assert(archiveWrites == 1 and #savedHistory.pending_events == 0, "archive the renewal once and clear the outbox")
local archivedRecord
for path, encoded in pairs(files) do
    if path:match("weekly%-reset%-event%-.+%.json$") then archivedRecord = encodedValues[encoded] end
end
assert(archivedRecord.change.previous_percent == 50 and archivedRecord.change.percent == 0
    and archivedRecord.change.previous_at and archivedRecord.change.detected_at == wallTime
    and archivedRecord.change.previous_source == "ai-usagebar"
    and archivedRecord.change.previous_reset_at == deadline,
    "the archive must preserve both observations and detection time")
assert(intervals[#intervals] == 300000, "confirmed new cycles restore normal polling")

-- Reload the service with only its disk history; subscribers need no old state.
values.report = nil
now = now + 2000
assert(load(read("service.luau"), "service", "t", env))()
callbacks[#callbacks]({ exitCode = 0, stdout = "{}" })
assert(values.report.entries[1].metrics[1].reset_observation.event.kind == "renewal",
    "a service restart must recover its last renewal explanation")
assert(archiveWrites == 1, "restarts and cached reads must not archive the same event again")

-- Failed writes stay in a durable outbox, including across service restarts.
failArchive = true
wallTime = wallTime + 300
complete(quota(wallTime + 604800 + 7200, 0))
assert(values.error.code == "" and #savedHistory.pending_events == 1,
    "archive failure must preserve the event for retry without blocking quota refresh")
assert(logs[#logs]:find("will retry", 1, true), "archive failure must be visible in host logs")
local pendingId = savedHistory.pending_events[1].archive_id
now = now + 2000
assert(load(read("service.luau"), "service", "t", env))()
failArchive, failRename = false, true
callbacks[#callbacks]({ exitCode = 0, stdout = "{}" })
assert(#savedHistory.pending_events == 1 and savedHistory.pending_events[1].archive_id == pendingId,
    "failed finalization must retain the same archive identity")
failRename = false
complete(decodedReport)
assert(#savedHistory.pending_events == 0, "a successful retry must empty the outbox")
local archivedCount = archiveWrites
complete(decodedReport)
assert(archiveWrites == archivedCount, "repeated polling must not duplicate archived events")

-- Existing v1 history is archived once on upgrade, with no invented old fields.
savedHistory.archive_initialized = nil
savedHistory.pending_events = nil
now = now + 2000
assert(load(read("service.luau"), "service", "t", env))()
callbacks[#callbacks]({ exitCode = 0, stdout = "{}" })
assert(savedHistory.archive_initialized and #savedHistory.pending_events == 0
    and archiveWrites == archivedCount + #savedHistory.events, "backfill the saved v1 events once")

-- Trimming the working history must never delete the permanent event archive.
local function archiveFileCount()
    local count = 0
    for path in pairs(files) do
        if path:match("weekly%-reset%-event%-.+%.json$") then count = count + 1 end
    end
    return count
end
local fileCount = archiveFileCount()
local movingReset = wallTime + 604800 + 7200
for i = 1, 35 do
    wallTime = wallTime + 300
    movingReset = movingReset + 7200
    complete(quota(movingReset, 0))
end
assert(#savedHistory.events == 32 and archiveFileCount() == fileCount + 35,
    "all events must survive even after the 32-entry working history is trimmed")
corruptHistory = true
now = now + 2000
assert(load(read("service.luau"), "service", "t", env))()
callbacks[#callbacks]({ exitCode = 0, stdout = "{}" })
assert(values.error.code == "" and values.report ~= nil, "corrupt history must not break polling")
corruptHistory = false

local sharedEnv = setmetatable({ noctalia = noctalia }, { __index = _G })
local shared = assert(load(read("shared.luau"), "shared", "t", sharedEnv))()
local incompleteFailure = shared.asFailure({})
assert(incompleteFailure.code == "" and incompleteFailure.detail == "",
    "an incomplete failure table should behave as no failure")
-- Read the offered providers out of the manifest rather than listing them again
-- here: a copy of the dropdown is a third place to keep the same set current, and
-- the one that silently stops matching. What is worth asserting is the relation
-- between the two -- every provider the settings editor offers has a glyph of its
-- own -- and that only holds if the list comes from the manifest itself.
local manifest = read("plugin.toml")
local vendorSetting = manifest:match('key = "vendor".-\n%s*\n') or manifest:match('key = "vendor".*')
local offered = {}
for value in vendorSetting:gmatch('{ value = "([^"]+)"') do
    if value ~= "auto" then offered[#offered + 1] = value end
end
assert(#offered > 10, "the vendor dropdown should have been read from the manifest")
for _, id in ipairs(offered) do
    -- "scale" is the fallback, so a provider still on it has no glyph of its own.
    assert(shared.providerGlyph(id) ~= "scale", "missing glyph for " .. id)
    assert(shared.providerDashboard(id) ~= nil, "missing quota service link for " .. id)
end

-- A named account is drawn with its provider's glyph, not the fallback.
assert(shared.providerGlyph("anthropic@gmail") == shared.providerGlyph("anthropic"),
    "an account should inherit the provider's glyph")
assert(shared.providerGlyph("unknown") == "scale", "an unknown provider falls back")

io.write("ok: refresh queue coalesced, timeouts rejected, provider visuals complete\n")
