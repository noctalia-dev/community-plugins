--!nonstrict
-- What the capsule and the panel both need, in one copy, so the parsing and the
-- severity tiers cannot drift between two entries that agree on screen. Needs
-- plugin_api 22, where require() arrived.

local M = {}

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
    gemini = "brand-google",
}

function M.baseProvider(id)
    return (tostring(id or ""):match("^[^@]+") or "")
end

function M.providerGlyph(id)
    return PROVIDER_GLYPHS[M.baseProvider(id)] or "brain"
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
            if M.saysError(value) then
                return noctalia.string.trim(value)
            end
        end
    end
    return ""
end

function M.unavailable(entry)
    return M.warning(entry) ~= ""
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

function M.countdown(section)
    local at = M.parseIso(section and section.reset_at)
    if at == nil then return "" end
    return formatDuration(at - os.time())
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

function M.entries(report)
    if type(report) ~= "table" or type(report.entries) ~= "table" then return {} end
    return report.entries
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
    local first = entry.metrics[1]
    return type(first) == "table" and first or nil
end

-- Kept next to the role both entries colour with, so the tiers cannot be edited
-- in one file and forgotten in the other. `low` falls through to 0, like
-- anything the CLI adds later.
M.SEVERITY_RANK = { critical = 3, high = 2, mid = 1 }

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

return M
