--!nonstrict
-- Reads the messages of F1's live-timing stream (see f1-live.sh) and turns them
-- into the table the Live tab shows. Used only by the experimental "F1
-- live-timing stream" source; the service owns the process, this file only
-- parses and derives.
--
-- The stream is SignalR Core JSON. Each SSE line is "data: <frame>\30<frame>...".
-- Frames that matter:
--   { type = 3, result = { <feed> = <full snapshot>, ... } }   answer to Subscribe
--   { type = 1, target = "feed", arguments = { <feed>, <partial update>, <time> } }
-- A partial update is a sparse copy of the snapshot: only the changed keys are
-- present, and array elements are addressed by 0-based string keys
-- ({"BestLapTimes": {"1": {"Value": "1:32.2"}}}). Snapshots are therefore
-- normalised to string keys ("0", "1", ...) so one deep merge handles both.

local shared = require("./shared.luau")

local M = {}

local RS = "\30"
local MAX_LINE_BYTES = 4 * 1024 * 1024    -- the first snapshot is ~50 KB; refuse anything absurd
local MAX_DRIVERS = 30

local feeds = {}                          -- feed name -> normalised table
local lastMessageSec = 0

-- ── State ────────────────────────────────────────────────────────────────────

local function normalise(value)
    if type(value) ~= "table" then return value end
    local out = {}
    if #value > 0 then
        for i = 1, #value do out[tostring(i - 1)] = normalise(value[i]) end
    else
        for k, v in pairs(value) do
            if k ~= "_kf" then out[tostring(k)] = normalise(v) end
        end
    end
    return out
end

local function merge(into, patch)
    for k, v in pairs(patch) do
        if k ~= "_kf" then
            if type(v) == "table" and type(into[k]) == "table" then
                merge(into[k], v)
            else
                into[k] = v
            end
        end
    end
end

function M.reset()
    feeds = {}
    lastMessageSec = 0
end

function M.hasData()
    return type(feeds.TimingData) == "table" and type(feeds.TimingData.Lines) == "table"
end

-- Feed one stdout line from f1-live.sh. Returns true when the state changed.
function M.handleLine(line)
    if #line > MAX_LINE_BYTES then return false end
    if line:sub(1, 5) ~= "data:" then return false end
    local changed = false
    for frame in line:sub(6):gmatch("[^" .. RS .. "]+") do
        local payload = frame:gsub("^%s+", "")
        if payload:sub(1, 1) == "{" then
            local message = noctalia.json.decode(payload)
            if type(message) == "table" then
                if message.type == 3 and type(message.result) == "table" then
                    for name, data in pairs(message.result) do
                        if type(name) == "string" and type(data) == "table" then
                            feeds[name] = normalise(data)
                        end
                    end
                    changed = true
                elseif message.type == 1 and message.target == "feed" and type(message.arguments) == "table" then
                    local name, data = message.arguments[1], message.arguments[2]
                    if type(name) == "string" and type(data) == "table" then
                        if type(feeds[name]) ~= "table" then feeds[name] = {} end
                        merge(feeds[name], normalise(data))
                        changed = true
                    end
                end
            end
        end
    end
    if changed then lastMessageSec = shared.nowSec() end
    return changed
end

-- ── Derived view ─────────────────────────────────────────────────────────────

-- F1's TrackStatus messages -> the flag names shared.friendlyFlag translates.
local TRACK_STATUS = {
    AllClear = "CLEAR",
    Yellow = "YELLOW",
    Red = "RED",
    SCDeployed = "SAFETY CAR",
    VSCDeployed = "VSC",
    VSCEnding = "VSC ENDING",
}

local function text(value, limit)
    if value == nil then return "" end
    return shared.safe(value, limit or 12)
end

local function valueOf(node)
    if type(node) == "table" then return text(node.Value) end
    return ""
end

-- "00:12:34" -> seconds.
local function clockSeconds(raw)
    local h, m, s = tostring(raw or ""):match("^(%d+):(%d%d):(%d%d)")
    if h == nil then return nil end
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
end

-- "1:31.639" or "59.123" -> seconds, or nil.
local function lapSeconds(raw)
    local m, sec = tostring(raw or ""):match("^(%d+):(%d+%.%d+)$")
    if m ~= nil then return tonumber(m) * 60 + tonumber(sec) end
    local only = tostring(raw or ""):match("^(%d+%.%d+)$")
    if only ~= nil then return tonumber(only) end
    return nil
end

-- One driver's row. `part` is the qualifying part (1..3) or 0 outside qualifying.
local function buildRow(number, line, driver, part)
    local best, gap = "", ""
    local state, outPart = "", 0
    local qualifying = part > 0

    local secondsByPart, bestPart = {}, 0
    if qualifying then
        local times = type(line.BestLapTimes) == "table" and line.BestLapTimes or {}
        for p = 1, 3 do
            secondsByPart[p] = lapSeconds(valueOf(times[tostring(p - 1)]))
        end
        -- The time for the part in progress; a driver who has not set one yet
        -- keeps the best of an earlier part, shown dimmed by the panel.
        for p = part, 1, -1 do
            local v = valueOf(times[tostring(p - 1)])
            if v ~= "" then
                best, bestPart = v, p
                if p < part then state = "prev" end
                break
            end
        end
        if line.KnockedOut == true then
            state = "out"
            for p = 3, 1, -1 do
                if valueOf(times[tostring(p - 1)]) ~= "" then outPart = p break end
            end
            if outPart == 0 then outPart = part end
        elseif line.Cutoff == true then
            state = "danger"
        end
    else
        -- Race and practice: the gap to the leader, or the best lap.
        local toLeader = text(line.GapToLeader)
        if toLeader ~= "" then
            best, gap = toLeader, valueOf(line.IntervalToPositionAhead)
        else
            best = valueOf(line.BestLapTime)
        end
    end

    return {
        pos = tonumber(line.Position) or 99,
        order = tonumber(line.Line) or 99,
        code = text(driver.Tla ~= nil and driver.Tla or ("#" .. number), 4),
        color = shared.hexColor(driver.TeamColour) or "",
        team = text(driver.TeamName, 32),
        best = best,
        gap = gap,
        state = state,
        outPart = outPart,
        inPit = line.InPit == true,
        seconds = secondsByPart,
        bestPart = bestPart,
    }
end

-- The table the Live tab consumes, or nil before the first snapshot.
function M.view(now)
    local timing = feeds.TimingData
    if type(timing) ~= "table" or type(timing.Lines) ~= "table" then return nil end
    local drivers = type(feeds.DriverList) == "table" and feeds.DriverList or {}
    local info = type(feeds.SessionInfo) == "table" and feeds.SessionInfo or {}

    local sessionType = text(info.Type, 24)
    local part = (sessionType == "Qualifying") and (tonumber(timing.SessionPart) or 0) or 0

    local rows = {}
    for number, line in pairs(timing.Lines) do
        if tostring(number):match("^%d%d?%d?$") and type(line) == "table" and #rows < MAX_DRIVERS then
            local driver = type(drivers[number]) == "table" and drivers[number] or {}
            rows[#rows + 1] = buildRow(number, line, driver, part)
        end
    end
    table.sort(rows, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.pos < b.pos
    end)
    for i, row in ipairs(rows) do row.pos = i end

    -- Qualifying gaps: the feed does not fill them for every part, so they are
    -- computed from the times, against the first driver in the order shown that
    -- has a time in the same part. A time ahead of the leader's (not yet counted
    -- by the timing system) shows no gap rather than a negative one.
    if part > 0 then
        local leader = {}
        for _, row in ipairs(rows) do
            for p = 1, 3 do
                if leader[p] == nil and row.seconds[p] ~= nil then leader[p] = row.seconds[p] end
            end
        end
        for _, row in ipairs(rows) do
            local t = row.seconds[row.bestPart]
            local f = leader[row.bestPart]
            if t ~= nil and f ~= nil and t - f > 0.0005 then
                row.gap = string.format("+%.3f", t - f)
            end
        end
    end
    for _, row in ipairs(rows) do
        row.seconds = nil   -- not needed by the panel
    end

    local status = type(feeds.TrackStatus) == "table" and feeds.TrackStatus.Message or nil
    local flag = TRACK_STATUS[tostring(status or "")] or ""

    -- Session clock: the time left, ticking if the feed says it is running.
    local clock = nil
    local extrapolated = feeds.ExtrapolatedClock
    if type(extrapolated) == "table" then
        local remaining = clockSeconds(extrapolated.Remaining)
        if remaining ~= nil then
            local at = shared.parseIso(extrapolated.Utc) or now
            clock = { remaining = remaining, at = at, running = extrapolated.Extrapolating == true }
        end
    end

    return {
        rows = rows,
        flag = flag,
        latestSec = lastMessageSec,
        session = {
            name = text(info.Name, 24),
            kind = sessionType,
            part = part,
            status = text(info.SessionStatus, 16),
        },
        clock = clock,
    }
end

return M
