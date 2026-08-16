--!nonstrict
-- Headless poller: the single owner of `ai-usagebar usage --json`.
--
-- One call returns every configured vendor, so the capsules and the panel are
-- pure subscribers of noctalia.state and never spawn a process of their own.

-- `ai-usagebar` is a declared dependency, so it is expected on PATH.
local COMMAND = "ai-usagebar usage --json"

local function intervalMs()
    local minutes = tonumber(noctalia.getConfig("refresh_minutes")) or 5
    if minutes < 1 then minutes = 1 end
    return math.floor(minutes * 60 * 1000)
end

-- Everything the CLI produces ends up on screen, so all of it is cleaned once,
-- here, where it enters the plugin:
-- an error can quote the request that failed, and a request can carry a key in
-- its query string. A runaway line would also push a bar capsule off screen.
local function safeText(value)
    local text = noctalia.string.trim(tostring(value or ""))
    text = text:gsub("%s+", " ")
    text = text:gsub("([%w_%-]*[Kk][Ee][Yy][%w_%-]*=)[^%s]+", "%1<redacted>")
    text = text:gsub("([Tt][Oo][Kk][Ee][Nn][%w_%-]*=)[^%s]+", "%1<redacted>")
    text = text:gsub("([Ss][Ee][Cc][Rr][Ee][Tt][%w_%-]*=)[^%s]+", "%1<redacted>")
    text = text:gsub("([Bb]earer%s+)[^%s]+", "%1<redacted>")
    if #text > 200 then text = string.sub(text, 1, 200) .. "..." end
    return text
end

-- Every string in the report, not just the error: a plan name, an account name
-- or a metric detail is CLI text too, and any of them can arrive long.
local function scrub(value)
    if type(value) == "string" then return safeText(value) end
    if type(value) ~= "table" then return value end
    for key, inner in pairs(value) do value[key] = scrub(inner) end
    return value
end

local inFlight = false

-- The CLI caches for a minute, so a manual refresh usually answers in about ten
-- milliseconds, too fast for the loader to survive a frame. The busy state is
-- held for a beat instead, timed by the service's own tick.
local MIN_BUSY_MS = 600
local busyUntil = 0
local clearPending = false

-- A floor between spawns. Opening the panel asks for a read, and a panel can be
-- opened as fast as a pointer can click, so this bounds how often the plugin
-- can start a process no matter how the request arrives.
local MIN_GAP_MS = 2000
local lastStart = 0

local function stopPolling()
    clearPending = false
    noctalia.state.set("polling", false)
    noctalia.setUpdateInterval(intervalMs())
end

local function refresh()
    if inFlight then return end
    local now = noctalia.nowMs()
    if now - lastStart < MIN_GAP_MS then return end
    lastStart = now
    inFlight = true
    busyUntil = now + MIN_BUSY_MS
    clearPending = false
    noctalia.state.set("polling", true)
    noctalia.setUpdateInterval(120)

    local started = noctalia.runAsync(COMMAND, function(result)
        inFlight = false
        if noctalia.nowMs() >= busyUntil then
            stopPolling()
        else
            clearPending = true
        end

        local decoded = result ~= nil and noctalia.json.decode(result.stdout or "") or nil
        if type(decoded) == "table" and type(decoded.entries) == "table" then
            -- A vendor that failed still comes back as an entry with `status =
            -- "error"`, so a non-zero exit is not a reason to drop the report.
            noctalia.state.set("report", scrub(decoded))
            noctalia.state.set("error", "")
            return
        end

        local message = "ai-usagebar returned no usage data"
        if result == nil then
            message = "could not run ai-usagebar"
        elseif result.timedOut then
            message = "ai-usagebar timed out"
        elseif result.exitCode ~= 0 then
            local stderr = safeText(result.stderr)
            message = stderr ~= "" and stderr or ("ai-usagebar exited with code " .. tostring(result.exitCode))
        end
        noctalia.state.set("error", message)
    end, 30000)

    -- A refusal to spawn never calls back, and without this the poller would
    -- sit in flight forever and stop asking.
    if not started then
        inFlight = false
        noctalia.state.set("error", "could not run ai-usagebar")
        stopPolling()
    end
end

-- Manual refresh from a capsule or the panel.
noctalia.state.watch("command", function(value)
    if type(value) == "table" and value.action == "refresh" then refresh() end
end)

function update()
    -- While a read is in flight the fast tick is the busy timer, not a poll.
    if inFlight then return end
    if clearPending then
        if noctalia.nowMs() >= busyUntil then stopPolling() end
        return
    end
    noctalia.setUpdateInterval(intervalMs())
    refresh()
end

function onConfigChanged()
    noctalia.setUpdateInterval(intervalMs())
    refresh()
end

function onIpc(event, payload)
    if event == "refresh" then refresh() end
    -- `select <provider-id>` points the panel at one provider from a script.
    if event == "select" and type(payload) == "string" and payload ~= "" then
        noctalia.state.set("selected", payload)
    end
end

noctalia.setUpdateInterval(intervalMs())
refresh()
