-- Contract regressions for ai-usagebar v1.43.0 (schema_version = 1).
-- An optional Lua document, emitted by check_ai_usagebar.py --live, exercises
-- the same service -> state -> bar/panel path with the installed CLI's output.
local function source(path)
    local f = assert(io.open(path))
    local text = f:read("*a")
    f:close()
    return text
end

local function clone(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = clone(v) end
    return out
end

local function host(report, config)
    local values, watchers, runs = { report = report }, {}, {}
    local bar, tooltip, tree
    local noctalia = {
        getConfig = function(key) return (config or {})[key] end,
        nowMs = function() return 5000 end,
        setUpdateInterval = function() end,
        string = { trim = function(v) return tostring(v):match("^%s*(.-)%s*$") end },
        tr = function(key) return key end,
        commandExists = function() return false end,
        formatTime = function(fmt, at) return os.date(fmt, at) end,
        timeFormat = function() return "%H:%M" end,
        togglePanel = function() end,
        json = { decode = function() return clone(report) end },
        runAsync = function(command, callback, timeout)
            runs[#runs + 1] = { command = command, callback = callback, timeout = timeout }
            return true
        end,
        runStream = function(command, onLine)
            runs[#runs + 1] = { command = command, onLine = onLine,
                callback = function(result)
                    if result.stdout and result.stdout ~= "" then onLine(result.stdout) end
                    if result.stderr and result.stderr ~= "" then onLine(result.stderr) end
                    onLine("__AI_TRIAGE_EXIT__" .. tostring(result.timedOut and 124 or result.exitCode or 0))
                end }
            return true
        end,
        state = {
            get = function(key) return values[key] end,
            set = function(key, value)
                values[key] = value
                for _, callback in ipairs(watchers[key] or {}) do callback(value) end
            end,
            watch = function(key, callback)
                watchers[key] = watchers[key] or {}
                table.insert(watchers[key], callback)
            end,
        },
    }
    local ui = setmetatable({}, { __index = function(_, kind)
        return function(props, children) return { kind = kind, props = props, children = children } end
    end })
    local env = setmetatable({ noctalia = noctalia, ui = ui,
        barWidget = {
            render = function(node) bar = node end,
            setTooltip = function(rows) tooltip = rows end,
            setVisible = function() end,
            isVertical = function() return false end,
        },
        panel = {
            render = function(node) tree = node end,
            setWantsSecondTicks = function() end,
        },
    }, { __index = _G })
    local shared = assert(load(source("shared.luau"), "shared", "t", env))()
    env.require = function(path) assert(path == "./shared.luau") return shared end
    return {
        env = env, shared = shared, values = values, runs = runs,
        load = function(path) assert(load(source(path), path, "t", env))() end,
        tooltip = function() return tooltip end,
        tree = function() return tree end,
        bar = function() return bar end,
    }
end

local function hasText(node, text)
    if type(node) ~= "table" then return false end
    if node.props and node.props.text == text then return true end
    for _, child in ipairs(node.children or {}) do
        if hasText(child, text) then return true end
    end
    return false
end

local function metric(label, percent, window)
    return { label = label, percent = percent, value = percent .. "%", headline = "percent",
        severity = "low", window_secs = window,
        reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + (window or 18000)) }
end

if arg[1] == "--query-command" then
    local h = host(nil)
    h.load("service.luau")
    io.write(h.runs[1].command)
    return
end

local weekly = metric("Codex weekly", 69, 604800)
local partial = { schema_version = 1, entries = {
    { id = "openai", display_name = "Codex", status = "ready", metrics = { weekly },
        sections = { { type = "text", label = "Codex 5h", value = "Not reported" } } },
} }
local h = host(partial, { vendor = "openai" })
h.load("bar.luau")
assert(h.tooltip()[1].value == "69%", "a weekly-only tooltip must not contain nil or a fake session")
h.load("panel.luau")
h.env.onOpen()
assert(hasText(h.tree(), "Not reported"), "missing quota is not an offline provider")
assert(not hasText(h.tree(), "Offline"), "partial ready reports must stay online")

local money = metric("Spend", 25, 604800)
money.headline, money.value = "value", "$5 / $20"
h = host({ entries = { { id = "anthropic_api", status = "ready", metrics = { money } } } },
    { vendor = "anthropic_api", visualization = "none" })
h.load("bar.luau")
assert(hasText(h.bar(), "$5 / $20"), "headline=value must show the amount on the bar")
assert(h.tooltip()[1].value == "$5 / $20", "the tooltip must agree with headline=value")

local named = { entries = {
    { id = "antigravity@aaa", display_name = "Antigravity · a***", status = "ready",
        metrics = { metric("Gemini", 10, 18000), metric("Gemini", 20, 604800) } },
    { id = "antigravity@bbb", display_name = "Antigravity · b***", status = "ready",
        metrics = { metric("Gemini", 40, 18000), metric("Gemini", 60, 604800) } },
} }
h = host(named, { vendor = "gemini", account = "bbb" })
h.load("bar.luau")
assert(h.tooltip()[1].value == "40% / 60%", "a model capsule must select its named account")
local models = h.shared.collectModelItems(named.entries)
assert(models[1].providerId == "gemini@aaa" and models[2].providerId == "gemini@bbb",
    "split Antigravity models must keep their account identity")
assert(h.shared.modelTelemetryKey("openai@work", "Codex") ~= h.shared.modelTelemetryKey("openai", "Codex"),
    "calibration must not mix account quotas")
assert(h.shared.getModelGearing("openai@work", "Codex") == h.shared.getModelGearing("openai", "Codex"),
    "named accounts must inherit provider gearing defaults")
h.load("service.luau")
assert(h.runs[1].command:find("timeout --kill-after=5s 180s", 1, true),
    "cold agy startup must use a bounded stream beyond the host's 60s async cap")
h.runs[1].callback({ exitCode = 0, stdout = "{}" })
assert(#h.runs == 1, "a named statusline reading must not trigger a default-account agy query")

-- The shell wrapper always reports how the stream finished. A timed-out
-- command must not publish even a complete-looking document from stdout.
h = host(partial)
h.load("service.luau")
h.runs[1].callback({ timedOut = true, stdout = "{}" })
assert(h.values.error.code == "timed_out" and h.values.polling == false,
    "stream deadlines must clear in-flight state and reject incomplete reads")
h = host(nil)
h.load("service.luau")
h.runs[1].callback({ exitCode = 127, stderr = "ai-usagebar: not found" })
assert(h.values.error.code == "not_installed", "stream command failures must preserve install diagnostics")
h = host(partial)
h.env.noctalia.runStream = function() return false end
h.load("service.luau")
assert(h.values.error.code == "spawn_failed" and h.values.polling == false,
    "stream spawn refusal must not leave the poller busy")

h = host(named)

local credits = { id = "openai", display_name = "Codex", metrics = { weekly },
    reset_credits = { available = 0, credits = {} },
    sections = { { type = "block", label = "Reset credits", body = { "None available" } } } }
assert(#h.shared.collectResetCredits({ credits }) == 0, "available=0 must not create a credit card")
credits.reset_credits = { available = 2, credits = {} }
local collected = h.shared.collectResetCredits({ credits })
assert(#collected == 1 and collected[1].expiresAt == math.huge, "count-only credits have no invented expiry")
local plan, stats = h.shared.analyzeResetCredits({ credits })
assert(stats.openai.earliestExpiry == nil and plan.creditAdvice.openai.status == "hold",
    "unknown credit expiration must not invent a claim deadline")
local work = clone(credits)
work.id, work.display_name = "openai@work", "Codex · work"
local _, accountStats = h.shared.analyzeResetCredits({ credits, work })
assert(accountStats.openai and accountStats["openai@work"], "reset inventories must remain per account")
credits.reset_credits = { available = 1, credits = {
    { expires_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 86400) } } }
credits.metrics = {}
plan = h.shared.analyzeResetCredits({ credits })
assert(plan.creditAdvice.openai.status == "hold", "partial reports must not invent weekly reset advice")

local stale = { entries = { { id = "anthropic", display_name = "Claude", status = "ready", stale = true,
    metrics = { metric("Session (5h)", 25, 18000) },
    sections = { { type = "text", label = "HTTP 429", value = "Rate limited" } } } } }
h = host(stale, { vendor = "anthropic" })
h.load("bar.luau")
assert(h.tooltip()[1].value == "ui.diagnostic.cause.rate_limited"
    and h.tooltip()[2].value == "ui.diagnostic.action.rate_limited"
    and h.tooltip()[3].value == "HTTP 429: Rate limited",
    "the failed query must show a cause, an action and its original detail")

-- End-to-end rendering with a real report, optionally supplied by the Python
-- runner. The injected decoder hands the CLI document to the actual poller.
if arg[1] then
    local report = assert(loadfile(arg[1]))()
    assert(report.schema_version == 1, "unexpected usage schema")
    for _, entry in ipairs(report.entries) do
        local vendor, account = entry.id:match("^([^@]+)@(.+)$")
        vendor = vendor or entry.id
        h = host(report, { vendor = vendor, account = account })
        h.load("bar.luau")
        h.load("panel.luau")
        h.load("service.luau")
        h.runs[1].callback({ exitCode = 0, stdout = "{}" })
        -- Complete the optional Cloud Code reconciliation without making a
        -- second live call; the external CLI already supplied the report.
        if h.runs[2] then h.runs[2].callback({ exitCode = 1 }) end
        assert(h.values.error.code == "" and h.values.polling == false, "poller must publish the CLI report")
        assert(h.bar() and h.tree() and #h.tooltip() > 0, "CLI entries must render in both surfaces")
    end
end
io.write("ok: 1.43 contract, partial quotas, amounts, accounts, reset inventories, timeout and diagnostics\n")
