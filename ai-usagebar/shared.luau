--!nonstrict
-- What the capsule and the panel both need, in one copy, so the ISO parsing and
-- the severity tiers cannot drift between two entries that have to agree on
-- screen. Needs plugin_api 22, where require() arrived.

local M = {}

-- Tabler has no Anthropic mark, so providers without a brand glyph use a
-- semantic one. Roles keep service identity distinct without hardcoded colors.
M.PROVIDER_VISUALS = {
    anthropic = { glyph = "asterisk-simple", role = "tertiary" },
    anthropic_api = { glyph = "asterisk-simple", role = "tertiary" },
    openai = { glyph = "brand-openai", role = "primary" },
    zai = { glyph = "bolt", role = "tertiary" },
    openrouter = { glyph = "route", role = "secondary" },
    deepseek = { glyph = "fish", role = "primary" },
    kimi = { glyph = "moon", role = "tertiary" },
    moonshot = { glyph = "moon", role = "tertiary" },
    kilo = { glyph = "robot", role = "secondary" },
    novita = { glyph = "cloud", role = "secondary" },
    grok = { glyph = "brand-x", role = "on_surface" },
    supergrok = { glyph = "brand-x", role = "on_surface" },
    antigravity = { glyph = "sparkles", role = "secondary" },
    cursor = { glyph = "cursor-text", role = "primary" },
    minimax = { glyph = "wave-square", role = "secondary" },
    kiro = { glyph = "ghost", role = "secondary" },
    copilot = { glyph = "brand-github-copilot", role = "secondary" },
    gemini = { glyph = "brand-google", role = "secondary" },
}

local DEFAULT_PROVIDER_VISUAL = { glyph = "brain", role = "on_surface_variant" }

function M.providerVisual(id)
    return M.PROVIDER_VISUALS[tostring(id)] or DEFAULT_PROVIDER_VISUAL
end

-- Ask the poller for a read. It only looks at `action`; `at` is never read, and
-- is there so two requests in a row are not the same value. nowMs is the only
-- sub-second clock the API has, so os.time() would stamp two clicks in the same
-- second identically.
function M.requestRefresh()
    noctalia.state.set("command", { action = "refresh", at = noctalia.nowMs() })
end

-- Anything else in the `error` slot means no failure.
M.NO_FAILURE = { code = "", detail = "" }

function M.asFailure(value)
    return type(value) == "table" and value or M.NO_FAILURE
end

-- "2026-08-15T11:29:59.872624Z" -> unix seconds. The stamps are UTC, and
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
    local utcAsLocal = os.time(os.date("!*t", asLocal))
    return asLocal + (asLocal - utcAsLocal)
end

function M.formatDuration(seconds)
    if seconds <= 0 then return noctalia.tr("ui.now") end
    local minutes = math.floor(seconds / 60)
    local days = math.floor(minutes / 1440)
    local hours = math.floor((minutes % 1440) / 60)
    local rest = minutes % 60
    if days > 0 then return string.format("%dd %dh", days, hours) end
    if hours > 0 then return string.format("%dh %dm", hours, rest) end
    return string.format("%dm", rest)
end

-- How long the window this section describes has left.
function M.countdown(section)
    local at = M.parseIso(section and section.reset_at)
    if at == nil then return "" end
    return M.formatDuration(at - os.time())
end

-- Where the countdown lands: "14:20" today, "Sat 14:20" past midnight, and a date
-- once a weekday alone stops naming one day.
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

-- How much of the window is gone, out of "Resets in 1h 58m · 60% elapsed · 30pts
-- ahead". Both entries draw it under the quota bar.
function M.elapsedPercent(detail)
    local value = tostring(detail or ""):match("(%d+)%%%s*elapsed")
    return value ~= nil and tonumber(value) or nil
end

-- A provider can report more than it was given, so clamp before this becomes a
-- bar width.
function M.ratio(percent)
    local value = (tonumber(percent) or 0) / 100
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

function M.headline(entry)
    if type(entry) ~= "table" or type(entry.metrics) ~= "table" then return nil end
    return entry.metrics[1]
end

-- The CLI tiers every percentage, and copying its thresholds here would be a
-- second source of truth. `calm` is for when it raised nothing: text stays on the
-- surface colour, and the accent is kept for bar fills.
function M.severityRole(section, calm)
    local severity = tostring(section and section.severity or "")
    if severity == "critical" then return "error" end
    if severity == "high" then return "tertiary" end
    return calm
end

return M
