--!nonstrict
-- Headless poller: the single owner of `ai-usagebar usage --json`. One call
-- returns every configured vendor, so the capsules and the panel are subscribers
-- of noctalia.state and never spawn a process of their own.

-- `ai-usagebar` is a declared dependency, so it is expected on PATH.
local COMMAND = "ai-usagebar usage --json"
local shared = require("./shared.luau")

local function intervalMs()
    local minutes = tonumber(noctalia.getConfig("refresh_minutes")) or 5
    if minutes < 1 then minutes = 1 end
    return math.floor(minutes * 60 * 1000)
end

-- ai-usagebar 1.42+ allows a cold agy quota read 90 seconds. The report
-- refreshes providers sequentially, so allow room for the remaining accounts.
local function queryTimeoutMs()
    local seconds = tonumber(noctalia.getConfig("query_timeout_seconds")) or 180
    return math.floor(math.max(30, math.min(600, seconds)) * 1000)
end

local function runQuery(callback)
    local timeoutMs = queryTimeoutMs()
    -- Noctalia caps runAsync at 60s, below agy's own 90s cold-start budget.
    -- Streams have no host deadline; coreutils timeout bounds the entire CLI
    -- process group, and the final marker reports completion even on failure.
    if type(noctalia.runStream) ~= "function" then
        return noctalia.runAsync(COMMAND, callback, math.min(timeoutMs, 60000))
    end
    local marker = "__AI_TRIAGE_EXIT__"
    local command = "timeout --kill-after=5s " .. tostring(math.floor(timeoutMs / 1000))
        .. "s " .. COMMAND .. " 2>&1; code=$?; printf '\\n" .. marker .. "%s\\n' \"$code\""
    local document, diagnostics, completed = "", {}, false
    return noctalia.runStream(command, function(line)
        if completed then return end
        line = tostring(line or "")
        local code = tonumber(line:match("^" .. marker .. "(%d+)%s*$"))
        if code then
            completed = true
            local result = { exitCode = code, timedOut = code == 124 or code == 137,
                stdout = document, stderr = table.concat(diagnostics, "\n") }
            local done = callback
            -- Noctalia retains a stream callback until script reload. Release
            -- the report and completion closure after the child has finished.
            document, diagnostics, callback = "", {}, nil
            done(result)
        elseif line:match("^%s*{") then
            -- usage --json emits one complete JSON document on one line.
            document = line
        elseif line:find("%S") and #diagnostics < 10 then
            diagnostics[#diagnostics + 1] = line:sub(1, 200)
        end
    end)
end

-- Everything the CLI prints reaches the screen, and an error can quote a request
-- that carried a key. A value runs to the whitespace, quote or brace closing it,
-- so a JSON field loses its value and keeps its punctuation.
local SECRET_VALUE = "[^%s\"',}]+"
-- Built once: safeText runs on ~165 strings per two-vendor read, and rebuilding
-- these cost more than matching them.
local SECRET_PATTERNS = {}
local function anyCase(word)
    return (word:gsub("%a", function(c) return "[" .. c:upper() .. c .. "]" end))
end
for _, word in ipairs({ "key", "token", "secret", "password" }) do
    local name = "[%w_%-]*" .. anyCase(word) .. "[%w_%-]*"
    SECRET_PATTERNS[#SECRET_PATTERNS + 1] = {
        word = word,
        -- Only the keyword that collides with a metric label keeps its numbers.
        -- Each keyword redacts on a pass of its own, so `api_key_tokens` has this
        -- exemption taken back by the `key` pass.
        keepsReadings = word == "token",
        quoted = "(" .. name .. "[\"']?%s*[:=]%s*)[\"'].*",
        -- name=value: query string, shell assignment, or the CLI's own TOML.
        assign = "(" .. name .. "%s*=%s*[\"']?)" .. SECRET_VALUE,
        -- name: value: an HTTP header or a JSON field. Captured rather than
        -- swallowed: it is also how the CLI labels a reading.
        colon = "(" .. name .. "[\"']?%s*:%s*[\"']?)(" .. SECRET_VALUE .. ")",
    }
end
local HEADER_PATTERNS = {}
for _, word in ipairs({ "authorization", "cookie" }) do
    HEADER_PATTERNS[word] = "(" .. anyCase(word) .. "[\"']?%s*[:=]%s*).*"
end

-- A quota is not a credential, but the exemption stays narrow: short, digits
-- only, and offered to labels that count tokens. The plural separates the two --
-- `input_tokens` counts, `access_token` authenticates -- and a long run of digits
-- is a credential whatever labels it.
local function isReading(prefix, value)
    local label = prefix:lower():match("([%w_%-]+)[\"']?%s*:%s*[\"']?$")
    local metric = label ~= nil and (label == "token" or label:find("tokens", 1, true) ~= nil)
    return metric and #value <= 9 and value:match("^%d[%d%.,]*%%?$") ~= nil
end

local function redactColon(prefix, value)
    if isReading(prefix, value) then return prefix .. value end
    return prefix .. "<redacted>"
end
-- Nine characters before the rest of a provider key, so a bare "sk-" in prose
-- is not mistaken for one.
local KEY_TAIL = string.rep("[%w_%-]", 9)

local function safeText(value)
    local text = noctalia.string.trim(tostring(value or ""))
    text = text:gsub("%s+", " ")

    -- Capped before the redaction: the patterns are the expensive part, and a
    -- callback that overruns its CPU budget loses the whole report.
    if #text > 200 then text = string.sub(text, 1, 200) .. "..." end

    -- A literal search gates each keyword's patterns. Gating on the separator
    -- does not work: `=` and `:` turn up in ratios, clock times and URLs.
    local lower = text:lower()

    for _, secret in ipairs(SECRET_PATTERNS) do
        if lower:find(secret.word, 1, true) then
            -- Fail closed on quoted diagnostics, including escaped quotes and
            -- values cut by the length cap: omit the remainder of the line.
            if text:find('"', 1, true) or text:find("'", 1, true) then
                text = text:gsub(secret.quoted, "%1<redacted>")
            end
            text = text:gsub(secret.assign, "%1<redacted>")
            text = text:gsub(secret.colon, secret.keepsReadings and redactColon or "%1<redacted>")
        end
    end

    if lower:find("bearer", 1, true) then
        text = text:gsub("([Bb][Ee][Aa][Rr][Ee][Rr]%s+)" .. SECRET_VALUE, "%1<redacted>")
    end

    for word, pattern in pairs(HEADER_PATTERNS) do
        if lower:find(word, 1, true) then text = text:gsub(pattern, "%1<redacted>") end
    end

    -- Credentials in the userinfo half of a URL the CLI echoed back.
    if lower:find("://", 1, true) then
        text = text:gsub("(://)[^%s/@]+:[^%s/@]+(@)", "%1<redacted>%2")
    end

    -- Anchored at a word start, so "desk-top" is not a key.
    if lower:find("sk-", 1, true) then
        text = text:gsub("%f[%w](sk%-)" .. KEY_TAIL .. "[%w_%-]*", "%1<redacted>")
    end

    return text
end

-- Every string, not just the error: a plan name is CLI text too.
local function scrub(value, cache)
    cache = cache or {}
    if type(value) == "string" then
        if cache[value] == nil then cache[value] = safeText(value) end
        return cache[value]
    end
    if type(value) ~= "table" then return value end
    for key, inner in pairs(value) do
        local sensitive = false
        if type(key) == "string" then
            local lower = key:lower()
            sensitive = lower:find("authorization", 1, true) ~= nil
                or lower:find("cookie", 1, true) ~= nil
            for _, secret in ipairs(SECRET_PATTERNS) do
                if lower:find(secret.word, 1, true)
                    and not (secret.keepsReadings and isReading(key .. ":", tostring(inner))) then
                    sensitive = true
                end
            end
        end
        if sensitive then value[key] = "<redacted>" else value[key] = scrub(inner, cache) end
    end
    return value
end

-- The one place a failure is named. Subscribers translate the code; the CLI's
-- own words travel with it as `detail`.
local function failure(code, detail)
    return { code = code, detail = safeText(detail) }
end

-- The run's outcome as one code. A missing binary gets its own, because the
-- panel offers an install link for it. 127 is the shell's "command not found".
local function classify(result)
    if result == nil then return failure("spawn_failed") end
    if result.timedOut then return failure("timed_out") end

    local stderr = tostring(result.stderr or "")
    if result.exitCode == 127 then
        return failure("not_installed", stderr)
    end
    if result.exitCode ~= 0 then
        -- Whitespace-only stderr scrubs to nothing; the exit code answers for it.
        return failure("failed", stderr:find("%S") and stderr
            or ("ai-usagebar exited with code " .. tostring(result.exitCode)))
    end
    return failure("no_data", stderr)
end

local inFlight = false
local pendingRefresh = false

local weeklyHistory = {}
local weeklyHistoryPath = nil
local weeklyDataDir = nil
pcall(function()
    weeklyDataDir = noctalia.pluginDataDir()
    weeklyHistoryPath = weeklyDataDir .. "/weekly-resets.json"
    local saved = noctalia.json.decode(noctalia.readFile(weeklyHistoryPath) or "")
    if type(saved) == "table" and saved.version == 1 then weeklyHistory = saved end
end)

local function historyLog(message)
    if type(noctalia.log) == "function" then pcall(noctalia.log, "AI Triage: " .. message) end
end

local function writeHistoryFile(path, encoded)
    assert(type(encoded) == "string", "JSON encoding failed")
    local written, err = noctalia.writeFile(path .. ".tmp", encoded)
    assert(written, err or "write refused")
    local renamed, renameErr = noctalia.renameFile(path .. ".tmp", path)
    assert(renamed, renameErr or "rename refused")
end

-- The small working history is not the audit log. Archive each change in its
-- own JSON file, with a persistent outbox so failed writes are retried. Import
-- the existing v1 events once, preserving missing legacy fields as unknown.
weeklyHistory.version = 1
weeklyHistory.pending_events = type(weeklyHistory.pending_events) == "table" and weeklyHistory.pending_events or {}
if not weeklyHistory.archive_initialized then
    for _, record in ipairs(type(weeklyHistory.events) == "table" and weeklyHistory.events or {}) do
        weeklyHistory.pending_events[#weeklyHistory.pending_events + 1] = record
    end
    weeklyHistory.archive_initialized = true
end

local function archiveWeeklyEvents()
    local pending = {}
    for _, record in ipairs(weeklyHistory.pending_events or {}) do
        local ok, result = pcall(function()
            assert(weeklyDataDir, "plugin data directory unavailable")
            assert(type(record) == "table" and type(record.change) == "table"
                and tonumber(record.change.at), "invalid event in archive outbox")
            if not record.archive_id then
                weeklyHistory.archive_sequence = (tonumber(weeklyHistory.archive_sequence) or 0) + 1
                record.archive_id = os.date("!%Y%m%dT%H%M%SZ", record.change.at)
                    .. "-" .. tostring(weeklyHistory.archive_sequence)
            end
            local change = record.change
            local payload = { version = 1, provider = record.provider, window = record.window,
                change = change, archive_id = record.archive_id }
            local encoded = noctalia.json.encode(payload)
            writeHistoryFile(weeklyDataDir .. "/weekly-reset-event-" .. record.archive_id .. ".json", encoded)
            return encoded
        end)
        if ok then
            historyLog("weekly reset event " .. result)
        else
            pending[#pending + 1] = record
            historyLog("could not archive weekly reset event; will retry: " .. tostring(result))
        end
    end
    weeklyHistory.pending_events = pending
end

local function trackWeeklyResets(report)
    local changes = {}
    weeklyHistory = shared.trackWeeklyResets(report, weeklyHistory, nil, changes)
    for _, record in ipairs(changes) do
        weeklyHistory.pending_events[#weeklyHistory.pending_events + 1] = record
    end
    archiveWeeklyEvents()
    if weeklyHistoryPath then
        local ok, result = pcall(function()
            writeHistoryFile(weeklyHistoryPath, noctalia.json.encode(weeklyHistory))
        end)
        if not ok or result == false then historyLog("could not persist weekly reset history: " .. tostring(result)) end
    end
end

local function scheduleNextRefresh(report)
    local delay = intervalMs()
    local now = os.time()
    for _, entry in ipairs(type(report) == "table" and type(report.entries) == "table" and report.entries or {}) do
        for _, metric in ipairs(type(entry) == "table" and type(entry.metrics) == "table" and entry.metrics or {}) do
            local _, weekly = shared.dualMetrics({ metric })
            local at = weekly and shared.parseIso(weekly.reset_at)
            if at then
                -- Check at the announced deadline. If it stays expired (including
                -- failed reads), retry at most once a minute, without inventing 7d.
                delay = math.min(delay, at > now and math.max(1000, (at - now) * 1000) or 60000)
            end
        end
    end
    noctalia.setUpdateInterval(delay)
end

-- A floor between spawns. Opening the panel asks for a read, and a panel opens as
-- fast as a pointer can click.
local MIN_GAP_MS = 2000
local lastStart = 0

local function queueRefresh()
    pendingRefresh = true
    noctalia.state.set("refresh_queued", true)
    noctalia.setUpdateInterval(250)
end

local function keepAntigravityReading(report)
    local previous = noctalia.state.get("report")
    if type(previous) ~= "table" or type(previous.entries) ~= "table" then return end
    for index, entry in ipairs(report.entries) do
        if type(entry) == "table" and shared.baseProvider(entry.id) == "antigravity"
            and shared.warning(entry):lower():find("no local server found", 1, true) then
            for _, old in ipairs(previous.entries) do
                if type(old) == "table" and old.id == entry.id
                    and not shared.unavailable(old) and type(old.metrics) == "table"
                    and #old.metrics > 0 then
                    local cached = {}
                    for key, value in pairs(old) do cached[key] = value end
                    cached.stale = true
                    report.entries[index] = cached
                    break
                end
            end
        end
    end
end

local lastAgyCliAt = 0
local cachedAgyCliQuota = nil

local function resolveAgyQuota(callback)
    -- 1. Try reading the observation JSON file first (instant, 0ms)
    local obsPath = noctalia and noctalia.expandPath
        and noctalia.expandPath("~/.local/state/herdr/plugins/herdr-agent-usage/agy-statusline.observation.json")
    local observationQuota = nil
    if obsPath then
        local raw = nil
        if noctalia and noctalia.readFile then
            local ok, content = pcall(noctalia.readFile, obsPath)
            if ok and type(content) == "string" and content ~= "" then
                raw = content
            end
        end
        if not raw and io and io.open then
            local ok, f = pcall(io.open, obsPath, "r")
            if ok and f then
                raw = f:read("*a")
                f:close()
            end
        end
        if raw and raw ~= "" then
            local ok, data = pcall(noctalia.json.decode, raw)
            if ok and type(data) == "table" then
                local quota = shared.parseAgyStatuslineObservation(data)
                if quota and quota.gemini_5h and quota.gemini_5h.reset_at then
                    local at = shared.parseIso(quota.gemini_5h.reset_at)
                    if at and at > os.time() then
                        -- If the observation file shows an actively started session, return it immediately (0ms)
                        if (quota.gemini_5h.percent and quota.gemini_5h.percent > 0) or quota.gemini_5h.started then
                            callback(quota)
                            return
                        end
                        observationQuota = quota
                    end
                end
            end
        end
    end

    -- Check if we have cached CLI quota from a recent authoritative query
    local now = os.time()
    if cachedAgyCliQuota and cachedAgyCliQuota.gemini_5h and cachedAgyCliQuota.gemini_5h.reset_at then
        local at = shared.parseIso(cachedAgyCliQuota.gemini_5h.reset_at)
        if at and at > now and (now - lastAgyCliAt) < 180 then
            callback(cachedAgyCliQuota)
            return
        end
    end

    -- 2. Fallback: run `agy -p /quota` asynchronously if `agy` is available.
    -- This performs the exact same force-refresh as typing `/usage` in the terminal.
    -- Throttled to at most once every 30 seconds to avoid spawning unnecessary processes.
    if noctalia and noctalia.runAsync and (now - lastAgyCliAt) >= 30 then
        lastAgyCliAt = now
        local spawned = noctalia.runAsync("agy -p /quota", function(result)
            if result and not result.timedOut and result.exitCode == 0 and result.stdout then
                local quota = shared.parseAgyCliQuota(result.stdout)
                if quota then
                    cachedAgyCliQuota = quota
                end
                callback(quota or observationQuota)
            else
                callback(observationQuota)
            end
        end, 8000)
        if not spawned then
            callback(observationQuota)
        end
    else
        callback(cachedAgyCliQuota or observationQuota)
    end
end

local function enrichAntigravity(report, callback)
    if type(report) ~= "table" or type(report.entries) ~= "table" then
        callback(report)
        return
    end

    local agyEntry = nil
    for _, entry in ipairs(report.entries) do
        -- A local agy observation belongs to the default login. Named-account
        -- readings from ai-usagebar must never be overwritten with its quota.
        if type(entry) == "table" and entry.id == "antigravity" then
            agyEntry = entry
            break
        end
    end

    if not agyEntry or shared.unavailable(agyEntry) then
        callback(report)
        return
    end

    -- Newer ai-usagebar reads agy/statusline itself and preserves its dated
    -- snapshot on failures. Only the Cloud Code fallback needs reconciliation.
    local cloudFallback = false
    for _, section in ipairs(type(agyEntry.sections) == "table" and agyEntry.sections or {}) do
        if type(section) == "table" and section.type == "text"
            and section.label == "Source" and section.value == "Google API" then
            cloudFallback = true
        end
    end
    if not cloudFallback then callback(report) return end

    -- Check if Gemini is missing, or at 0% (synthetic floating reset awaiting kickstart)
    local hasGemini5h = false
    local gemini5hZero = false
    if type(agyEntry.metrics) == "table" then
        for _, m in ipairs(agyEntry.metrics) do
            if type(m) == "table" and type(m.label) == "string" and m.label:lower():find("gemini") then
                local window = tonumber(m.window_secs) or 0
                if window <= 43200 then
                    hasGemini5h = true
                    if (tonumber(m.percent) or 0) == 0 and m.started ~= true then
                        gemini5hZero = true
                    end
                    break
                end
            end
        end
    end

    local needsEnrich = (not hasGemini5h) or gemini5hZero

    if not needsEnrich then
        callback(report)
        return
    end

    resolveAgyQuota(function(quota)
        if quota then
            shared.enrichAntigravityEntry(agyEntry, quota)
        end
        callback(report)
    end)
end

local function refresh()
    if inFlight then
        queueRefresh()
        return
    end
    local now = noctalia.nowMs()
    if MIN_GAP_MS - (now - lastStart) > 0 then
        queueRefresh()
        return
    end
    lastStart = now
    pendingRefresh = false
    noctalia.setUpdateInterval(intervalMs())
    inFlight = true
    noctalia.state.set("refresh_queued", false)
    noctalia.state.set("polling", true)

    local started = runQuery(function(result)
        local decoded = result ~= nil and not result.timedOut
            and noctalia.json.decode(result.stdout or "") or nil
        if type(decoded) == "table" and type(decoded.entries) == "table" then
            -- A failed vendor still comes back as an entry with `status = "error"`,
            -- so a non-zero exit is no reason to drop the report.
            local safeReport = scrub(decoded)
            keepAntigravityReading(safeReport)
            enrichAntigravity(safeReport, function(finalReport)
                trackWeeklyResets(finalReport)
                inFlight = false
                noctalia.state.set("polling", false)
                noctalia.state.set("report", finalReport)
                noctalia.state.set("error", failure(""))
                scheduleNextRefresh(finalReport)
                if pendingRefresh then refresh() end
            end)
            return
        else
            inFlight = false
            noctalia.state.set("polling", false)
            noctalia.state.set("error", classify(result))
            scheduleNextRefresh(noctalia.state.get("report"))
        end

        if pendingRefresh then refresh() end
    end)

    -- A refusal to spawn never calls back, and the poller would sit in flight
    -- forever.
    if not started then
        inFlight = false
        pendingRefresh = false
        noctalia.state.set("refresh_queued", false)
        noctalia.state.set("polling", false)
        noctalia.state.set("error", failure("spawn_failed"))
        scheduleNextRefresh(noctalia.state.get("report"))
    end
end

noctalia.state.watch("command", function(value)
    if type(value) == "table" and value.action == "refresh" then refresh() end
end)

function update()
    -- A read in flight answers on its own callback; the tick only starts them.
    if inFlight then return end
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
    if event == "kickstart" and type(payload) == "string" and payload ~= "" then
        local st = {}
        local current = noctalia.state.get("kickstarted_at")
        if type(current) == "table" then
            for k, v in pairs(current) do st[k] = v end
        end
        st[payload] = os.time()
        noctalia.state.set("kickstarted_at", st)
    end
end

-- Clean up legacy cycle memory file from v1.6.0 if present
pcall(function()
    local path = noctalia and noctalia.expandPath and noctalia.expandPath("~/.local/state/noctalia/ai_triage_cycles.json")
    if path and os and os.remove then os.remove(path) end
end)

noctalia.setUpdateInterval(intervalMs())
refresh()
