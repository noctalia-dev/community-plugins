--!nonstrict
-- What the capsule and the panel both need, in one copy, so the parsing and the
-- severity tiers cannot drift between two entries that agree on screen.
-- Relative require() arrived in API 22; the plugin manifest requires API 43.

local M = {}

M.WINDOW_5H = 18000
M.WINDOW_7D = 604800
M.WEEKLY_HOURS = 168.0
M.NOMINAL_WEEKLY_PACE_RATIO = 1.68

local function trim(s)
    if noctalia and noctalia.string and type(noctalia.string.trim) == "function" then
        return noctalia.string.trim(s)
    end
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

-- Tabler has no Anthropic mark, so providers without a brand glyph use a
-- semantic one. The glyph is identity: it carries no colour of its own, so every
-- colour left in the panel means something.
local PROVIDER_GLYPHS = {
    anthropic = "asterisk-simple",
    anthropic_api = "asterisk-simple",
    openai = "brand-openai",
    zai = "bolt",
    openrouter = "route",
    deepseek = "fish",
    kimi = "moon",
    moonshot = "moon",
    kilo = "robot",
    novita = "cloud",
    grok = "brand-x",
    supergrok = "brand-x",
    antigravity = "sparkles",
    cursor = "cursor-text",
    minimax = "wave-square",
    kiro = "ghost",
    nous = "flask",
    ["opencode-go"] = "code",
    commandcode = "terminal-2",
    copilot = "brand-github-copilot",
    ["deepinfra"] = "cloud",
    ["synthetic"] = "flask",
    ["grokbot"] = "brand-x",
    ["ollama"] = "cloud",
    ["orcarouter"] = "route",
    ["modelstudio"] = "code",
    ["lyceum"] = "school",
    ["devin"] = "terminal-2",
    ["muse-code"] = "brand-meta",
    ["cline"] = "terminal-2",
    gemini = "brand-google",
    ["claude-oss"] = "robot",
    ["claude_oss"] = "robot",
}

local PROVIDER_DASHBOARDS = {
    anthropic = "https://claude.ai/settings/usage",
    anthropic_api = "https://console.anthropic.com/",
    openai = "https://chatgpt.com/codex/settings/usage",
    openrouter = "https://openrouter.ai/activity",
    cursor = "https://www.cursor.com/settings",
    deepseek = "https://platform.deepseek.com/",
    zai = "https://z.ai",
    kimi = "https://platform.moonshot.cn/",
    moonshot = "https://platform.moonshot.cn/",
    grok = "https://console.x.ai/",
    supergrok = "https://grok.com/",
    ["deepinfra"] = "https://deepinfra.com/",
    ["synthetic"] = "https://synthetic.new/",
    ["grokbot"] = "https://grok.com/",
    ["ollama"] = "https://ollama.com/settings",
    ["orcarouter"] = "https://orcarouter.ai/",
    ["modelstudio"] = "https://modelstudio.console.alibabacloud.com/",
    ["lyceum"] = "https://lyceum.technology/",
    ["devin"] = "https://app.devin.ai/",
    ["muse-code"] = "https://dev.meta.ai/docs/muse-code",
    ["cline"] = "https://app.cline.bot/",
    gemini = "https://aistudio.google.com/",
    copilot = "https://github.com/settings/copilot",
    minimax = "https://platform.minimaxi.com/",
    antigravity = "https://antigravity.google/",
    ["claude-oss"] = "https://antigravity.google/",
    ["claude_oss"] = "https://antigravity.google/",
    kilo = "https://app.kilo.ai/usage",
    novita = "https://novita.ai/console",
    kiro = "https://app.kiro.dev/",
    nous = "https://portal.nousresearch.com/",
    ["opencode-go"] = "https://opencode.ai/console/",
    commandcode = "https://commandcode.ai/signin",
}

function M.baseProvider(id)
    return (tostring(id or ""):match("^[^@]+") or "")
end

function M.providerGlyph(id)
    return PROVIDER_GLYPHS[M.baseProvider(id)] or "scale"
end

function M.providerDashboard(id)
    return PROVIDER_DASHBOARDS[M.baseProvider(id)]
end

-- Ask the poller for a read. `at` is never read: it is there so two requests in
-- a row differ, and nowMs is the only sub-second clock the API has.
function M.requestRefresh()
    noctalia.state.set("command", { action = "refresh", at = noctalia.nowMs() })
end

-- Free text the CLI wrote to complain rather than to report; it marks those by
-- writing `error:` into the line. Asked here and nowhere else, so the panel and
-- the capsule cannot disagree about which lines are data.
function M.saysError(value)
    return tostring(value or ""):lower():find("error:") ~= nil
end

function M.transportError(value)
    return tostring(value or ""):lower():match("http%s*:?%s*%d%d%d") ~= nil
end

local function terminalAuthText(value)
    local text = tostring(value or ""):lower()
    local status = text:match("http%s*:?%s*401") ~= nil
        or text:match("http%s*:?%s*403") ~= nil
    local rejected = text:find("reject", 1, true) ~= nil
        or text:find("invalid", 1, true) ~= nil
        or text:find("expired", 1, true) ~= nil
        or text:find("forbidden", 1, true) ~= nil
        or text:find("unauthorized", 1, true) ~= nil
    return status and text:find("auth", 1, true) ~= nil and rejected
end

function M.terminalAuth(entry)
    if type(entry) ~= "table" then return false end
    if terminalAuthText(entry.error) then return true end
    local sections = type(entry.sections) == "table" and entry.sections or {}
    for _, section in ipairs(sections) do
        if type(section) == "table" and section.type == "text"
            and terminalAuthText(tostring(section.label or "") .. " "
                .. tostring(section.value or "")) then
            return true
        end
    end
    return false
end

-- A provider the CLI is no longer reading: the entry either fails outright, or
-- keeps serving cached numbers with a warning saying why they stopped moving.
-- Both mean the readings are a record, not a gauge.
function M.warning(entry)
    if type(entry) ~= "table" then return "" end
    local direct = noctalia.string.trim(tostring(entry.error or ""))
    if direct ~= "" then return direct end
    local sections = type(entry.sections) == "table" and entry.sections or {}
    for _, section in ipairs(sections) do
        if type(section) == "table" and section.type == "text" then
            local value = tostring(section.value or "")
            if M.transportError(section.label) then
                return trim(tostring(section.label)) .. (value ~= "" and (": " .. trim(value)) or "")
            end
            if M.saysError(value) then
                return noctalia.string.trim(value)
            end
        end
    end
    return ""
end

function M.unavailable(entry)
    if type(entry) ~= "table" then return true end
    if entry.status == "error" or M.warning(entry) ~= "" then return true end
    if entry.stale ~= true then return false end
    local sections = type(entry.sections) == "table" and entry.sections or {}
    for _, section in ipairs(sections) do
        if type(section) == "table" and section.type == "text"
            and (M.transportError(section.label) or M.transportError(section.value)) then
            return true
        end
    end
    return false
end

-- A parser failure says nothing about the account's availability.
function M.readFailure(entry)
    return type(entry) == "table" and entry.status == "error"
        and tostring(entry.error or ""):find("^schema mismatch:") ~= nil
end

-- Diagnose the failed read, rather than inferring whether the provider itself
-- is usable. In particular, 429/5xx must never tell the user to log out.
local API_KEY_PROVIDERS = {
    anthropic_api = true, zai = true, openrouter = true, deepseek = true,
    deepinfra = true, kilo = true, novita = true, synthetic = true,
    moonshot = true, grok = true, minimax = true, ["opencode-go"] = true,
    ollama = true, orcarouter = true, lyceum = true,
}

function M.diagnostic(entry)
    if type(entry) ~= "table" or not M.unavailable(entry) then return nil end
    local detail = M.warning(entry)
    local text = detail:lower()
    local status = tonumber(text:match("http%s*:?%s*(%d%d%d)"))
    local function has(...)
        for _, phrase in ipairs({ ... }) do
            if text:find(phrase, 1, true) then return true end
        end
        return false
    end
    local code
    if status == 429 or has("rate limited", "rate limit", "too many requests") then
        code = "rate_limited"
    elseif status and status >= 500 then
        code = "server"
    elseif has("no local server found", "requires a csrf token", "no usable local server") then
        code = "local_server"
    elseif has("timed out", "timeout", "time out") then
        code = "timeout"
    elseif has("network transport error", "connection", "dns", "resolve host", "tls", "http 000") then
        code = "network"
    elseif has("schema mismatch:", "json error:") then
        code = "schema"
    elseif has("no api key", "missing api key", "api key is not set") then
        code = "missing_key"
    elseif has("no access token", "not logged in", "signed out", "run `claude` to log in") then
        code = "signed_out"
    elseif status == 401 or M.terminalAuth(entry)
        or has("authentication rejected", "invalid_grant", "token expired", "token has expired",
            "invalid api key", "api key is invalid", "unauthorized") then
        code = "authentication"
    elseif status == 403 then
        code = "permission"
    elseif has("credentials error:") then
        code = "credentials"
    else
        code = "unknown"
    end

    local action = code
    local command = nil
    local account = tostring(entry and entry.id or ""):match("@(.+)$")
    if code == "signed_out" or code == "authentication" then
        local provider = M.baseProvider(entry and entry.id)
        if account then
            action = "named_account"
        elseif provider == "anthropic" then
            action, command = "login", "claude auth login"
        elseif provider == "openai" then
            action, command = "login", "codex login"
        elseif provider == "copilot" then
            action, command = "login", "gh auth login"
        elseif provider == "kiro" then
            action, command = "login", "kiro-cli login"
        elseif provider == "nous" then
            action, command = "login", "ai-usagebar auth nous login"
        elseif provider == "antigravity" then
            action = "local_server"
        elseif API_KEY_PROVIDERS[provider] then
            action = "missing_key"
        else
            action = "reconnect"
        end
    end
    return { code = code, titleKey = "ui.diagnostic.cause." .. code,
        actionKey = "ui.diagnostic.action." .. action, actionArgs = { account = account or "" },
        command = command, detail = detail, retryable = code ~= "rate_limited" }
end

-- Anything else in the `error` slot means no failure.
M.NO_FAILURE = { code = "", detail = "" }

function M.asFailure(value)
    if type(value) ~= "table" then return M.NO_FAILURE end
    return {
        code = type(value.code) == "string" and value.code or "",
        detail = type(value.detail) == "string" and value.detail or "",
    }
end

-- "2026-08-15T11:29:59.872624Z" -> unix seconds. The stamps are UTC and
-- os.time() reads its table as local, so the offset is measured at that same
-- instant and added back.
function M.parseIso(value)
    if type(value) ~= "string" then return nil end
    local y, mo, d, h, mi, s = value:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
    if y == nil then return nil end
    local asLocal = os.time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
    })
    local utc = os.date("!*t", asLocal)
    -- Let os.time resolve DST for these wall-clock fields. os.date marks a UTC
    -- table as standard time, which is wrong when the same fields fall in the
    -- local timezone's daylight-saving season.
    utc.isdst = nil
    local utcAsLocal = os.time(utc)
    return asLocal + (asLocal - utcAsLocal)
end

local function formatDuration(seconds)
    if seconds <= 0 then return noctalia.tr("ui.now") end
    local minutes = math.floor(seconds / 60)
    local days = math.floor(minutes / 1440)
    local hours = math.floor((minutes % 1440) / 60)
    local rest = minutes % 60
    if days > 0 then return string.format("%dd %dh", days, hours) end
    if hours > 0 then return string.format("%dh %dm", hours, rest) end
    return string.format("%dm", rest)
end

local function formatFixedDuration(seconds)
    if seconds <= 0 then return noctalia.tr("ui.now") end
    local minutes = math.floor(seconds / 60)
    local days = math.floor(minutes / 1440)
    local hours = math.floor((minutes % 1440) / 60)
    local rest = minutes % 60
    if days > 0 then return string.format("%dd %dh", days, hours) end
    return string.format("%dh %02dm", hours, rest)
end

function M.countdown(section)
    local at = M.parseIso(section and section.reset_at)
    if at == nil then return "" end
    return formatDuration(at - os.time())
end

function M.fixedCountdown(section)
    local at = M.parseIso(section and section.reset_at)
    if at == nil then return "" end
    return formatFixedDuration(at - os.time())
end

-- Where the countdown lands: "14:20" today, "Sat 14:20" past midnight, a date
-- once a weekday stops naming one day.
function M.resetClock(section)
    local at = M.parseIso(section and section.reset_at)
    if at == nil then return "" end
    local clock = noctalia.formatTime(noctalia.timeFormat(), at)
    if os.date("%Y-%m-%d", at) == os.date("%Y-%m-%d") then return clock end
    -- Prepended rather than folded into the pattern: the host's format grammar
    -- passes unknown text through verbatim, so "ddd" would render as the word.
    if at - os.time() > 6 * 86400 then return os.date("%d %b", at) .. " " .. clock end
    return os.date("%a", at) .. " " .. clock
end

-- How much of the window is gone, out of "Resets in 1h 58m · 60% elapsed".
function M.elapsedPercent(detail)
    local value = tostring(detail or ""):match("(%d+)%%%s*elapsed")
    return value ~= nil and tonumber(value) or nil
end

-- The pace is the trailing segment of "Resets in 1h 58m · 60% elapsed · 30pts
-- ahead". `elapsed` sitting there means the reading carries no pace at all.
-- Returns that segment's text, then the points and the direction inside it.
function M.pace(detail)
    local text = tostring(detail or "")
    local points, word = text:match("(%d+)pts%s+(%a+)")
    points = tonumber(points)
    if not text:find("·") then return "", points, word end
    local last = ""
    for part in text:gmatch("[^·]+") do last = part end
    last = noctalia.string.trim(last)
    if last:find("elapsed") then return "", points, word end
    return last, points, word
end

-- Whether a 5h rolling session has actively started consumption/countdown.
function M.isSessionStarted(metric)
    if type(metric) ~= "table" then return false end
    if metric.started == true then
        return true
    end
    local pct = tonumber(metric.percent)
    if pct == nil then
        pct = tonumber(tostring(metric.value or ""):match("(%d+)")) or 0
    end
    if pct > 0 then
        return true
    end

    local at = M.parseIso(metric.reset_at)
    local remaining = nil
    if at ~= nil and at > os.time() then
        remaining = at - os.time()
    end

    if remaining == nil and type(metric.detail) == "string" then
        local detail = metric.detail
        local d, dh = detail:match("Resets in%s+(%d+)d%s*(%d*)h?")
        if d then
            remaining = tonumber(d) * 86400 + (tonumber(dh) or 0) * 3600
        else
            local h, m = detail:match("Resets in%s+(%d+)h%s*(%d*)m?")
            if h then
                remaining = tonumber(h) * 3600 + (tonumber(m) or 0) * 60
            else
                local mOnly = detail:match("Resets in%s+(%d+)m")
                if mOnly then
                    remaining = tonumber(mOnly) * 60
                end
            end
        end
    end

    -- If no future reset time is present (expired or never scheduled), session is not started
    if remaining == nil or remaining <= 0 then
        return false
    end

    local window = tonumber(metric.window_secs) or 18000
    if window <= 0 then window = 18000 end

    local elapsed = M.elapsedPercent(metric.detail)
    if elapsed == nil then
        local elapsedSecs = math.max(0, window - remaining)
        elapsed = math.floor((elapsedSecs / window) * 100)
    end

    -- At 0% quota usage, rolling providers (Codex, Antigravity) report a synthetic
    -- future reset timestamp floating around the full window (e.g. 4h 59m, 4h 58m,
    -- with 0% elapsed). These are unstarted sessions awaiting their first prompt.
    -- A 5h session is only considered started if:
    -- 1) Quota has been consumed (pct > 0, handled above),
    -- 2) Time has elapsed significantly (>= 10% elapsed, e.g. > 30m into a 5h window),
    -- 3) Or less than 90% of the window remains (< 4h 30m of 5h: remaining < window * 0.90).
    if (elapsed and elapsed >= 10) or (remaining > 0 and remaining < (window * 0.90)) then
        return true
    end

    return false
end

-- Kept next to the role both entries colour with, so the tiers cannot be edited
-- in one file and forgotten in the other. `low` falls through to 0, like
-- anything the CLI adds later.
M.SEVERITY_RANK = { critical = 3, high = 2, mid = 1 }

local function isCritical(metric)
    if type(metric) ~= "table" then return false end
    local sev = tostring(metric.severity or "")
    local pct = tonumber(metric.percent) or 0
    return sev == "critical" or pct >= 100
end
M.isCritical = isCritical

function M.isModelHidden(providerId, modelName)
    local hideOss = false
    local hiddenList = ""
    if noctalia and type(noctalia.getConfig) == "function" then
        hideOss = noctalia.getConfig("hide_claude_oss") == true
        hiddenList = tostring(noctalia.getConfig("hidden_services") or "")
    end
    local pid = tostring(providerId or ""):lower()
    local name = tostring(modelName or ""):lower()
    local basePid = M.baseProvider(pid):lower()

    if hideOss then
        if pid == "claude-oss" or pid == "claude_oss"
            or basePid == "claude-oss" or basePid == "claude_oss"
            or name:find("oss", 1, true)
            or (name:find("claude", 1, true) and not pid:find("anthropic")) then
            return true
        end
    end

    if hiddenList ~= "" then
        for item in hiddenList:gmatch("[^,]+") do
            local lowerItem = item:match("^%s*(.-)%s*$"):lower()
            if lowerItem ~= "" then
                if pid == lowerItem or basePid == lowerItem or name == lowerItem
                    or (name ~= "" and name:find(lowerItem, 1, true))
                    or (pid ~= "" and pid:find(lowerItem, 1, true)) then
                    return true
                end
                if (lowerItem == "claude-oss" or lowerItem == "claude_oss" or lowerItem == "claudeoss")
                    and (name:find("claude", 1, true) and name:find("oss", 1, true)) then
                    return true
                end
            end
        end
    end

    return false
end

-- Severity is a warning, not proof of exhaustion. Only a full quota blocks use.
function M.blockingMetric(metrics, providerId)
    local blocking = nil
    for _, metric in ipairs(metrics or {}) do
        if M.isQuotaMetric(metric) and (tonumber(metric.percent) or 0) >= 100 then
            local lbl = tostring(metric.label or "")
            if not M.isModelHidden(providerId or lbl, lbl) then
                local reset = M.parseIso(metric.reset_at) or -1
                local previous = M.parseIso(blocking and blocking.reset_at) or -1
                if blocking == nil or reset > previous then blocking = metric end
            end
        end
    end
    return blocking
end

-- Grouped rows describe context windows or product breakdowns, rather than
-- another shared quota. They must not block the account or fill a missing 5h/7d.
function M.isQuotaMetric(metric)
    return type(metric) == "table" and trim(tostring(metric.group or "")) == ""
end

function M.metricText(metric)
    if type(metric) ~= "table" then return nil end
    if metric.headline == "value" and trim(tostring(metric.value or "")) ~= "" then
        return tostring(metric.value)
    end
    local percent = tonumber(metric.percent)
    return percent and string.format("%d%%", percent) or tostring(metric.value or "")
end

function M.headline(entry)
    if type(entry) ~= "table" or type(entry.metrics) ~= "table" then return nil end
    local metrics = entry.metrics
    if #metrics == 0 then return nil end

    local visibleMetrics = {}
    for _, m in ipairs(metrics) do
        if M.isQuotaMetric(m) then
            local lbl = tostring(m.label or "")
            if not M.isModelHidden(entry.id, lbl) then
                visibleMetrics[#visibleMetrics + 1] = m
            end
        end
    end
    if #visibleMetrics == 0 then return nil end

    -- Per-model quota pools (ai-usagebar 1.40+ model_pool) should not block the headline
    -- if shared provider windows still have capacity
    local nonPoolMetrics = {}
    for _, m in ipairs(visibleMetrics) do
        if type(m) == "table" and not m.model_pool then nonPoolMetrics[#nonPoolMetrics + 1] = m end
    end
    local candidateMetrics = #nonPoolMetrics > 0 and nonPoolMetrics or visibleMetrics

    local blocking = M.blockingMetric(candidateMetrics, entry.id)
    if blocking ~= nil then return blocking end

    -- 1. For Antigravity: always follow active session usage across visible models
    if M.baseProvider(entry.id) == "antigravity" then
        local seen = {}
        local best = nil
        local bestPct = -1
        for _, metric in ipairs(candidateMetrics) do
            if type(metric) == "table" and metric.label ~= nil and metric.label ~= "" then
                local model = tostring(metric.label)
                if not seen[model] then
                    seen[model] = true
                    local pct = tonumber(metric.percent) or 0
                    if pct > bestPct then
                        best = metric
                        bestPct = pct
                    end
                end
            end
        end
        if best ~= nil then return best end
    end

    -- Otherwise keep the primary window selected by the CLI.
    for _, metric in ipairs(candidateMetrics) do
        if type(metric) == "table" then return metric end
    end
    return nil
end

-- A provider can report a balance instead of a quota. The CLI then sends no
-- percentage metrics and puts the figure in a `text` section (DeepSeek
-- `Balance: $2.90`, Nous `Total usable credits: 8.19`). Pick the one a reader
-- would want on the bar: a total or balance first, then a credit/remaining
-- line, and never a reset countdown. Returns nil for providers that already
-- carry a headline metric, so the percentage path is untouched.
function M.balanceText(entry)
    if type(entry) ~= "table" or M.headline(entry) ~= nil then return nil end
    local sections = type(entry.sections) == "table" and entry.sections or nil
    if sections == nil then return nil end

    local credit = nil
    for _, section in ipairs(sections) do
        if type(section) == "table" and section.type == "text" then
            local value = noctalia.string.trim(tostring(section.value or ""))
            if value ~= "" and not M.saysError(value) then
                local label = tostring(section.label or ""):lower()
                if label:find("total", 1, true) or label:find("balance", 1, true) then
                    return value
                end
                if credit == nil
                    and (label:find("credit", 1, true) or label:find("remaining", 1, true)) then
                    credit = value
                end
            end
        end
    end
    return credit
end

function M.modelGlyph(label)
    local lower = tostring(label or ""):lower()
    if lower:find("oss", 1, true) or lower:find("claude", 1, true) then return "robot" end
    if lower:find("gemini", 1, true) then return "brand-google" end
    if lower:find("gpt", 1, true) or lower:find("openai", 1, true) then return "brand-openai" end
    return "sparkles"
end

function M.modelDisplayName(label)
    local lower = tostring(label or ""):lower()
    if lower:find("oss", 1, true) or lower:find("claude", 1, true) then return tostring(label or "") end
    if lower:find("argon", 1, true) then return "Gemini 4 Argon" end
    if lower == "gemini" then return "Gemini" end
    if lower:find("gemini", 1, true) then return tostring(label or "") end
    if lower:find("gpt", 1, true) or lower:find("openai", 1, true) then return "GPT" end
    return tostring(label or "")
end

-- Parse quota from agy statusline observation JSON (e.g. agy-statusline.observation.json)
function M.parseAgyStatuslineObservation(data)
    if type(data) ~= "table" then return nil end
    local quota = {}

    local q = (type(data.payload) == "table" and type(data.payload.quota) == "table") and data.payload.quota or nil
    if q then
        if type(q["gemini-5h"]) == "table" then
            local rem = tonumber(q["gemini-5h"].remaining_fraction) or 1
            local rawUsed = (1 - rem) * 100
            local used = math.max(0, math.min(100, math.floor(rawUsed + 0.5)))
            local started = rem < 0.9999 or rawUsed > 0.001
            if started and used == 0 then
                used = 1
            end
            quota.gemini_5h = {
                percent = used,
                reset_at = q["gemini-5h"].reset_time,
                remaining_secs = tonumber(q["gemini-5h"].reset_in_seconds),
                started = started,
            }
        end
        if type(q["gemini-weekly"]) == "table" then
            local rem = tonumber(q["gemini-weekly"].remaining_fraction) or 1
            local rawUsed = (1 - rem) * 100
            local used = math.max(0, math.min(100, math.floor(rawUsed + 0.5)))
            quota.gemini_weekly = {
                percent = used,
                reset_at = q["gemini-weekly"].reset_time,
                remaining_secs = tonumber(q["gemini-weekly"].reset_in_seconds),
            }
        end
        if type(q["3p-5h"]) == "table" then
            local rem = tonumber(q["3p-5h"].remaining_fraction) or 1
            local rawUsed = (1 - rem) * 100
            local used = math.max(0, math.min(100, math.floor(rawUsed + 0.5)))
            local started = rem < 0.9999 or rawUsed > 0.001
            if started and used == 0 then
                used = 1
            end
            quota.third_party_5h = {
                percent = used,
                reset_at = q["3p-5h"].reset_time,
                remaining_secs = tonumber(q["3p-5h"].reset_in_seconds),
                started = started,
            }
        end
        if type(q["3p-weekly"]) == "table" then
            local rem = tonumber(q["3p-weekly"].remaining_fraction) or 1
            local rawUsed = (1 - rem) * 100
            local used = math.max(0, math.min(100, math.floor(rawUsed + 0.5)))
            quota.third_party_weekly = {
                percent = used,
                reset_at = q["3p-weekly"].reset_time,
                remaining_secs = tonumber(q["3p-weekly"].reset_in_seconds),
            }
        end
    end

    if not quota.gemini_5h and type(data.snapshot) == "table" and type(data.snapshot.windows) == "table" then
        for _, w in ipairs(data.snapshot.windows) do
            if type(w) == "table" then
                local kind = w.kind
                local rawUsed = tonumber(w.used_percent)
                if rawUsed == nil and w.remaining_percent ~= nil then
                    rawUsed = 100 - tonumber(w.remaining_percent)
                end
                local used = math.max(0, math.min(100, math.floor((rawUsed or 0) + 0.5)))
                local started = (rawUsed and rawUsed > 0.001) or (w.remaining_percent and tonumber(w.remaining_percent) < 99.99)
                if started and used == 0 then
                    used = 1
                end
                local resetIso = nil
                local remSecs = nil
                if w.resets_at then
                    local ts = tonumber(w.resets_at)
                    if ts then
                        resetIso = os.date("!%Y-%m-%dT%H:%M:%SZ", ts)
                        remSecs = math.max(0, ts - os.time())
                    end
                end
                if kind == "five_hour" then
                    quota.gemini_5h = {
                        percent = used,
                        reset_at = resetIso,
                        remaining_secs = remSecs,
                        started = started,
                    }
                elseif kind == "weekly" then
                    quota.gemini_weekly = {
                        percent = used,
                        reset_at = resetIso,
                        remaining_secs = remSecs,
                    }
                end
            end
        end
    end

    if quota.gemini_5h or quota.gemini_weekly then
        return quota
    end
    return nil
end

-- Parse quota output from `agy -p /quota`
function M.parseAgyCliQuota(text)
    if type(text) ~= "string" or text == "" then return nil end
    local quota = {}

    for line in text:gmatch("[^\r\n]+") do
        local isGemini = line:find("Gemini", 1, true) ~= nil
        local is3p = line:find("Claude", 1, true) ~= nil or line:find("GPT", 1, true) ~= nil
        local is5h = line:find("Five Hour", 1, true) ~= nil
        local isWeekly = line:find("Weekly", 1, true) ~= nil
        local remPct, y, mo, d, h, mi = line:match("(%d+)%%%s+(%d%d%d%d)%-(%d%d)%-(%d%d)%s+(%d%d):(%d%d)")
        if (isGemini or is3p) and (is5h or isWeekly) and remPct then
            local remaining = tonumber(remPct) or 100
            local used = math.max(0, math.min(100, 100 - remaining))
            local localTs = os.time({
                year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                hour = tonumber(h), min = tonumber(mi), sec = 0,
            })
            local iso = os.date("!%Y-%m-%dT%H:%M:%SZ", localTs)
            local item = {
                percent = used,
                reset_at = iso,
                remaining_secs = math.max(0, localTs - os.time()),
                started = used > 0,
            }
            if isGemini and is5h then
                quota.gemini_5h = item
            elseif isGemini and isWeekly then
                quota.gemini_weekly = item
            elseif is3p and is5h then
                quota.third_party_5h = item
            elseif is3p and isWeekly then
                quota.third_party_weekly = item
            end
        end
    end

    if quota.gemini_5h or quota.gemini_weekly then
        return quota
    end
    return nil
end

-- Enrich Antigravity entry with real local session quota
function M.enrichAntigravityEntry(entry, quotaData)
    if type(entry) ~= "table" or type(quotaData) ~= "table" then return end
    if type(entry.metrics) ~= "table" then return end

    local function applyUpdate(m, qd)
        if not qd then return end
        if qd.percent ~= nil then
            m.percent = qd.percent
            m.value = string.format("%d%%", qd.percent)
            if qd.percent >= 90 then
                m.severity = "critical"
            elseif qd.percent >= 75 then
                m.severity = "high"
            elseif qd.percent >= 50 then
                m.severity = "mid"
            else
                m.severity = "low"
            end
        end
        if qd.reset_at then
            m.reset_at = qd.reset_at
            local remainingText = M.countdown({ reset_at = qd.reset_at })
            if remainingText ~= "" then
                m.detail = "Resets in " .. remainingText
            else
                m.detail = "Resets now"
            end
        end
        if qd.started ~= nil then
            m.started = qd.started
        end
    end

    local foundGemini5h = false
    local foundGeminiWeekly = false

    for _, m in ipairs(entry.metrics) do
        if type(m) == "table" and type(m.label) == "string" then
            local label = m.label:lower()
            local window = tonumber(m.window_secs) or 0
            if label:find("gemini") then
                if window <= 43200 then
                    foundGemini5h = true
                    applyUpdate(m, quotaData.gemini_5h)
                else
                    foundGeminiWeekly = true
                    applyUpdate(m, quotaData.gemini_weekly)
                end
            elseif label:find("claude") or label:find("gpt") or label:find("oss") then
                if window <= 43200 then
                    applyUpdate(m, quotaData.third_party_5h)
                else
                    applyUpdate(m, quotaData.third_party_weekly)
                end
            end
        end
    end

    local function makeMetric(label, windowSecs, qd)
        if not qd then return nil end
        local remainingText = qd.reset_at and M.countdown({ reset_at = qd.reset_at }) or ""
        local detail = remainingText ~= "" and ("Resets in " .. remainingText) or "Resets now"
        local pct = qd.percent or 0
        local sev = "low"
        if pct >= 90 then sev = "critical"
        elseif pct >= 75 then sev = "high"
        elseif pct >= 50 then sev = "mid"
        end
        return {
            detail = detail,
            headline = "percent",
            label = label,
            percent = pct,
            reset_at = qd.reset_at,
            severity = sev,
            value = string.format("%d%%", pct),
            window_secs = windowSecs,
            started = qd.started,
        }
    end

    if not foundGemini5h and quotaData.gemini_5h then
        local m = makeMetric("Gemini", 18000, quotaData.gemini_5h)
        if m then
            table.insert(entry.metrics, 1, m)
            foundGemini5h = true
        end
    end

    if not foundGeminiWeekly and quotaData.gemini_weekly then
        local m = makeMetric("Gemini", 604800, quotaData.gemini_weekly)
        if m then
            local insertPos = 2
            for idx, item in ipairs(entry.metrics) do
                if item.label == "Gemini" and (tonumber(item.window_secs) or 0) <= 43200 then
                    insertPos = idx + 1
                    break
                end
            end
            table.insert(entry.metrics, insertPos, m)
            foundGeminiWeekly = true
        end
    end

    if type(entry.sections) == "table" then
        for _, s in ipairs(entry.sections) do
            if type(s) == "table" and s.type == "metric" and type(s.label) == "string" then
                local label = s.label:lower()
                local window = tonumber(s.window_secs) or 0
                if label:find("gemini") then
                    if window <= 43200 then
                        applyUpdate(s, quotaData.gemini_5h)
                    else
                        applyUpdate(s, quotaData.gemini_weekly)
                    end
                elseif label:find("claude") or label:find("gpt") or label:find("oss") then
                    if window <= 43200 then
                        applyUpdate(s, quotaData.third_party_5h)
                    else
                        applyUpdate(s, quotaData.third_party_weekly)
                    end
                end
            elseif type(s) == "table" and s.label == "Source" and type(s.value) == "string" then
                s.value = "Local agy session"
            end
        end
    end
end

function M.modelHeadlines(entry)
    if type(entry) ~= "table" or type(entry.metrics) ~= "table" then return {} end
    if M.baseProvider(entry.id) ~= "antigravity" then return {} end

    local order = {}
    local byModel = {}
    for _, metric in ipairs(entry.metrics) do
        if type(metric) == "table" and metric.label ~= nil and metric.label ~= "" then
            local model = tostring(metric.label)
            if not M.isModelHidden(entry.id, model) then
                if byModel[model] == nil then
                    byModel[model] = {}
                    order[#order + 1] = model
                end
                byModel[model][#byModel[model] + 1] = metric
            end
        end
    end

    local result = {}
    for _, model in ipairs(order) do
        local modelMetrics = byModel[model]
        local sessionMetric, weeklyMetric = M.dualMetrics(modelMetrics)
        sessionMetric = sessionMetric or weeklyMetric
        local blockingMetric = M.blockingMetric(modelMetrics, entry.id)
        if sessionMetric ~= nil then
            result[#result + 1] = {
                model = model,
                displayName = M.modelDisplayName(model),
                glyph = M.modelGlyph(model),
                metric = sessionMetric,
                metrics = modelMetrics,
                blockingMetric = blockingMetric,
            }
        end
    end
    return result
end

-- Extracts (shortMetric, weeklyMetric) where shortMetric represents the 5-hour
-- session limit and weeklyMetric represents the 7-day rate limit.
function M.dualMetrics(metrics)
    if type(metrics) ~= "table" then return nil, nil end
    local valid = {}
    for _, metric in ipairs(metrics) do
        if M.isQuotaMetric(metric) then valid[#valid + 1] = metric end
    end
    metrics = valid
    if #metrics == 0 then return nil, nil end
    if #metrics == 1 then
        local m = metrics[1]
        local isWeekly = false
        if type(m) == "table" then
            local w = tonumber(m.window_secs)
            local lbl = tostring(m.label or ""):lower()
            if (w ~= nil and w > 86400) or lbl:find("week", 1, true) or lbl:find("7d", 1, true) then
                isWeekly = true
            end
        end
        if isWeekly then
            return nil, m
        end
        return m, nil
    end

    local shortMetric = nil
    local weeklyMetric = nil

    for _, m in ipairs(metrics) do
        if type(m) == "table" then
            local w = tonumber(m.window_secs)
            local lbl = tostring(m.label or ""):lower()
            if w ~= nil and w > 0 then
                if w <= 86400 and shortMetric == nil then
                    shortMetric = m
                elseif w > 86400 and weeklyMetric == nil then
                    weeklyMetric = m
                end
            elseif lbl:find("5h", 1, true) or lbl:find("session", 1, true) or lbl:find("hour", 1, true) then
                if shortMetric == nil then shortMetric = m end
            elseif lbl:find("week", 1, true) or lbl:find("7d", 1, true) then
                if weeklyMetric == nil then weeklyMetric = m end
            end
        end
    end

    if shortMetric ~= nil or weeklyMetric ~= nil then
        return shortMetric, weeklyMetric
    end

    return metrics[1], metrics[2]
end

function M.entries(report)
    if type(report) ~= "table" or type(report.entries) ~= "table" then return {} end
    local visible, positions = {}, {}
    for _, entry in ipairs(report.entries) do
        if type(entry) == "table" and not M.terminalAuth(entry)
            and (not M.unavailable(entry) or M.readFailure(entry)) then
            local id = entry.id
            local name = entry.display_name or entry.name or entry.id
            if not M.isModelHidden(id, name) then
                visible[#visible + 1] = entry
                positions[entry] = #visible
            end
        end
    end
    table.sort(visible, function(a, b)
        local aMetric = M.headline(a)
        local bMetric = M.headline(b)
        local aRank = M.SEVERITY_RANK[tostring(aMetric and aMetric.severity or "")] or 0
        local bRank = M.SEVERITY_RANK[tostring(bMetric and bMetric.severity or "")] or 0
        if aRank ~= bRank then return aRank > bRank end
        local aPercent = type(aMetric) == "table" and tonumber(aMetric.percent) or -1
        local bPercent = type(bMetric) == "table" and tonumber(bMetric.percent) or -1
        if aPercent ~= bPercent then return aPercent > bPercent end
        return positions[a] < positions[b]
    end)
    return visible
end

-- A provider can report more than it was given, so clamp before this becomes a
-- bar width.
function M.ratio(percent)
    local value = (tonumber(percent) or 0) / 100
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

-- The CLI tiers every percentage; copying its thresholds here would be a second
-- source of truth. `calm` is for when it raised nothing.
--
-- `high` is deliberately not `tertiary`: themes may make that role dark, and in
-- the stock dark theme it lands at 2.8:1 on a card, below the 3.9:1 of the muted
-- text it is supposed to outrank.
function M.severityRole(section, calm)
    local severity = tostring(section and section.severity or "")
    if severity == "critical" then return "error" end
    if severity == "high" then return "secondary" end
    return calm
end

-- ── Reset credit analysis and staggering plan ─────────────────────────────────
-- A weekly reset credit is worth the quota it lets you burn before the natural
-- renewal would have refilled the week anyway, minus the unused quota it throws
-- away. That holds whether a claim zeroes the counter under the same renewal or
-- opens a fresh 7d window (which then stands in for the natural renewal), so a
-- claim is bounded by the active hours left in the cycle: claiming a few hours
-- before the renewal buys back one session at most and wastes the credit.
--
-- Capacity runs at full 5h-session pace, each session spending 100/gearing % of
-- the week, the same C_max the weekly triage uses.
M.CLAIM_MIN_WEEKLY_PCT = 95 -- the week is effectively spent
M.CLAIM_VALUE_RATIO = 0.5   -- spend it now only for at least half of what it is worth later
M.CLAIM_MARGIN_ACTIVE_HOURS = 1.0
M.CREDIT_MAX_BONUS = 300.0 -- a full extra week at (or beyond) the required burn pace

local function sessionCapacity(activeHours, gearing)
    return math.max(0.0, activeHours) * 20.0 / gearing
end

-- Best gain from spending a credit inside one cycle: burn `wFree` at full pace,
-- claim as soon as it runs out (or right before the credit expires), then burn
-- the refill until the renewal. Hours are active hours from the start of the cycle.
local function cycleClaimGain(cycleHours, expiryHours, wFree, gearing)
    if expiryHours <= 0 then return 0.0 end
    local burnHours = math.min(wFree * gearing / 20.0, expiryHours, cycleHours)
    local leftover = wFree - math.min(wFree, sessionCapacity(burnHours, gearing))
    local refill = math.min(100.0, sessionCapacity(cycleHours - burnHours, gearing))
    return math.max(0.0, refill - leftover)
end

-- When to spend a provider's earliest-expiring credit: "claim" now, "advance"
-- (worth spending this cycle once the week runs out), or "hold" for a later cycle.
local function adviseResetCredit(stats, gearing, nowTime, config)
    if not stats.weeklyReported then
        return { status = "hold", summary = "Keep the reset: weekly quota not reported",
            nowGain = 0, cycleGain = 0, laterGain = 0, lastChance = false }
    end
    if stats.weeklyScheduleKnown == false then
        return { status = "hold", summary = "Keep the reset: refresh to confirm the weekly schedule",
            nowGain = 0, cycleGain = 0, laterGain = 0, lastChance = false }
    end
    if stats.earliestExpiry == nil then
        return { status = "hold", summary = "Keep the reset: expiration not reported",
            nowGain = 0, cycleGain = 0, laterGain = 0, lastChance = false }
    end
    local renewAt = stats.weeklyResetAt
    local window = stats.weeklyWindowSecs
    local expiresAt = stats.earliestExpiry
    local wFree = math.max(0.0, 100.0 - stats.weeklyPercent)

    local cycleHours = M.calculateActiveHours(nowTime, renewAt, config, true)
    local expiryHours = expiresAt >= renewAt and math.huge
        or M.calculateActiveHours(nowTime, expiresAt, config, true)
    local nowGain = math.max(0.0, math.min(100.0, sessionCapacity(cycleHours, gearing)) - wFree)
    local cycleGain = cycleClaimGain(cycleHours, expiryHours, wFree, gearing)

    -- The next cycle starts at 0%: the whole week has to be burnt before a claim pays.
    -- To meaningfully defer to the next cycle, the credit must survive deep enough
    -- into the next cycle (at least 3.0 days / 72h) and allow burning at least ~40%
    -- of the fresh week naturally. Credits expiring on the same day as renewal or
    -- within 72h cannot be deferred — this cycle is their last viable chance.
    local laterGain = 0.0
    local minDeferRunwaySecs = 3 * 86400
    if expiresAt > (renewAt + minDeferRunwaySecs) then
        local nextEnd = renewAt + window
        local nextHours = M.calculateActiveHours(renewAt, nextEnd, config, false)
        local nextExpiry = expiresAt >= nextEnd and math.huge
            or M.calculateActiveHours(renewAt, expiresAt, config, false)
        local minBurnHours = 40.0 * gearing / 20.0
        if nextExpiry >= minBurnHours then
            laterGain = cycleClaimGain(nextHours, nextExpiry, 100.0, gearing)
        end
    end

    local oneSession = 100.0 / gearing
    local lastChance = (expiresAt <= renewAt + minDeferRunwaySecs)
        or (laterGain < math.max(40.0, oneSession))
        or (cycleGain >= 50.0 and laterGain < cycleGain * 0.65)

    local worthIt = cycleGain >= oneSession and (laterGain == 0.0 or cycleGain >= M.CLAIM_VALUE_RATIO * laterGain)
    local spent = stats.weeklyPercent >= M.CLAIM_MIN_WEEKLY_PCT
    local expiryFirst = expiryHours < wFree * gearing / 20.0
    local renewIn = formatDuration(renewAt - nowTime)
    local expiresIn = formatDuration(expiresAt - nowTime)

    local perilExpiry = expiryHours <= 4.0 or (expiresAt - nowTime) <= (6 * 3600)
    local canClaimPeril = perilExpiry and (stats.weeklyPercent >= 80 or nowGain >= oneSession)

    local advice = {
        nowGain = nowGain,
        cycleGain = cycleGain,
        laterGain = laterGain,
        lastChance = lastChance,
        expiresAt = expiresAt,
        sessionsToSpend = math.max(0, M.CLAIM_MIN_WEEKLY_PCT - stats.weeklyPercent) / oneSession,
    }
    if worthIt and (spent or canClaimPeril or (expiryFirst and expiryHours <= 2.0)) then
        advice.status = "claim"
        advice.summary = spent
            and string.format("Weekly quota spent · claim now: ~%d%% of a week back before the renewal in %s",
                math.floor(nowGain + 0.5), renewIn)
            or string.format("Reset credit expires in %s · claim now: ~%d%% of a week back",
                expiresIn, math.floor(nowGain + 0.5))
    elseif worthIt then
        advice.status = "advance"
        if expiresAt < renewAt then
            advice.summary = string.format("Claim before %s · burn remaining %d%% early · worth up to ~%d%% of a week",
                os.date("%b %d %H:%M %Z", expiresAt),
                math.floor(math.max(0, M.CLAIM_MIN_WEEKLY_PCT - stats.weeklyPercent) + 0.5), math.floor(cycleGain + 0.5))
        elseif lastChance and (renewAt - nowTime) <= (7 * 86400) and not expiryFirst then
            advice.summary = string.format("Claim before renewal in %s · burn remaining %d%% early · worth ~%d%% of a week",
                renewIn, math.floor(wFree + 0.5), math.floor(cycleGain + 0.5))
        elseif expiryFirst then
            advice.summary = string.format("Claim before the credit expires in %s · worth ~%d%% of a week",
                expiresIn, math.floor(cycleGain + 0.5))
        else
            advice.summary = string.format("Claim once this week runs out · worth ~%d%% of a week",
                math.floor(cycleGain + 0.5))
        end
    else
        advice.status = "hold"
        advice.summary = laterGain > cycleGain
            and string.format("Keep the reset: renews in %s, a claim now adds ~%d%% of a week vs ~%d%% next cycle",
                renewIn, math.floor(cycleGain + 0.5), math.floor(laterGain + 0.5))
            or string.format("Keep the reset: a claim this cycle adds only ~%d%% of a week",
                math.floor(cycleGain + 0.5))
    end
    return advice
end

-- Credit expiry is a separate opportunity, not an expiry of the current quota.
-- Keep its score bounded by the extra quota it can buy, using the real deadline
-- and remaining burn work. Ordinary weekly/session urgency remains unchanged.
function M.resetCreditUrgency(item, advice, nowTime, config, isUserActiveNow)
    if not item or not advice or advice.status ~= "advance" then return nil end
    local now = nowTime or os.time()
    config = config or M.getScheduleConfig()
    if M.unavailable(item.entry) or M.weeklyResetStatus(item.weeklyMetric, item.entry, now) ~= "announced" then return nil end
    local expiresAt = tonumber(advice.expiresAt)
    local renewAt = M.parseIso(item.weeklyMetric and item.weeklyMetric.reset_at)
    local gain = math.min(100, math.max(0, tonumber(advice.cycleGain) or 0))
    if not expiresAt or expiresAt <= now or not renewAt or gain <= 0 then return nil end

    local gearing = M.getModelGearing(item.providerId or (item.entry and item.entry.id), item.name)
    local percent = tonumber(item.weeklyMetric.percent) or 0
    local toSpend = math.max(0, M.CLAIM_MIN_WEEKLY_PCT - percent)
    local needed = toSpend * gearing / 20.0
    if needed <= 0 then return nil end

    local deadline = math.min(expiresAt, renewAt)
    local expiryHours = M.calculateActiveHours(now, deadline, config, isUserActiveNow)
    local cycleHours = M.calculateActiveHours(now, renewAt, config, isUserActiveNow)
    -- Leave at least one full session to use the refill before natural renewal.
    -- The credit analysis already withholds claims that are not worth that much.
    local budget = math.max(0, math.min(expiryHours, cycleHours - 5.0) - M.CLAIM_MARGIN_ACTIVE_HOURS)
    local session = item.sessionMetric
    local sessionAt = M.parseIso(session and session.reset_at)
    local blockedHours = 0
    if sessionAt and sessionAt > now then
        local beforeReset = M.calculateActiveHours(now, math.min(sessionAt, deadline), config, isUserActiveNow)
        local sessionFree = math.max(0, 100 - (tonumber(session.percent) or 0))
        -- Until the current session resets, unused active time beyond its
        -- remaining allowance cannot help reach the weekly claim threshold.
        blockedHours = math.max(0, beforeReset - sessionFree / 20.0)
    end
    local available = math.max(0, budget - blockedHours)
    local pressure = needed / math.max(0.25, available)
    return {
        expiresAt = expiresAt, deadlineAt = deadline,
        neededHours = needed, availableHours = available, blockedHours = blockedHours,
        marginHours = M.CLAIM_MARGIN_ACTIVE_HOURS, percentToSpend = toSpend,
        pressure = pressure, feasible = needed <= available,
        bonus = M.CREDIT_MAX_BONUS * (gain / 100.0) * math.min(1, pressure) ^ 2,
    }
end

-- When two or more providers have weekly reset credits/promotions expiring
-- around the same date (e.g. within 7 days in the same ~16d horizon),
-- it is practically impossible to double quota consumption for both in the same final week.
-- The optimal strategy is staggering:
-- 1. One provider is advanced to burn its weekly quota early and claim the reset
--    mid-cycle, completing two full quotas that week. When its current cycle is
--    too short for that, the advance starts from its next renewal.
-- 2. The other provider is deferred to the final expiration week.
-- 3. A claim is flagged only once the week is spent (or the credit is about to
--    expire) and the cycle has enough active hours left to make it pay.
function M.analyzeResetCredits(entries, nowTime, scheduleConfig)
    nowTime = nowTime or os.time()
    scheduleConfig = scheduleConfig or M.getScheduleConfig()
    local providerStats = {}
    local allExpiring = {}

    for _, entry in ipairs(entries or {}) do
        local id = entry.id
        local baseId = M.baseProvider(id)
        local displayName = tostring(entry.display_name or entry.name or id or "")
        local rawCredits = type(entry.reset_credits) == "table" and entry.reset_credits.credits or nil
        local availableCount = type(entry.reset_credits) == "table" and tonumber(entry.reset_credits.available) or 0
        local sections = type(entry.sections) == "table" and entry.sections or {}

        local _, wMetric = M.dualMetrics(entry.metrics)
        local wPct = wMetric and tonumber(wMetric.percent) or 0
        local wWindow = wMetric and tonumber(wMetric.window_secs) or 604800
        local wAt = wMetric and M.parseIso(wMetric.reset_at)
        if wAt == nil or wAt <= nowTime then wAt = nowTime + wWindow end
        local wRemainingSecs = wAt - nowTime

        local list = {}
        if type(rawCredits) == "table" and #rawCredits > 0 and availableCount ~= 0 then
            for _, rc in ipairs(rawCredits) do
                local expAt = M.parseIso(rc.expires_at)
                if expAt and expAt > nowTime then
                    list[#list + 1] = {
                        title = rc.title or "Full reset",
                        expiresAt = expAt,
                        remainingSecs = expAt - nowTime,
                    }
                end
            end
        end

        if type(entry.reset_credits) ~= "table" then
            for _, section in ipairs(sections) do
                if type(section) == "table" and section.type == "block" and tostring(section.label or ""):lower():find("reset credit") then
                    local lines = type(section.body) == "table" and section.body or {}
                    for _, line in ipairs(lines) do
                        local text = noctalia.string.trim(tostring(line or ""))
                        local days = tonumber(text:match("(%d+)d")) or 0
                        local hours = tonumber(text:match("(%d+)h")) or 0
                        local expAt = nowTime + (days * 86400) + (hours * 3600)
                        if expAt > nowTime then
                            list[#list + 1] = {
                                title = text:match("^(.-)%s+·") or text,
                                expiresAt = expAt,
                                remainingSecs = expAt - nowTime,
                            }
                        end
                    end
                end
            end
        end

        table.sort(list, function(a, b) return a.expiresAt < b.expiresAt end)

        local count = math.max(availableCount, #list)
        if count > 0 then
            local earliest = list[1]
            local stats = {
                id = id,
                baseId = baseId,
                name = displayName,
                glyph = M.providerGlyph(baseId),
                available = count,
                credits = list,
                earliestExpiry = earliest and earliest.expiresAt,
                earliestRemainingSecs = earliest and earliest.remainingSecs,
                weeklyPercent = wPct,
                weeklyReported = wMetric ~= nil,
                weeklyScheduleKnown = wMetric ~= nil and M.weeklyResetStatus(wMetric, entry, nowTime) == "announced",
                weeklyResetAt = wAt,
                weeklyWindowSecs = wWindow,
                weeklyRemainingSecs = wRemainingSecs,
                entry = entry,
            }
            stats.advice = adviseResetCredit(stats, M.getModelGearing(id, displayName), nowTime, scheduleConfig)
            stats.canClaimNow = stats.advice.status == "claim"
            providerStats[id] = stats
            if earliest then
                allExpiring[#allExpiring + 1] = stats
            end
        end
    end

    local staggerPlan = {
        hasCollision = false,
        collidingProviders = {},
        advanceProviderId = nil,
        advanceName = nil,
        deferProviderId = nil,
        deferName = nil,
        daysUntilExpiry = nil,
        expiresAt = nil,
        timeDiffHours = nil,
        advanceNow = false,
        optimalClaimProviders = {},
        -- Providers whose weekly quota should be burnt early so the credit is claimed this cycle
        fastTrack = {},
        creditAdvice = {},
    }

    for baseId, stats in pairs(providerStats) do
        staggerPlan.creditAdvice[baseId] = stats.advice
        if stats.canClaimNow then
            staggerPlan.optimalClaimProviders[baseId] = true
        end
        -- Last cycle in which the credit can pay off: burn the week early to reach it.
        if stats.advice.status == "advance" and stats.advice.lastChance then
            staggerPlan.fastTrack[baseId] = true
        end
    end

    -- Collision detection: 2 or more providers with credits expiring in <= 16 days
    -- and with expiration dates separated by less than 7 days (same weekly window)
    if #allExpiring >= 2 then
        table.sort(allExpiring, function(a, b) return a.earliestExpiry < b.earliestExpiry end)
        for i = 1, #allExpiring - 1 do
            local p1 = allExpiring[i]
            local p2 = allExpiring[i + 1]
            local diffSecs = math.abs(p1.earliestExpiry - p2.earliestExpiry)
            local horizonSecs = 16 * 86400

            if p1.earliestRemainingSecs <= horizonSecs and p2.earliestRemainingSecs <= horizonSecs and diffSecs <= (7 * 86400) then
                staggerPlan.hasCollision = true
                staggerPlan.collidingProviders = { p1, p2 }
                staggerPlan.timeDiffHours = diffSecs / 3600
                staggerPlan.daysUntilExpiry = math.min(p1.earliestRemainingSecs, p2.earliestRemainingSecs) / 86400
                staggerPlan.expiresAt = math.min(p1.earliestExpiry, p2.earliestExpiry)

                -- Advance fitness evaluation:
                -- 1. Reserve scarcity: a provider with 1 credit must secure its single window,
                --    whereas providers with multiple credits have subsequent renewal cycles.
                -- 2. Progress / Cycle proximity: higher weekly progress (or imminent renewal
                --    starting a fresh week in a few hours) minimizes burn friction.
                local function advanceScore(p)
                    local reserveScarcity = (1.0 / math.max(1, p.available)) * 50.0
                    local progress = p.weeklyPercent
                    if p.advice.status == "hold" and not p.advice.lastChance then
                        -- For providers held pending imminent renewal: proximity to the fresh cycle
                        progress = (1.0 - math.min(1.0, p.weeklyRemainingSecs / p.weeklyWindowSecs)) * 30.0
                    elseif p.advice.lastChance then
                        progress = progress + 100.0
                    end
                    return reserveScarcity + progress
                end
                local p1Score = advanceScore(p1)
                local p2Score = advanceScore(p2)

                local advanceP = (p1Score >= p2Score) and p1 or p2
                local deferP = (p1Score >= p2Score) and p2 or p1

                staggerPlan.advanceProviderId = advanceP.id
                staggerPlan.advanceName = advanceP.name
                staggerPlan.deferProviderId = deferP.id
                staggerPlan.deferName = deferP.name
                staggerPlan.advanceNow = advanceP.advice.status == "advance"
                if staggerPlan.advanceNow then
                    staggerPlan.fastTrack[advanceP.id] = true
                end
                -- The deferred credit waits for a later cycle while that one can still pay it back.
                if deferP.advice.status == "advance" and not deferP.advice.lastChance then
                    deferP.advice.status = "hold"
                    deferP.advice.summary = string.format("Deferred: keep it for the cycle after the renewal in %s · worth ~%d%% of a week",
                        formatDuration(deferP.weeklyRemainingSecs), math.floor(deferP.advice.laterGain + 0.5))
                end
                break
            end
        end
    end

    for id, stats in pairs(providerStats) do
        if staggerPlan.fastTrack[id] then
            local session, weekly = M.dualMetrics(stats.entry.metrics)
            stats.advice.urgency = M.resetCreditUrgency({ entry = stats.entry, providerId = id,
                name = stats.name, sessionMetric = session, weeklyMetric = weekly },
                stats.advice, nowTime, scheduleConfig, true)
        end
    end
    return staggerPlan, providerStats
end

-- Check whether a candidate provider is configured (excludes unconfigured "no api key" errors)
function M.isConfigured(entry)
    if type(entry) ~= "table" then return false end
    if entry.status ~= "error" then return true end
    local message = tostring(entry.error or ""):lower()
    return not (message:find("^credentials error:") and message:find("no api key", 1, true))
end

-- Map a provider/model entry to its CLI kickstart target name ("claude", "codex", "gemini", "claude-oss")
function M.kickstartTarget(itemOrId, optionalName)
    if itemOrId == nil then return nil end
    local id = ""
    local name = ""
    if type(itemOrId) == "table" then
        id = tostring(itemOrId.providerId or itemOrId.id or "")
        name = tostring(itemOrId.name or itemOrId.displayName or ""):lower()
    else
        id = tostring(itemOrId)
        name = tostring(optionalName or ""):lower()
    end
    -- The helper runs the CLI's current login; it cannot select a named account.
    if id:find("@", 1, true) or id:find(":", 1, true) then return nil end
    if id == "anthropic" or name:find("^claude$") then
        return "claude"
    elseif id == "openai" or name:find("^codex") then
        return "codex"
    elseif id == "gemini" or name:find("gemini") then
        return "gemini"
    elseif id == "claude-oss" or id == "claude_oss" or name:find("oss") then
        return "claude-oss"
    elseif id == "antigravity" then
        if name:find("claude") or name:find("oss") then
            return "claude-oss"
        else
            return "gemini"
        end
    end
    return nil
end

-- Normalize candidate provider entries and unpack multi-model providers (Antigravity) into distinct model items
function M.collectModelItems(candidates)
    local items = {}
    if type(candidates) ~= "table" then return items end
    for _, entry in ipairs(candidates) do
        local id = entry.id
        local baseId = M.baseProvider(id)
        local displayName = tostring(entry.display_name or entry.name or entry.id or "")
        local plan = tostring(entry.plan or "")

        if baseId == "antigravity" then
            local models = M.modelHeadlines(entry)
            if #models > 0 then
                for _, model in ipairs(models) do
                    local sMetric, wMetric = M.dualMetrics(model.metrics)
                    local modelName = tostring(model.model or ""):lower()
                    local subId = modelName == "gemini" and "gemini"
                        or (modelName:find("claude") or modelName:find("oss")) and "claude-oss"
                        or (id .. ":" .. modelName)
                    local suffix = tostring(id):match("(@.*)$")
                    if suffix and (subId == "gemini" or subId == "claude-oss") then
                        subId = subId .. suffix
                    end
                    items[#items + 1] = {
                        providerId = subId,
                        providerName = model.displayName,
                        plan = plan,
                        providerGlyph = model.glyph,
                        name = model.displayName,
                        glyph = model.glyph,
                        badge = nil,
                        sessionMetric = sMetric,
                        weeklyMetric = wMetric,
                        entry = entry,
                    }
                end
            elseif not M.isModelHidden(id, displayName) then
                local sMetric, wMetric = M.dualMetrics(entry.metrics)
                items[#items + 1] = {
                    providerId = id,
                    providerName = displayName,
                    plan = plan,
                    providerGlyph = M.providerGlyph(id),
                    name = displayName,
                    glyph = M.providerGlyph(id),
                    badge = nil,
                    sessionMetric = sMetric,
                    weeklyMetric = wMetric,
                    entry = entry,
                }
            end
        else
            if not M.isModelHidden(id, displayName) then
                local sMetric, wMetric = M.dualMetrics(entry.metrics)
                items[#items + 1] = {
                    providerId = id,
                    providerName = displayName,
                    plan = plan,
                    providerGlyph = M.providerGlyph(id),
                    name = displayName,
                    glyph = M.providerGlyph(id),
                    badge = nil,
                    sessionMetric = sMetric,
                    weeklyMetric = wMetric,
                    entry = entry,
                }
            end
        end
    end
    for _, item in ipairs(items) do
        M.recordTelemetrySample(item)
    end
    return items
end

-- Collect, parse, and sort pending reset credits from provider sections and stagger plans
function M.collectResetCredits(candidates, staggerPlan)
    local credits = {}
    if type(candidates) ~= "table" then return credits end
    local now = os.time()
    for _, entry in ipairs(candidates) do
        local providerId = entry.id
        local function add(title, expiresAt, expiryText)
            if expiresAt and expiresAt <= now then return end
            local role = nil
            if staggerPlan and staggerPlan.hasCollision then
                if providerId == staggerPlan.advanceProviderId then role = "advance"
                elseif providerId == staggerPlan.deferProviderId then role = "defer" end
            end
            credits[#credits + 1] = {
                baseId = M.baseProvider(providerId),
                providerId = providerId,
                providerName = tostring(entry.display_name or entry.name or providerId or ""),
                glyph = M.providerGlyph(providerId),
                expiry = expiryText or "Expiration not reported",
                fullTitle = title or "Full reset",
                expiresAt = expiresAt or math.huge,
                role = role,
            }
        end
        if type(entry.reset_credits) == "table" then
            -- The structured inventory is authoritative, including an explicit
            -- zero. Relative dates in cached text must not resurrect credits.
            local inventory = entry.reset_credits
            local list = type(inventory.credits) == "table" and inventory.credits or {}
            if tonumber(inventory.available) ~= 0 then
                for _, rc in ipairs(list) do
                    local at = M.parseIso(rc.expires_at)
                    add(rc.title, at, at and os.date("%b %d %H:%M", at) or nil)
                end
                if #list == 0 and (tonumber(inventory.available) or 0) > 0 then
                    add(tostring(inventory.available) .. " reset credits")
                end
            end
        else
            -- Older reports only supplied a human-readable block.
            local sections = type(entry.sections) == "table" and entry.sections or {}
            for _, section in ipairs(sections) do
                if type(section) == "table" and section.type == "block"
                    and tostring(section.label or ""):lower():find("reset credit") then
                    for _, line in ipairs(type(section.body) == "table" and section.body or {}) do
                        local text = trim(tostring(line))
                        local kind, expiry = text:match("^(.-)%s+·%s+(.+)$")
                        local expiryText = (expiry or text):gsub("^[Ee]xpires%s*", "")
                        local days = tonumber(expiryText:match("(%d+)d")) or 0
                        local hours = tonumber(expiryText:match("(%d+)h")) or 0
                        if days > 0 or hours > 0 then
                            add(kind or text, now + days * 86400 + hours * 3600, expiryText)
                        end
                    end
                end
            end
        end
    end
    table.sort(credits, function(a, b)
        if a.expiresAt ~= b.expiresAt then return a.expiresAt < b.expiresAt end
        return (a.providerName or "") < (b.providerName or "")
    end)
    local seen = {}
    for _, credit in ipairs(credits) do
        local id = credit.providerId
        if not seen[id] then
            seen[id] = true
            local advice = staggerPlan and staggerPlan.creditAdvice and staggerPlan.creditAdvice[id]
            credit.advice = advice and advice.summary or nil
            if staggerPlan and staggerPlan.optimalClaimProviders and staggerPlan.optimalClaimProviders[id] then
                credit.role = "claim"
            end
        end
    end
    return credits
end


-- ── Schedule-aware Human Activity Model ──────────────────────────────────────
-- Models realistic human interaction patterns (workdays vs weekends, sleep/rest,
-- meal pauses). Calculates effective active working hours (H_active) rather than
-- raw calendar hours, reflecting that quotas expiring within off-hours must be
-- burned during remaining awake periods before they are permanently lost.

M.DEFAULT_SCHEDULE = {
    scheduleAware = true,
    sleepStartHour = 0,         -- 00:00 midnight on weekdays
    sleepEndHour = 8,           -- 08:00 AM on weekdays
    weekendSleepStartHour = 1,  -- 01:00 AM on weekends
    weekendSleepEndHour = 9,    -- 09:00 AM on weekends
    mealPauseHours = 1,         -- Unscheduled daytime unavailability, spread across waking hours
    burstDurationHours = 2.0,   -- 2h active awake burst when active out-of-schedule
}

function M.getScheduleConfig()
    local aware = true
    if type(noctalia) == "table" and type(noctalia.getConfig) == "function" then
        if noctalia.getConfig("schedule_aware_triage") == false then
            aware = false
        end
    end
    local function numConfig(key, default, minVal, maxVal)
        if type(noctalia) == "table" and type(noctalia.getConfig) == "function" then
            local val = tonumber(noctalia.getConfig(key))
            if val ~= nil then
                if minVal and val < minVal then val = minVal end
                if maxVal and val > maxVal then val = maxVal end
                return val
            end
        end
        return default
    end

    return {
        scheduleAware = aware,
        sleepStartHour = numConfig("sleep_start_hour", 0, 0, 23.5),
        sleepEndHour = numConfig("sleep_end_hour", 8, 0, 23.5),
        weekendSleepStartHour = numConfig("weekend_sleep_start_hour", 1, 0, 23.5),
        weekendSleepEndHour = numConfig("weekend_sleep_end_hour", 9, 0, 23.5),
        mealPauseHours = numConfig("meal_pause_hours", 1, 0, 24),
        burstDurationHours = 2.0,
    }
end

local function sleepWindow(config, date)
    local weekend = date.wday == 1 or date.wday == 7
    return weekend and config.weekendSleepStartHour or config.sleepStartHour,
        weekend and config.weekendSleepEndHour or config.sleepEndHour
end

local function inSleepWindow(hour, startHour, endHour)
    if startHour == endHour then return false end
    if startHour < endHour then return hour >= startHour and hour < endHour end
    return hour >= startHour or hour < endHour
end

-- Sustainable weekly pace follows the configured budget, rather than assuming
-- 15 hours available every day regardless of the user's actual schedule.
function M.nominalWeeklyActiveHours(config)
    config = config or M.getScheduleConfig()
    if not config.scheduleAware then return 105.0 end
    local function daily(startHour, endHour)
        local sleep = (endHour - startHour) % 24
        return math.max(0, 24 - sleep - (config.mealPauseHours or 0))
    end
    return daily(config.sleepStartHour, config.sleepEndHour) * 5
        + daily(config.weekendSleepStartHour, config.weekendSleepEndHour) * 2
end

-- Calculates effective active working hours between tStart and tEnd.
-- Out-of-schedule adaptation: If the user is currently active during nominal sleep hours
-- (e.g. late-night coding burst), an immediate awake burst is credited as active time,
-- after which off-hours resume until the morning wake-up hour.
function M.calculateActiveHours(tStart, tEnd, config, isUserActiveNow)
    if tEnd == nil or tStart == nil or tEnd <= tStart then
        return 0.0
    end
    config = config or M.getScheduleConfig()
    if not config.scheduleAware then
        return (tEnd - tStart) / 3600.0
    end
    if isUserActiveNow == nil then
        isUserActiveNow = true
    end

    local current = os.date("*t", tStart)
    local sleepStart, sleepEnd = sleepWindow(config, current)
    local burstUntil = tStart
    if isUserActiveNow and inSleepWindow(current.hour + current.min / 60, sleepStart, sleepEnd) then
        burstUntil = tStart + ((config.burstDurationHours or 2.0) * 3600)
    end

    local totalActiveHours = 0.0
    local cur = tStart
    while cur < tEnd do
        local date = os.date("*t", cur)
        local function localTime(hour, dayOffset)
            return os.time({ year = date.year, month = date.month, day = date.day + (dayOffset or 0),
                hour = math.floor(hour), min = math.floor((hour % 1) * 60 + 0.5), sec = 0 })
        end
        local dayStart, dayEnd = localTime(0), localTime(0, 1)
        local sStart, sEnd = sleepWindow(config, date)
        local boundaries = { dayStart, dayEnd, localTime(sStart), localTime(sEnd) }
        table.sort(boundaries)
        local awakeHours = 0
        local spans = {}
        for index = 1, #boundaries - 1 do
            local first, last = boundaries[index], boundaries[index + 1]
            if last > first then
                local mid = os.date("*t", math.floor((first + last) / 2))
                local sleeping = inSleepWindow(mid.hour + mid.min / 60, sStart, sEnd)
                spans[#spans + 1] = { first = first, last = last, sleeping = sleeping }
                if not sleeping then awakeHours = awakeHours + (last - first) / 3600 end
            end
        end
        local daytimeWeight = awakeHours > 0
            and math.max(0, 1 - (config.mealPauseHours or 0) / awakeHours) or 0
        for _, span in ipairs(spans) do
            local first, last = math.max(cur, span.first), math.min(tEnd, span.last)
            if last > first then
                if span.sleeping then
                    totalActiveHours = totalActiveHours + math.max(0, math.min(last, burstUntil) - first) / 3600
                else
                    totalActiveHours = totalActiveHours + (last - first) / 3600 * daytimeWeight
                end
            end
        end
        cur = dayEnd
    end

    return math.max(0.25, totalActiveHours)
end

-- Default reference only; scoring uses nominalWeeklyActiveHours(config).
M.NOMINAL_WEEKLY_ACTIVE_HOURS = 105.0

-- Model Quota Gearing Ratios (K_m = L_weekly / L_session):
-- Defines how many full 100% 5h sessions equal 100% weekly quota.
-- Low K (<= 3.5, e.g. Claude & GPT OSS ~2.5): weekly quota is the bottleneck; 1 session burns ~40% of the week.
-- Moderate K (e.g. Codex ~6.3, Claude Pro ~7.0): 1 session burns ~15.9% / ~14.3% of the week.
-- High K (>= 12.0): session capacity can become the bottleneck before the weekly reset.
M.DEFAULT_GEARING = {
    ["claude-oss"] = 2.5,
    ["gemini"] = 8.0,
    ["anthropic"] = 7.0,
    ["openai"] = 6.3, -- Observed Oct 1–12, 2026: 512 session points / 81 weekly points.
    ["default"] = 10.0,
}

-- In-memory empirical telemetry store for tracking session delta vs weekly delta (K_obs = Delta S / Delta W)
M.telemetryBaselines = {}

function M.modelTelemetryKey(providerId, modelName)
    local pid = tostring(providerId or ""):lower()
    local mname = tostring(modelName or ""):lower()
    local base, suffix = pid:match("^(.-)(@.*)$")
    if suffix then return M.modelTelemetryKey(base, modelName) .. suffix end
    if pid:find("oss") or mname:find("oss") then
        return "claude-oss"
    elseif pid:find("gemini") or mname:find("gemini") then
        return "gemini"
    elseif pid:find("anthropic") or (mname:find("claude") and not mname:find("oss")) then
        return "anthropic"
    elseif pid:find("openai") or mname:find("codex") or mname:find("gpt") then
        return "openai"
    end
    return pid ~= "" and pid or "default"
end

-- Record a telemetry sample from an item with both 5h session and 7d weekly metrics.
-- When quota is consumed during an active session, computes empirical gearing:
-- K_obs = Delta Session % / Delta Weekly %
function M.recordTelemetrySample(item)
    if type(item) ~= "table" then return end
    if item.entry and M.unavailable(item.entry) then return end
    local sMetric = item.sessionMetric
    local wMetric = item.weeklyMetric
    if type(sMetric) ~= "table" or type(wMetric) ~= "table" then return end

    local sPct = tonumber(sMetric.percent)
    local wPct = tonumber(wMetric.percent)
    if sPct == nil or wPct == nil then return end

    local key = M.modelTelemetryKey(item.providerId or (item.entry and item.entry.id), item.name)
    local sReset = tostring(sMetric.reset_at or "")
    local wReset = tostring(wMetric.reset_at or "")

    local telemetry = M.telemetryBaselines
    if type(noctalia) == "table" and type(noctalia.state) == "table" and type(noctalia.state.get) == "function" then
        local st = noctalia.state.get("gearing_telemetry")
        if type(st) == "table" then telemetry = st end
    end

    local rec = telemetry[key]
    if rec == nil then
        rec = {
            s_base = sPct,
            w_base = wPct,
            s_reset = sReset,
            w_reset = wReset,
            k_calibrated = nil,
            obs_samples = 0,
        }
        telemetry[key] = rec
    else
        -- Detect session or weekly cycle reset
        local resetChanged = (sReset ~= "" and rec.s_reset ~= "" and sReset ~= rec.s_reset)
        local sessionDropped = (rec.s_base > 25 and sPct <= 5)
        local weekReset = (wReset ~= "" and rec.w_reset ~= "" and wReset ~= rec.w_reset)

        if resetChanged or sessionDropped or weekReset then
            rec.s_base = sPct
            rec.w_base = wPct
            rec.s_reset = sReset
            rec.w_reset = wReset
        else
            if sPct < rec.s_base then
                rec.s_base = sPct
                rec.w_base = wPct
            else
                local dS = sPct - rec.s_base
                local dW = wPct - rec.w_base
                -- When session usage delta is significant (>= 15%) and weekly delta >= 1%:
                if dS >= 15.0 and dW >= 1.0 then
                    local k_sample = dS / dW
                    if k_sample >= 1.5 and k_sample <= 30.0 then
                        rec.obs_samples = (rec.obs_samples or 0) + 1
                        if rec.k_calibrated == nil then
                            rec.k_calibrated = math.floor(k_sample * 10 + 0.5) / 10
                        else
                            local blended = 0.35 * k_sample + 0.65 * rec.k_calibrated
                            rec.k_calibrated = math.floor(blended * 10 + 0.5) / 10
                        end
                    end
                end
            end
        end
    end

    M.telemetryBaselines = telemetry
    if type(noctalia) == "table" and type(noctalia.state) == "table" and type(noctalia.state.set) == "function" then
        noctalia.state.set("gearing_telemetry", telemetry)
    end
end

function M.getModelGearing(providerId, modelName, item)
    local rawId = tostring(providerId or ""):lower()
    local rawName = tostring(modelName or ""):lower()
    local key = M.modelTelemetryKey(providerId, modelName)

    local baseKey = M.baseProvider(key)

    -- 1. Check user manual override in configuration
    if type(noctalia) == "table" and type(noctalia.getConfig) == "function" then
        local configKey = "gearing_" .. (baseKey:gsub("%-", "_"))
        local v = tonumber(noctalia.getConfig(configKey))
        if v and v > 0 then
            local defVal = M.DEFAULT_GEARING[baseKey] or 10.0
            if math.abs(v - defVal) > 0.05 then
                return v, false
            end
        end
    end

    -- 2. Check dynamic empirical telemetry calibration
    local telemetry = M.telemetryBaselines
    if type(noctalia) == "table" and type(noctalia.state) == "table" and type(noctalia.state.get) == "function" then
        local st = noctalia.state.get("gearing_telemetry")
        if type(st) == "table" then telemetry = st end
    end
    local rec = telemetry and telemetry[key]
    if rec and rec.k_calibrated and rec.k_calibrated > 0 then
        return rec.k_calibrated, true
    end

    -- 3. Default empirical baseline
    local def = M.DEFAULT_GEARING[baseKey] or M.DEFAULT_GEARING["default"]
    return def, false
end

-- Upstream dynamic weekly cycle passthrough (the upstream reset_at is authoritative)
function M.reconcileReportCycles(report, _nowTime)
    return report
end

-- Keep observations, never a second calendar. The service archives new events;
-- only the recent 32 and the latest baseline are needed in the working state.
function M.trackWeeklyResets(report, history, nowTime, changes)
    local now = nowTime or os.time()
    changes = changes or {}
    history = type(history) == "table" and history.version == 1 and history or {}
    history.version = 1
    history.samples = type(history.samples) == "table" and history.samples or {}
    history.events = type(history.events) == "table" and history.events or {}
    for _, entry in ipairs(type(report) == "table" and type(report.entries) == "table" and report.entries or {}) do
        if type(entry) == "table" and type(entry.id) == "string" then
            local samples = history.samples[entry.id]
            samples = type(samples) == "table" and samples or {}
            local source = "ai-usagebar"
            for _, section in ipairs(type(entry.sections) == "table" and entry.sections or {}) do
                if type(section) == "table" and section.label == "Source" then
                    source = tostring(section.value or source)
                end
            end
            for _, metric in ipairs(type(entry.metrics) == "table" and entry.metrics or {}) do
                local _, weekly = M.dualMetrics({ metric })
                if weekly then
                    local key = tostring(metric.label or "Weekly") .. "/" .. tostring(metric.window_secs or 604800)
                    local previous = samples[key]
                    previous = type(previous) == "table" and previous or nil
                    local at = M.parseIso(entry.fetched_at) or now
                    local reset = M.parseIso(metric.reset_at)
                    local percent = tonumber(metric.percent)
                    local credits = type(entry.reset_credits) == "table" and tonumber(entry.reset_credits.available) or nil
                    local minutes = type(noctalia) == "table" and type(noctalia.getConfig) == "function"
                        and tonumber(noctalia.getConfig("refresh_minutes")) or 5
                    local fresh = not M.unavailable(entry) and entry.stale ~= true and at <= now + 60
                        and now - at <= math.max(900, (minutes or 5) * 120)
                        and (not previous or at > (tonumber(previous.at) or 0))
                    if fresh and reset and percent then
                        local event = previous and previous.event
                        local oldReset = previous and tonumber(previous.reset_at)
                        if oldReset and math.abs(reset - oldReset) > 60 then
                            local kind = nil
                            if previous.source == source and reset > oldReset
                                and (tonumber(previous.percent) or 0) - percent >= 5 then
                                kind = at < oldReset - 60 and "early_renewal" or "renewal"
                            elseif math.abs(reset - oldReset) >= 3600 then
                                kind = "schedule_changed"
                            end
                            if kind then
                                local window = tonumber(metric.window_secs) or 604800
                                local fewer_credits = credits ~= nil and tonumber(previous.credits) ~= nil
                                    and credits < tonumber(previous.credits) or false
                                local isFloating = (percent == 0 and math.abs(reset - at - window) <= 60 and not fewer_credits)
                                    or (percent == 0 and previous.percent == 0
                                        and tonumber(previous.at) ~= nil
                                        and math.abs(reset - at - window) <= 60
                                        and math.abs(oldReset - previous.at - window) <= 60)
                                event = { kind = kind, at = at, detected_at = now,
                                    previous_at = previous.at, previous_reset_at = oldReset, reset_at = reset,
                                    previous_reset_at_raw = previous.reset_at_raw, reset_at_raw = metric.reset_at,
                                    previous_fetched_at = previous.fetched_at, fetched_at = entry.fetched_at,
                                    previous_source = previous.source, source = source,
                                    previous_percent = previous.percent, percent = percent,
                                    previous_credits = previous.credits, credits = credits,
                                    expected = kind == "renewal" or (at >= oldReset - 60
                                        and math.abs(reset - oldReset - window) <= 300),
                                    floating = isFloating,
                                    fewer_credits = fewer_credits }
                                local record = { provider = entry.id, window = key, change = event }
                                history.events[#history.events + 1] = record
                                changes[#changes + 1] = record
                            end
                        end
                        previous = { at = at, reset_at = reset, percent = percent, credits = credits,
                            source = source, event = event, fetched_at = entry.fetched_at,
                            reset_at_raw = metric.reset_at }
                        samples[key] = previous
                        history.samples[entry.id] = samples
                    end
                    -- A cached/out-of-order read must not acquire a fresh timestamp
                    -- or attach an event belonging to a different calendar.
                    metric.reset_observation = {
                        at = M.parseIso(entry.fetched_at) or (fresh and now or previous and previous.at),
                        source = source,
                        event = previous and reset == previous.reset_at and previous.event or nil,
                    }
                end
            end
        end
    end
    while #history.events > 32 do table.remove(history.events, 1) end
    for id, samples in pairs(history.samples) do
        if type(samples) ~= "table" then
            history.samples[id] = nil
        else
            for key, sample in pairs(samples) do
                if type(sample) ~= "table" or now - (tonumber(sample.at) or 0) > 30 * 86400 then samples[key] = nil end
            end
            if next(samples) == nil then history.samples[id] = nil end
        end
    end
    return history
end

-- Detection time controls the 24h notice. Old v1 histories only have reading time.
function M.weeklyResetChange(metric, nowTime)
    local observation = metric and metric.reset_observation
    local event = type(observation) == "table" and observation.event
    if type(event) ~= "table" then return nil end
    local now = nowTime or os.time()
    local at = tonumber(event.detected_at) or tonumber(event.at)
    if not at or at > now or now - at >= 86400 then return nil end
    if event.kind ~= "early_renewal" and event.kind ~= "schedule_changed" then return nil end
    if event.expected or event.floating then return nil end
    return event
end

function M.weeklyResetStatus(metric, entry, nowTime)
    local now = nowTime or os.time()
    local at = M.parseIso(metric and metric.reset_at)
    if not at or at <= now then return "pending" end
    local observation = metric and metric.reset_observation
    local fetched = type(observation) == "table" and tonumber(observation.at) or M.parseIso(entry and entry.fetched_at)
    local minutes = type(noctalia) == "table" and type(noctalia.getConfig) == "function"
        and tonumber(noctalia.getConfig("refresh_minutes")) or 5
    if (entry and entry.stale == true) or (fetched and now - fetched > math.max(900, (minutes or 5) * 120)) then
        return "stale"
    end
    return "announced"
end

function M.weeklyResetTooltip(metric, entry, nowTime)
    local status = M.weeklyResetStatus(metric, entry, nowTime)
    local lines = { "Next weekly reset announced by the provider." }
    if status == "pending" then
        lines[1] = "Weekly renewal pending confirmation. Refresh to check the provider."
    elseif status == "stale" then
        lines[#lines + 1] = "Reading is old; refresh to confirm the schedule."
    end
    local observation = metric and metric.reset_observation
    local fetched = type(observation) == "table" and tonumber(observation.at) or M.parseIso(entry and entry.fetched_at)
    local function date(at) return os.date("%Y-%m-%d %H:%M %Z", at) end
    lines[#lines + 1] = fetched and ("Last quota reading: " .. date(fetched)) or "Last quota reading: unavailable."
    if type(observation) == "table" then
        lines[#lines + 1] = "Source: " .. tostring(observation.source or "ai-usagebar")
        local event = observation.event
        -- Keep the full history on disk; only explain a recent change on hover.
        local detected = type(event) == "table" and (tonumber(event.detected_at) or tonumber(event.at))
        local age = detected and (nowTime or os.time()) - detected
        if age and age >= 0 and age < 86400 and not event.floating then
            local descriptions = { early_renewal = "Early renewal detected", renewal = "Renewal detected",
                schedule_changed = "Schedule changed; renewal not confirmed" }
            lines[#lines + 1] = (descriptions[event.kind] or "Schedule changed") .. " at " .. date(event.at) .. "."
            if tonumber(event.previous_reset_at) then lines[#lines + 1] = "Previously announced: " .. date(event.previous_reset_at) end
            if tonumber(event.reset_at) then lines[#lines + 1] = "Changed to: " .. date(event.reset_at) end
            if event.fewer_credits then lines[#lines + 1] = "Fewer reset credits available in this reading." end
        end
    end
    return table.concat(lines, "\n")
end

-- Mathematical triage model for dynamic multi-provider resource optimization:
-- Goal: Maximize useful token throughput over time without premature exhaustion,
-- ensuring all provider quotas finish near 0% by the end of their weekly (7d) or session (5h) window.
-- Schedule-aware active pacing: Pacing and velocity are calculated over effective active working hours
-- (discounting sleep and off-hours), elevating providers whose remaining active time is critically scarce.
-- Model gearing (K_m): Couples weekly quotas with 5h session windows, factoring in how many sessions
-- fit in a weekly quota (e.g. ~2.5 for Claude & GPT OSS vs ~6.3 for Codex).
-- Time-arbitrage & perishability: When weekly reset is within active reach (<= 24 active hours),
-- unspent quota risks permanent loss and receives an urgency multiplier.
-- Reset credits add their own value/deadline bonus without moving the provider's
-- weekly horizon or treating credit expiry as expiry of the current allowance.
function M.calculateModelTriageScore(item, staggerPlan, nowTime, scheduleConfig, isUserActiveNow)
    if item == nil or M.unavailable(item.entry) then
        return -1000
    end
    nowTime = nowTime or os.time()
    scheduleConfig = scheduleConfig or M.getScheduleConfig()
    if isUserActiveNow == nil then
        isUserActiveNow = true
    end

    local sMetric = item.sessionMetric
    local wMetric = item.weeklyMetric

    local sPct = sMetric and tonumber(sMetric.percent) or 0
    local wPct = wMetric and tonumber(wMetric.percent) or 0
    local sFree = math.max(0, 100 - sPct)
    local wFree = math.max(0, 100 - wPct)

    -- Hard constraints / lockouts
    -- If weekly quota is 100% exhausted, no traffic can be routed
    if wMetric ~= nil and wPct >= 100 then
        return -500 - sPct
    end
    -- If session quota is 100% exhausted, provider waits for the 5h reset
    if sMetric ~= nil and sPct >= 100 then
        local sAt = M.parseIso(sMetric.reset_at)
        local sRem = (sAt and sAt > nowTime) and (sAt - nowTime) or 18000
        return -300 - math.min(99.0, (sRem / 3600.0) * 10.0) - (wPct * 0.05)
    end

    ----------------------------------------------------------------------
    -- 1. WEEKLY MATHEMATICAL MODEL (7d): Velocity, Capacity & Gearing
    ----------------------------------------------------------------------
    local gearing = M.getModelGearing(item.providerId or (item.entry and item.entry.id), item.name)

    local wFactor = 1.0
    local uResetWeekly = 0.0
    local uBottleneck = 0.0
    local dutyCycle = 0.0
    local H_w = 0.0

    if wMetric ~= nil and M.weeklyResetStatus(wMetric, item.entry, nowTime) == "announced" then
        local wAt = wMetric and M.parseIso(wMetric.reset_at)
        H_w = M.calculateActiveHours(nowTime, wAt, scheduleConfig, isUserActiveNow)
        if H_w < 0.5 then H_w = 0.5 end

        -- Capacity and session duty cycle:
        -- In H_w active hours, max sessions = H_w / 5.0, each session burns (100 / gearing)%
        local C_max = (H_w * 20.0) / gearing
        dutyCycle = wFree / math.max(1.0, C_max)

        -- Required weekly consumption velocity ratio Pi_w relative to nominal active pace:
        local Pi_w = (wFree / H_w) * (M.nominalWeeklyActiveHours(scheduleConfig) / 100.0)
        local defaultGearing = M.DEFAULT_GEARING["default"] or 10.0
        local gearedPi_w = Pi_w * ((gearing / defaultGearing) ^ 0.60)

        -- Threshold for low headroom scales with gearing (1 session is 100/gearing %):
        local oneSessionPct = 100.0 / gearing
        local lowHeadroomPct = math.min(30.0, math.max(8.0, oneSessionPct * 0.80))

        -- Temporal distribution & anti-burst smoothing (prevents concentration of usage followed by voids):
        -- When there are still many active hours left in the week (H_w > 24.0):
        -- Evaluate pacing relative to elapsed time in the 7-day cycle.
        local paceSmooth = 1.0
        if H_w > 24.0 and wMetric.window_secs then
            local wWindow = tonumber(wMetric.window_secs) or 604800
            local wRemSecs = (wAt and wAt > nowTime) and (wAt - nowTime) or 0
            local wElapsedRatio = math.min(1.0, math.max(0.0, (wWindow - wRemSecs) / wWindow))
            local expectedBurn = wElapsedRatio * 100.0
            local overPace = wPct - expectedBurn
            if overPace > 15.0 then
                -- Ahead of pace: smoothly dampen to avoid exhausting quota days before renewal
                paceSmooth = math.max(0.35, 1.0 - 0.02 * (overPace - 15.0))
            elseif overPace < -15.0 then
                -- Behind pace: gently favor to ensure smooth utilization of available quota
                paceSmooth = math.min(1.35, 1.0 + 0.015 * (-overPace - 15.0))
            end
        end

        if wFree <= lowHeadroomPct and H_w > 24.0 then
            wFactor = (0.08 + 0.15 * (wFree / lowHeadroomPct)) * paceSmooth
        else
            -- Continuous weighting function: smooth scaling modulated by temporal pacing
            wFactor = math.min(1.80, math.max(0.20, (0.40 + 0.60 * gearedPi_w) * paceSmooth))
        end

        -- Time-arbitrage and perishability urgency for imminent weekly reset (<= 24 active hours):
        -- Reflects that quotas expire permanently if not consumed.
        -- When active hours <= 24h, remaining 5h sessions are scarce.
        local sprintH = H_w
        if sprintH <= 24.0 and wFree > 0.5 then
            local ratio = math.min(8.0, (24.0 / math.max(0.5, sprintH)) ^ 1.25)
            local sprintBonus = sprintH <= 3.0 and (220.0 * (3.0 - sprintH) / 3.0) or 0.0
            uResetWeekly = 50.0 + sprintBonus + (wFree * 4.0 * ratio)
        end

        -- Unified capacity bottleneck urgency when session slots are scarce:
        if dutyCycle >= 0.70 and wFree >= 5.0 and H_w > 24.0 then
            local excess = math.min(1.5, dutyCycle - 0.50)
            uBottleneck = 20.0 * (wFree / 100.0) * excess
        end
    end

    ----------------------------------------------------------------------
    -- 2. SESSION MATHEMATICAL MODEL (5h) AND WEEKLY COUPLING
    ----------------------------------------------------------------------
    local score = 0.0

    if sMetric ~= nil then
        local sAt = M.parseIso(sMetric.reset_at)
        local sStarted = M.isSessionStarted(sMetric)
        local sWindow = tonumber(sMetric.window_secs) or 18000
        local sRemainingSecs = (sStarted and sAt and sAt > nowTime)
            and math.max(1, sAt - nowTime)
            or (sStarted and 1 or sWindow)
        local H_s = M.calculateActiveHours(nowTime, nowTime + sRemainingSecs, scheduleConfig, isUserActiveNow)
        if H_s < 0.05 then H_s = 0.05 end

        if sStarted then
            -- Active session: 5h timer is running
            local sElapsedRatio = math.min(1.0, math.max(0.0, (sWindow - sRemainingSecs) / sWindow))
            local sUrgencyFactor = 1.0 + 1.80 * (sElapsedRatio * sElapsedRatio)
            local baseSession = sFree * sUrgencyFactor

            -- Critical session burn urgency if effective active time before sleep/reset <= 1.5h
            local uBurnSession = 0.0
            if H_s <= 1.50 and sFree >= 15.0 then
                local burnUrgency = (1.50 - H_s) / 1.50
                uBurnSession = 50.0 * (sFree / 100.0) * burnUrgency
            end

            -- Coupling: session velocity modulated by weekly pace factor and bonuses
            score = (baseSession * wFactor) + uBurnSession + uResetWeekly + uBottleneck
        else
            -- Uninitiated session (0% usage, timer not yet started):
            -- Discounted if available active time before sleep/off-hours is short
            local availabilityDiscount = math.min(1.0, math.max(0.35, H_s / 5.0))
            local baseSession = sFree * 0.75 * availabilityDiscount
            score = (baseSession * wFactor) + uResetWeekly + uBottleneck
        end
    else
        -- No session metric: optimize directly on weekly quota
        score = (wFree * wFactor) + uResetWeekly + uBottleneck
    end

    local providerId = (item.entry and item.entry.id) or item.providerId
    if staggerPlan and staggerPlan.fastTrack and staggerPlan.fastTrack[providerId] then
        local advice = staggerPlan.creditAdvice and staggerPlan.creditAdvice[providerId]
        local urgency = M.resetCreditUrgency(item, advice, nowTime, scheduleConfig, isUserActiveNow)
        if urgency then score = score + urgency.bonus end
    end
    return score
end

-- ── Typographic scaling & presets ─────────────────────────────────────────────
local PRESET_FACTORS = {
    compact = 0.85,
    small = 0.85,
    normal = 1.00,
    medium = 1.00,
    large = 1.15,
    huge = 1.30,
    xlarge = 1.30,
    ["extra-large"] = 1.30,
    ["extra_large"] = 1.30,
}

function M.getTypography(customPreset)
    local preset = customPreset
    if preset == nil or preset == "" or preset == "inherit" then
        if noctalia and type(noctalia.getConfig) == "function" then
            preset = noctalia.getConfig("font_scale")
        end
    end
    preset = tostring(preset or "normal"):lower()
    local num = tonumber(preset)
    local factor = num or PRESET_FACTORS[preset] or 1.00
    if factor < 0.50 then factor = 0.50 end
    if factor > 2.00 then factor = 2.00 end

    return {
        preset = preset,
        factor = factor,
        fontSize = function(base)
            return math.max(7, math.floor((base or 11) * factor + 0.5))
        end,
        glyphSize = function(base)
            return math.max(8, math.floor((base or 14) * factor + 0.5))
        end,
    }
end

return M
