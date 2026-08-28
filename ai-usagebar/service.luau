--!nonstrict
-- Headless poller: the single owner of `ai-usagebar usage --json`. One call
-- returns every configured vendor, so the capsules and the panel are subscribers
-- of noctalia.state and never spawn a process of their own.

-- `ai-usagebar` is a declared dependency, so it is expected on PATH.
local COMMAND = "ai-usagebar usage --json"

local function intervalMs()
    local minutes = tonumber(noctalia.getConfig("refresh_minutes")) or 5
    if minutes < 1 then minutes = 1 end
    return math.floor(minutes * 60 * 1000)
end

-- Everything the CLI prints reaches the screen, so it is cleaned here, on the
-- way in: an error can quote the request that failed, and that request can carry
-- a key. A secret's value runs to the whitespace, quote or brace that closes it,
-- so a JSON field loses its value and keeps its punctuation.
local SECRET_VALUE = "[^%s\"',}]+"
-- Built once: safeText runs on every string in the report, about 165 of them for
-- a two-vendor read, and rebuilding these pairs each time cost more than matching
-- them.
local SECRET_PATTERNS = {}
for _, word in ipairs({ "key", "token", "secret", "password" }) do
    local anyCase = (word:gsub("%a", function(c) return "[" .. c:upper() .. c .. "]" end))
    local name = "[%w_%-]*" .. anyCase .. "[%w_%-]*"
    SECRET_PATTERNS[#SECRET_PATTERNS + 1] = {
        word = word,
        -- Only the keyword that collides with a metric label keeps its numbers.
        keepsReadings = word == "token",
        -- name=value: a query string, a shell assignment, or a line out of the
        -- CLI's own TOML, where the separator is padded and the value quoted.
        assign = "(" .. name .. "%s*=%s*\"?)" .. SECRET_VALUE,
        -- name: value: an HTTP header or a JSON field. The value is captured
        -- rather than swallowed, because this shape is also how the CLI labels a
        -- reading -- "Tokens: 45000 / 100000" -- and a plugin that draws token
        -- counts cannot redact them.
        colon = "(" .. name .. "\"?%s*:%s*\"?)(" .. SECRET_VALUE .. ")",
    }
end

-- A quota or a percentage is not a credential. The exemption is deliberately
-- narrow: short, digits only, and offered to `token` alone. "Tokens: 45000" is a
-- reading this plugin exists to draw, while a bare number after `password` or
-- `secret` never is, and a long run of digits is a credential whatever labels it.
local function isReading(value)
    return #value <= 9 and value:match("^%d[%d%.,]*%%?$") ~= nil
end

local function redactColon(prefix, value)
    if isReading(value) then return prefix .. value end
    return prefix .. "<redacted>"
end
-- Nine characters before the rest of a provider key, so a bare "sk-" in prose
-- is not mistaken for one.
local KEY_TAIL = string.rep("[%w_%-]", 9)

local function safeText(value)
    local text = noctalia.string.trim(tostring(value or ""))
    text = text:gsub("%s+", " ")

    -- Capped before the redaction, not after. The patterns are the expensive part
    -- of the callback, and a callback that overruns its CPU budget loses the whole
    -- report, so they only ever scan what the plugin would draw.
    if #text > 200 then text = string.sub(text, 1, 200) .. "..." end

    -- A literal search gates each keyword's own two patterns. Gating on the
    -- separator instead does not work: `=` and `:` turn up in ordinary readings,
    -- in ratios, clock times and URLs.
    local lower = text:lower()

    for _, secret in ipairs(SECRET_PATTERNS) do
        if lower:find(secret.word, 1, true) then
            text = text:gsub(secret.assign, "%1<redacted>")
            text = text:gsub(secret.colon, secret.keepsReadings and redactColon or "%1<redacted>")
        end
    end

    if lower:find("bearer", 1, true) then
        text = text:gsub("([Bb][Ee][Aa][Rr][Ee][Rr]%s+)" .. SECRET_VALUE, "%1<redacted>")
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

-- Every string, not just the error: a plan name or a metric detail is CLI text
-- too, and any of them can arrive long.
local function scrub(value)
    if type(value) == "string" then return safeText(value) end
    if type(value) ~= "table" then return value end
    for key, inner in pairs(value) do value[key] = scrub(inner) end
    return value
end

-- The one place a failure is named. Subscribers translate the code; the CLI's
-- own words travel with it as `detail`.
local function failure(code, detail)
    return { code = code, detail = safeText(detail) }
end

-- The run's outcome as one code. A missing binary gets its own, because the
-- panel offers an install link for that one. Status 127 is the shell's own
-- "command not found"; the CLI never exits with it once it is on PATH.
local function classify(result)
    if result == nil then return failure("spawn_failed") end
    if result.timedOut then return failure("timed_out") end

    local stderr = tostring(result.stderr or "")
    if result.exitCode == 127 then
        return failure("not_installed", stderr)
    end
    if result.exitCode ~= 0 then
        -- Whitespace-only stderr scrubs down to nothing, so the exit code answers
        -- for it instead.
        return failure("failed", stderr:find("%S") and stderr
            or ("ai-usagebar exited with code " .. tostring(result.exitCode)))
    end
    return failure("no_data", stderr)
end

local inFlight = false
local pendingRefresh = false

-- A floor between spawns. Opening the panel asks for a read, and a panel opens as
-- fast as a pointer can click.
local MIN_GAP_MS = 2000
local lastStart = 0

local function queueRefresh()
    pendingRefresh = true
    noctalia.state.set("refresh_queued", true)
    noctalia.setUpdateInterval(250)
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

    local started = noctalia.runAsync(COMMAND, function(result)
        inFlight = false
        noctalia.state.set("polling", false)

        local decoded = result ~= nil and noctalia.json.decode(result.stdout or "") or nil
        if type(decoded) == "table" and type(decoded.entries) == "table" then
            -- A failed vendor still comes back as an entry with `status = "error"`,
            -- so a non-zero exit is no reason to drop the report.
            noctalia.state.set("report", scrub(decoded))
            noctalia.state.set("error", failure(""))
        else
            noctalia.state.set("error", classify(result))
        end

        if pendingRefresh then refresh() end
    end, 30000)

    -- A refusal to spawn never calls back, and the poller would sit in flight
    -- forever.
    if not started then
        inFlight = false
        pendingRefresh = false
        noctalia.state.set("refresh_queued", false)
        noctalia.state.set("polling", false)
        noctalia.state.set("error", failure("spawn_failed"))
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
end

noctalia.setUpdateInterval(intervalMs())
refresh()
