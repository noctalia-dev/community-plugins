--!nonstrict
-- Everything the poller, the capsule and the panel all need, in one copy, so the
-- session maths and the text hygiene cannot drift between three entries that
-- must agree on screen. Needs plugin_api 22 for require().
--
-- Ported from the QML helpers in Snackwrap/omarchy-f1 (MIT).

local M = {}

M.JOLPICA = "https://api.jolpi.ca/ergast/f1/"
M.OPENF1 = "https://api.openf1.org/v1/"
M.USER_AGENT = "User-Agent: gcap0n1-noctalia-f1/0.1"

-- Ceilings for anything that comes back from the network. noctalia.http has no
-- size limit of its own, so a response is rejected here before it is decoded.
M.MAX_BODY_BYTES = 1048576
M.MAX_FIELD_CHARS = 72

-- ── Remote data hygiene ──────────────────────────────────────────────────────

-- Control characters, C1 controls and invisible bidi/format marks can reorder or
-- hide what is shown without changing what was checked. All patterns are UTF-8
-- byte sequences: U+0080-009F, U+061C, U+200B-200F, U+202A-202E, U+2060-2064,
-- U+2066-206F and U+FEFF.
local STRIP_PATTERNS = {
    "[%c\127]",
    "\194[\128-\159]",
    "\216\156",
    "\226\128[\139-\143]",
    "\226\128[\170-\174]",
    "\226\129[\160-\164]",
    "\226\129[\166-\175]",
    "\239\187\191",
}

-- Clamp a remote value to printable text of at most `limit` characters.
function M.safe(value, limit)
    local text = tostring(value == nil and "" or value)
    for _, pattern in ipairs(STRIP_PATTERNS) do
        text = text:gsub(pattern, " ")
    end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    local cap = limit or M.MAX_FIELD_CHARS
    local length = utf8.len(text)
    if length == nil then
        -- Not valid UTF-8: keep only ASCII rather than show mojibake.
        text = text:gsub("[\128-\255]", "?")
        length = #text
    end
    if length > cap then
        text = text:sub(1, utf8.offset(text, cap + 1) - 1) .. "…"
    end
    return text
end

-- Keep an array from a remote payload to a sane size before anything walks it.
function M.bounded(list, cap)
    if type(list) ~= "table" then return {} end
    if #list <= cap then return list end
    local out = {}
    for i = 1, cap do out[i] = list[i] end
    return out
end

-- Wikipedia links arrive inside the API payload, so the destination is remote
-- data. Only https links to hosts this data is documented to reference are
-- opened, and anything with userinfo, a port or an odd length is dropped.
local LINK_HOSTS = { ["en.wikipedia.org"] = true, ["www.wikipedia.org"] = true, ["wikipedia.org"] = true }

function M.openLink(url)
    local raw = tostring(url or "")
    if #raw > 400 or raw:sub(1, 8) ~= "https://" then return end
    if raw:find("[%c%s]") then return end
    local rest = raw:sub(9)
    local host = rest:match("^([^/?#]*)")
    if host == nil or host == "" or host:find("[@:]") then return end
    if not LINK_HOSTS[host:lower()] then return end
    noctalia.runAsync({ "xdg-open", raw })
end

-- ── Time ─────────────────────────────────────────────────────────────────────

-- Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant).
local function daysFromCivil(y, m, d)
    if m <= 2 then y -= 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = m > 2 and (m - 3) or (m + 9)
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

-- "2026-10-11" + "12:00:00Z" -> Unix seconds (UTC), or nil.
function M.parseUtc(dateStr, timeStr)
    local y, m, d = tostring(dateStr or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if y == nil then return nil end
    local hh, mm, ss = tostring(timeStr or "00:00:00Z"):match("^(%d%d):(%d%d):?(%d*)")
    if hh == nil then hh, mm, ss = "0", "0", "0" end
    return daysFromCivil(tonumber(y), tonumber(m), tonumber(d))
        * 86400 + tonumber(hh) * 3600 + tonumber(mm) * 60 + (tonumber(ss) or 0)
end

-- OpenF1 timestamp "2026-10-10T08:17:42.627000+00:00" -> Unix seconds, or nil.
function M.parseIso(text)
    local s = tostring(text or "")
    local y, mo, d, hh, mm, ss = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if y == nil then return nil end
    local t = daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
        + tonumber(hh) * 3600 + tonumber(mm) * 60 + tonumber(ss)
    local sign, oh, om = s:match("([+-])(%d%d):(%d%d)$")
    if sign ~= nil then
        local offset = tonumber(oh) * 3600 + tonumber(om) * 60
        t = sign == "+" and (t - offset) or (t + offset)
    end
    return t
end

-- Whole seconds since the epoch. os.time() is the host clock in UTC seconds.
function M.nowSec()
    return os.time()
end

-- "4d", "3h", "12m", "<1m": the short form for the bar pill.
function M.fmtShort(seconds)
    if seconds <= 0 then return noctalia.tr("countdown.live") end
    local s = math.floor(seconds)
    local d = s // 86400
    s -= d * 86400
    local h = s // 3600
    s -= h * 3600
    local m = s // 60
    if d > 0 then return d .. "d" end
    if h > 0 then return h .. "h" end
    if m > 0 then return m .. "m" end
    return noctalia.tr("countdown.under_minute")
end

-- "in 4d 21h 36m", or "live now" once the time has come.
function M.fmtLong(seconds)
    if seconds <= 0 then return noctalia.tr("countdown.live_now") end
    local s = math.floor(seconds)
    local d = s // 86400
    s -= d * 86400
    local h = s // 3600
    s -= h * 3600
    local m = s // 60
    local parts = {}
    if d > 0 then parts[#parts + 1] = d .. "d" end
    if h > 0 then parts[#parts + 1] = h .. "h" end
    parts[#parts + 1] = m .. "m"
    return noctalia.tr("countdown.in", { time = table.concat(parts, " ") })
end

-- Local weekday + time, honouring the 12/24 h setting. `long` adds the date.
function M.fmtDateTime(ts, long)
    local twelve = noctalia.getConfig("time_format") == "12h"
    local pattern
    if long then
        pattern = twelve and "{:%a %d %b, %I:%M %p}" or "{:%a %d %b, %H:%M}"
    else
        pattern = twelve and "{:%a %I:%M %p}" or "{:%a %H:%M}"
    end
    return noctalia.formatTime(pattern, ts)
end

-- ── Sessions ─────────────────────────────────────────────────────────────────

-- Build the sorted session list from one Jolpica race object. Each entry is
-- { id = "fp1", ts = <unix seconds> }; `id` selects the translated name.
function M.buildSessions(race)
    if type(race) ~= "table" then return {} end
    local raw = {
        { id = "fp1", s = race.FirstPractice },
        { id = "fp2", s = race.SecondPractice },
        { id = "fp3", s = race.ThirdPractice },
        { id = "sprint_quali", s = race.SprintQualifying },
        { id = "sprint", s = race.Sprint },
        { id = "quali", s = race.Qualifying },
        { id = "race", s = { date = race.date, time = race.time } },
    }
    local out = {}
    for _, item in ipairs(raw) do
        if type(item.s) == "table" then
            local ts = M.parseUtc(item.s.date, item.s.time)
            if ts ~= nil then out[#out + 1] = { id = item.id, ts = ts } end
        end
    end
    table.sort(out, function(a, b) return a.ts < b.ts end)
    return out
end

function M.sessionTs(sessions, id)
    for _, s in ipairs(sessions or {}) do
        if s.id == id then return s.ts end
    end
    return nil
end

-- First session that has not started yet.
function M.nextSession(sessions, now)
    for _, s in ipairs(sessions or {}) do
        if s.ts > now then return s end
    end
    return nil
end

-- Near a scheduled session: 15 minutes before it starts until 3 hours after.
-- The only window in which OpenF1 is touched at all.
function M.nearSession(sessions, now)
    for _, s in ipairs(sessions or {}) do
        if now >= s.ts - 15 * 60 and now <= s.ts + 3 * 3600 then return true end
    end
    return false
end

-- The starting grid exists once qualifying is over (plus an hour of buffer) and
-- the race has not started.
function M.gridApplicable(sessions, now)
    local quali = M.sessionTs(sessions, "quali")
    local race = M.sessionTs(sessions, "race")
    if quali == nil or race == nil then return false end
    return now >= quali + 3600 and now < race
end

-- ── Teams ────────────────────────────────────────────────────────────────────

-- Approximate 2026 constructor colours keyed by Ergast/Jolpica constructorId,
-- used for the small team chips in the tables. Live rows carry their own colour.
local TEAM_COLORS = {
    mercedes = "#27F4D2",
    ferrari = "#E8002D",
    mclaren = "#FF8000",
    red_bull = "#3671C6",
    rb = "#6692FF",
    alpine = "#00A1E8",
    haas = "#B6BABD",
    audi = "#BB0A30",
    williams = "#64C4FF",
    aston_martin = "#229971",
    cadillac = "#C4A24A",
    -- historical / fallbacks
    sauber = "#52E252",
    alphatauri = "#5E8FAA",
    alfa = "#C92D4B",
    renault = "#FFF500",
}

function M.teamColor(constructorId, fallback)
    return TEAM_COLORS[constructorId] or fallback
end

-- OpenF1 gives team colours as bare hex ("27F4D2"); accept only that shape.
function M.hexColor(raw)
    local hex = tostring(raw or "")
    if hex:match("^%x%x%x%x%x%x$") then return "#" .. hex:upper() end
    return nil
end

local FLAG_KEYS = {
    ["GREEN"] = "flag.green",
    ["CLEAR"] = "flag.clear",
    ["YELLOW"] = "flag.yellow",
    ["DOUBLE YELLOW"] = "flag.double_yellow",
    ["RED"] = "flag.red",
    ["CHEQUERED"] = "flag.chequered",
    ["BLUE"] = "flag.blue",
}

function M.friendlyFlag(flag)
    if flag == nil or flag == "" then return "" end
    local key = FLAG_KEYS[flag]
    if key ~= nil then return noctalia.tr(key) end
    return M.safe(flag, 24)
end

-- ── Live state helpers ───────────────────────────────────────────────────────

-- Live only when near a session AND the position feed is genuinely fresh, which
-- guards against session_key=latest resolving to a session that already ended.
function M.liveActive(live, sessions, now, debug)
    if type(live) ~= "table" or type(live.rows) ~= "table" or #live.rows == 0 then return false end
    if debug then return true end
    if not M.nearSession(sessions, now) then return false end
    return live.latestSec ~= nil and live.latestSec > 0 and (now - live.latestSec) < 15 * 60
end

return M
