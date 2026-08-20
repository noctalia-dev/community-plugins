--!nonstrict
-- What the capsule and the panel both need.
--
-- One copy, so the ISO parsing, the severity tiers and the provider glyphs
-- cannot drift between two entries that have to agree with each other on
-- screen. Needs plugin_api 22, which is where require() arrived.

local M = {}

-- Tabler has no Anthropic mark, so providers without a brand glyph get a
-- semantic one. Same approach the other CLI-backed meters in this repo take.
M.GLYPHS = {
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
    copilot = "brand-github-copilot",
    gemini = "brand-google",
}

-- The poller names the failure, so a subscriber only ever has a code to
-- translate. Anything else in that state slot reads as no failure at all.
M.NO_FAILURE = { code = "", detail = "" }

function M.asFailure(value)
    return type(value) == "table" and value or M.NO_FAILURE
end

-- "2026-08-15T11:29:59.872624Z" -> unix seconds. The stamps are UTC, so the
-- naive os.time() reading (which assumes local time) is corrected by the local
-- offset measured at that same instant.
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

-- The clock time the countdown lands on: "14:20" today, "Sat 14:20" past
-- midnight, and a date once a weekday alone stops naming one day.
function M.resetClock(section)
    local at = M.parseIso(section and section.reset_at)
    if at == nil then return "" end
    local clock = noctalia.formatTime(noctalia.timeFormat(), at)
    if os.date("%Y-%m-%d", at) == os.date("%Y-%m-%d") then return clock end
    -- The weekday is prepended here instead of folded into the pattern: the
    -- host's format grammar passes unknown text through verbatim, so a "ddd"
    -- prefix would render as the literal word.
    if at - os.time() > 6 * 86400 then return os.date("%d %b", at) .. " " .. clock end
    return os.date("%a", at) .. " " .. clock
end

-- A provider can report more than it was given, so the reading is clamped
-- before it becomes a bar width.
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

-- The CLI tiers every percentage; copying its thresholds here would be a second
-- source of truth. `calm` is what to use when it has raised nothing: text stays
-- on the surface colour, and the accent is kept for bar fills.
function M.severityRole(section, calm)
    local severity = tostring(section and section.severity or "")
    if severity == "critical" then return "error" end
    if severity == "high" then return "tertiary" end
    return calm
end

return M
