--!nonstrict
-- Headless engine. The only entry that runs headsetcontrol: it polls
-- `headsetcontrol -o json`, normalizes the result and publishes it as the
-- "snapshot" state. The widget and panel only render that snapshot and ask
-- for an immediate poll by bumping the nonce in "refresh_request".

local STATE_KEY = "snapshot"
local REQUEST_KEY = "refresh_request"
local COMMAND = "headsetcontrol"
local TIMEOUT_MS = 5000
local DEFAULT_INTERVAL = 5
local MIN_INTERVAL = 1
local MAX_INTERVAL = 60
-- Consecutive failed polls that keep showing the last good devices before
-- the cache is dropped, so a persistent failure never shows stale data forever.
local MAX_STALE_FAILURES = 3

local BATTERY_STATUS = {
    BATTERY_AVAILABLE = "available",
    BATTERY_CHARGING = "charging",
    BATTERY_UNAVAILABLE = "unavailable",
}

local function tr(key, args)
    return noctalia.tr(key, args)
end

local dependencyOk = false
local inFlight = false
local lastDevices = {}
local failures = 0
local lastNonce = 0

local function pollInterval()
    local value = tonumber(noctalia.getConfig("poll_interval"))
    if value == nil then
        return DEFAULT_INTERVAL
    end
    return math.clamp(math.floor(value), MIN_INTERVAL, MAX_INTERVAL)
end

local function stripHex(value)
    return string.lower(tostring(value or ""):gsub("^0[xX]", ""))
end

local function normalizeBattery(raw)
    if type(raw) ~= "table" then
        return nil
    end
    local level = tonumber(raw.level)
    if level ~= nil and level < 0 then
        level = nil
    end
    return {
        status = BATTERY_STATUS[raw.status] or "unknown",
        level = level,
    }
end

-- headsetcontrol reports per-feature failures as an `errors` map (status "partial").
local function deviceError(raw)
    if type(raw.errors) == "table" then
        local parts = {}
        for feature, message in pairs(raw.errors) do
            table.insert(parts, `{feature}: {message}`)
        end
        if #parts > 0 then
            table.sort(parts)
            return table.concat(parts, "; ")
        end
    end
    return tostring(raw.error_message or raw.status or "")
end

local function normalizeDevice(raw)
    local ok = raw.status == "success"
    return {
        id = `{stripHex(raw.id_vendor)}:{stripHex(raw.id_product)}`,
        name = raw.device or raw.product or "?",
        vendor = raw.vendor,
        product = raw.product,
        ok = ok,
        error = (not ok) and deviceError(raw) or nil,
        battery = normalizeBattery(raw.battery),
        chatmix = tonumber(raw.chatmix),
        capabilities = type(raw.capabilities_str) == "table" and raw.capabilities_str or {},
    }
end

local function publish(state, devices, err)
    noctalia.state.set(STATE_KEY, {
        state = state,
        error = err,
        updatedAt = os.time(),
        devices = devices,
    })
end

local function firstLine(text)
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            return trimmed
        end
    end
    return ""
end

local function decode(stdout)
    local ok, decoded = pcall(function()
        return noctalia.json.decode(stdout or "")
    end)
    if ok and type(decoded) == "table" and type(decoded.devices) == "table" then
        return decoded
    end
    return nil
end

local function fail(err)
    failures += 1
    if failures > MAX_STALE_FAILURES then
        lastDevices = {}
    end
    publish("error", lastDevices, err)
end

local function checkDependency()
    dependencyOk = noctalia.commandExists(COMMAND)
    if not dependencyOk then
        lastDevices = {}
        publish("missing_dependency", {}, nil)
    end
    return dependencyOk
end

local function handleResult(result)
    if result.timedOut then
        fail(tr("error.timed_out"))
        return
    end

    local doc = decode(result.stdout)
    if doc ~= nil and #doc.devices == 0 then
        -- headsetcontrol may exit non-zero when nothing is connected; an empty
        -- device list is still a valid answer, not an error.
        lastDevices = {}
        failures = 0
        publish("no_devices", {}, nil)
        return
    end

    -- A decodable device list is fresh data even if the exit code is non-zero.
    if doc ~= nil then
        local devices = {}
        for _, raw in ipairs(doc.devices) do
            if type(raw) == "table" then
                table.insert(devices, normalizeDevice(raw))
            end
        end
        lastDevices = devices
        failures = 0
        publish(#devices > 0 and "ok" or "no_devices", devices, nil)
        return
    end

    -- 127 is the shell's "command not found": the binary went away after startup.
    if result.exitCode == 127 and not checkDependency() then
        return
    end

    if result.exitCode ~= 0 then
        local detail = firstLine(result.stderr)
        if detail == "" then
            detail = firstLine(result.stdout)
        end
        fail(tr("error.exit", { code = result.exitCode, detail = detail }))
        return
    end

    fail(tr("error.invalid_json"))
end

local function poll()
    if inFlight then
        return
    end
    inFlight = true
    local started = noctalia.runAsync(`{COMMAND} -o json`, function(result)
        inFlight = false
        handleResult(result)
    end, TIMEOUT_MS)
    if not started then
        inFlight = false
        fail(tr("error.failed_to_start"))
    end
end

noctalia.state.watch(REQUEST_KEY, function(value)
    if type(value) ~= "table" then
        return
    end
    local nonce = tonumber(value.nonce) or 0
    if nonce == lastNonce then
        return
    end
    lastNonce = nonce
    if checkDependency() then
        poll()
    end
end)

function update()
    if dependencyOk then
        poll()
    end
    noctalia.setUpdateInterval(pollInterval() * 1000)
end

-- Apply a changed poll interval right away instead of after the current one.
function onConfigChanged()
    noctalia.setUpdateInterval(pollInterval() * 1000)
end

local pending = noctalia.state.get(REQUEST_KEY)
lastNonce = type(pending) == "table" and (tonumber(pending.nonce) or 0) or 0
noctalia.setUpdateInterval(pollInterval() * 1000)
if checkDependency() then
    poll()
end
