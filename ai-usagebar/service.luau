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
-- A secret's value runs until whitespace or the quote or brace that closes it,
-- so a JSON field loses its value and keeps its punctuation.
local SECRET_VALUE = "[^%s\"',}]+"
local SECRET_WORDS = {
    "[Kk][Ee][Yy]",
    "[Tt][Oo][Kk][Ee][Nn]",
    "[Ss][Ee][Cc][Rr][Ee][Tt]",
    "[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]",
}
-- Nine characters before the rest of a provider key, so a bare "sk-" in prose
-- is not mistaken for one.
local KEY_TAIL = string.rep("[%w_%-]", 9)

local function safeText(value)
    local text = noctalia.string.trim(tostring(value or ""))
    text = text:gsub("%s+", " ")

    -- `scrub` runs this over ~165 strings per two-vendor read, and backtracking
    -- patterns on every one of them exhaust the callback's CPU budget, which
    -- costs the whole report. So nothing expensive runs until a literal search
    -- says it could match. The keyword is what opens the gate. A separator will
    -- not do: `=` and `:` both turn up in ordinary readings, in a ratio, a clock
    -- time, a URL, so gating on those ran the patterns over almost every string.
    local lower = text:lower()

    if lower:find("key", 1, true) or lower:find("token", 1, true)
        or lower:find("secret", 1, true) or lower:find("password", 1, true) then
        for _, word in ipairs(SECRET_WORDS) do
            local name = "[%w_%-]*" .. word .. "[%w_%-]*"
            -- name=value: a query string or a shell assignment.
            text = text:gsub("(" .. name .. "=)" .. SECRET_VALUE, "%1<redacted>")
            -- name: value: an HTTP header or a JSON field.
            text = text:gsub("(" .. name .. "\"?%s*:%s*\"?)" .. SECRET_VALUE, "%1<redacted>")
        end
    end

    if lower:find("bearer", 1, true) then
        text = text:gsub("([Bb][Ee][Aa][Rr][Ee][Rr]%s+)" .. SECRET_VALUE, "%1<redacted>")
    end

    -- Credentials in the userinfo half of a URL the CLI echoed back.
    if lower:find("://", 1, true) then
        text = text:gsub("(://)[^%s/@]+:[^%s/@]+(@)", "%1<redacted>%2")
    end

    -- The provider key shape this plugin sits next to all day. Anchored at a
    -- word start, so "desk-top" is not a key.
    if lower:find("sk-", 1, true) then
        text = text:gsub("%f[%w](sk%-)" .. KEY_TAIL .. "[%w_%-]*", "%1<redacted>")
    end

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

-- The one place a failure is named. Subscribers translate the code, and the
-- CLI's own text travels with it as `detail`, redacted like any other string
-- that reaches the screen.
local function failure(code, detail)
    return { code = code, detail = safeText(detail) }
end

-- The run's outcome as one code. A missing binary is split out from the
-- generic failure because the panel can offer an install link for that one,
-- and shells report it as one of two messages. Both arrive with status 127,
-- which a CLI that merely cannot open its own config file does not use, so the
-- code has to agree with the message before the install link is offered.
local function classify(result)
    if result == nil then return failure("spawn_failed") end
    if result.timedOut then return failure("timed_out") end

    -- Matched raw. `failure` scrubs what it is given, and scrubbing first would
    -- mean matching against text already capped at 200 characters, so a noisy
    -- run could push the message that names the failure out of reach.
    local stderr = tostring(result.stderr or "")
    local lower = stderr:lower()
    if result.exitCode == 127
        and (lower:find("command not found", 1, true)
            or lower:find("no such file or directory", 1, true)) then
        return failure("not_installed", stderr)
    end
    if result.exitCode ~= 0 then
        -- Whitespace-only stderr scrubs down to nothing, so the exit code has
        -- to answer for it rather than a detail that arrives on screen empty.
        return failure("failed", stderr:find("%S") and stderr
            or ("ai-usagebar exited with code " .. tostring(result.exitCode)))
    end
    return failure("no_data", stderr)
end

local inFlight = false

-- A floor between spawns. Opening the panel asks for a read, and a panel can be
-- opened as fast as a pointer can click, so this bounds how often the plugin
-- can start a process no matter how the request arrives.
local MIN_GAP_MS = 2000
local lastStart = 0

local function refresh()
    if inFlight then return end
    local now = noctalia.nowMs()
    if now - lastStart < MIN_GAP_MS then return end
    lastStart = now
    inFlight = true
    noctalia.state.set("polling", true)

    local started = noctalia.runAsync(COMMAND, function(result)
        inFlight = false
        noctalia.state.set("polling", false)

        local decoded = result ~= nil and noctalia.json.decode(result.stdout or "") or nil
        if type(decoded) == "table" and type(decoded.entries) == "table" then
            -- A vendor that failed still comes back as an entry with `status =
            -- "error"`, so a non-zero exit is not a reason to drop the report.
            noctalia.state.set("report", scrub(decoded))
            noctalia.state.set("error", failure(""))
            return
        end

        noctalia.state.set("error", classify(result))
    end, 30000)

    -- A refusal to spawn never calls back, and without this the poller would
    -- sit in flight forever and stop asking.
    if not started then
        inFlight = false
        noctalia.state.set("polling", false)
        noctalia.state.set("error", failure("spawn_failed"))
    end
end

-- Manual refresh from a capsule or the panel.
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
end

noctalia.setUpdateInterval(intervalMs())
refresh()
