--!nonstrict
-- Headless poller: the only entry that touches the network. It fetches the next
-- race, both championships, the last result and the starting grid from Jolpica,
-- and live positions and flags from OpenF1 while a session is on, then publishes
-- the cleaned result into noctalia.state for the capsule and the panel.
--
-- State keys written here:
--   race          { season, round, name, circuitId, circuitName, locality, country,
--                   url, sessions = { { id, ts } ... } }            or nil
--   drivers       { loaded, rows = { {pos, code, team, teamId, pts, gap, url} } }
--   constructors  { loaded, rows = { {pos, name, teamId, pts, gap, url} } }
--   grid          { loaded, rows = { {pos, code, team, teamId, detail, url} } }
--   results       { loaded, raceName, rows = { {pos, code, team, teamId, detail, pts, url} } }
--   live          { rows = { {pos, code, color, team, best, gap, state, outPart, inPit} },
--                   flag, latestSec, error, source, session, clock }
--   status        { loading, error }
--
-- Network calls made by this file, all HTTPS GET, no credentials:
--   api.jolpi.ca  current/next, current/driverStandings, current/constructorStandings,
--                 current/last/results, current/<round>/qualifying
--   livetiming.formula1.com  static/SessionInfo.json (the start time of the current session),
--                 once a minute from 3 h before the first session of the weekend to 4 h after the race.
--   api.openf1.org drivers, position, race_control with session_key=latest, polled
--                 every 15 s only from 15 minutes before a session until 3 hours after.
-- This file writes nothing to disk and spawns no process.

local shared = require("./shared.luau")
local f1feed = require("./f1feed.luau")

local SCHEDULE_EVERY = 6 * 3600       -- refetch the schedule every 6 hours
local STANDINGS_EVERY = 3 * 3600      -- standings and last result every 3 hours
local LIVE_EVERY_MS = 15000           -- OpenF1 allows 30 requests a minute
local MIN_REFRESH_GAP_MS = 5000

local JOLPICA = shared.JOLPICA
local OPENF1 = shared.OPENF1

local race = nil                      -- processed race table, mirrored in state
local sessions = {}                   -- effective sessions (published times + manual fixes)
local rawSessions = {}                -- sessions exactly as the schedule API gave them
local fixedTs = {}                    -- session id -> start corrected by hand (`delay`), Unix seconds
local autoTs = {}                     -- session id -> start reported by the F1 timing feed
local forceTabs = noctalia.getConfig("debug_force_tabs") == true

-- Next time (Unix seconds) each dataset is due, and in-flight guards.
local due = { schedule = 0, standings = 0, results = 0 }
local busy = {}                       -- busy[name] = true while a request is out
local gridRound = nil                 -- round the grid was last loaded for
local gridDebug = false
local postRaceRound = nil             -- round whose post-race refresh already ran
local lastLiveMs = 0
local lastRefreshMs = 0
local driversMap = nil                -- OpenF1 driver_number -> { acr, color, team }
local liveRows, liveFlag, liveLatest, liveError = {}, "", 0, nil

local function setStatus(loading, errorText)
    noctalia.state.set("status", { loading = loading, error = errorText or "" })
end

-- GET a JSON document. `onData` gets the decoded table; `onFail` gets a short
-- reason ("net", "http 429", "parse", "size") and the HTTP status.
--
-- `opts.scoped`: the answer only matters for the race that was current when the
-- request went out, so it is dropped if the race changed meanwhile (grid and
-- live timing). Standings and results are global and are never dropped.
-- `opts.auth`: send the OpenF1 bearer token when one is held.
local generation = 0
local token, tokenExpiresAt = nil, 0

local function getJson(url, onData, onFail, opts)
    local options = opts or {}
    local mine = generation
    local headers = { shared.USER_AGENT, "Accept: application/json" }
    if options.auth and token ~= nil then
        headers[#headers + 1] = "Authorization: Bearer " .. token
    end
    local started = noctalia.http({
        url = url,
        headers = headers,
        follow_redirects = true,
    }, function(res)
        if options.scoped and mine ~= generation then return end
        if not res.ok then
            if onFail then onFail("net", 0) end
            return
        end
        if res.status ~= 200 then
            if onFail then onFail("http " .. tostring(res.status), res.status) end
            return
        end
        local body = res.body or ""
        if #body == 0 or #body > shared.MAX_BODY_BYTES then
            if onFail then onFail("size", res.status) end
            return
        end
        if body:sub(1, 3) == "\239\187\191" then body = body:sub(4) end   -- UTF-8 BOM
        local decoded = noctalia.json.decode(body)
        if type(decoded) ~= "table" then
            if onFail then onFail("parse", res.status) end
            return
        end
        onData(decoded)
    end)
    if not started and onFail then onFail("net", 0) end
end

-- Safe nested read: path(t, "a", "b") -> t.a.b or nil, without indexing nil.
local function path(t, ...)
    local cur = t
    for _, key in ipairs({ ... }) do
        if type(cur) ~= "table" then return nil end
        cur = cur[key]
    end
    return cur
end

local function driverCode(driver)
    if type(driver) ~= "table" then return "?" end
    if driver.code ~= nil then return shared.safe(driver.code, 4) end
    return shared.safe(tostring(driver.familyName or "?"):sub(1, 3):upper(), 4)
end

local function lastOf(list)
    if type(list) == "table" and #list > 0 then return list[#list] end
    return nil
end

-- ── Session times ────────────────────────────────────────────────────────────

-- The schedule API publishes planned times and is not updated when a session is
-- delayed (rain, red flags). F1's own timing feed (SessionInfo.json) is: it
-- carries the start time the organisers are currently running to, so that is
-- what overrides the published time, automatically. A correction made by hand
-- with `delay` takes precedence over both and is only a fallback for the case
-- where that feed is unavailable. Corrections are absolute times, so they stay
-- right if the API later catches up, and each entry carries `delay` (minutes
-- against the published time) for the panel to show.
local KNOWN_SESSIONS = { fp1 = true, fp2 = true, fp3 = true, sprint_quali = true, sprint = true, quali = true, race = true }

local function effectiveSessions()
    local out = {}
    for _, base in ipairs(rawSessions) do
        local ts = fixedTs[base.id] or autoTs[base.id] or base.ts
        out[#out + 1] = { id = base.id, ts = ts, delay = math.floor((ts - base.ts) / 60) }
    end
    table.sort(out, function(a, b) return a.ts < b.ts end)
    return out
end

local function republishRace()
    sessions = effectiveSessions()
    if race ~= nil then
        race.sessions = sessions
        noctalia.state.set("race", race)
    end
end

-- ── Schedule ─────────────────────────────────────────────────────────────────

local function resetPerRaceData()
    generation += 1
    fixedTs, autoTs = {}, {}
    gridRound = nil
    busy.grid, busy.ofDrivers, busy.ofPos, busy.ofFlag = nil, nil, nil, nil
    noctalia.state.set("grid", { loaded = false, rows = {} })
    liveRows, liveFlag, liveLatest, liveError = {}, "", 0, nil
    driversMap = nil
    noctalia.state.set("live", { rows = {}, flag = "", latestSec = 0, error = "" })
end

local function loadSchedule()
    if busy.schedule then return end
    busy.schedule = true
    getJson(JOLPICA .. "current/next.json", function(data)
        busy.schedule = false
        due.schedule = shared.nowSec() + SCHEDULE_EVERY
        local races = path(data, "MRData", "RaceTable", "Races")
        local r = type(races) == "table" and races[1] or nil
        if type(r) ~= "table" then
            race, sessions, rawSessions = nil, {}, {}
            noctalia.state.set("race", false)
            setStatus(false, "no_race")
            return
        end
        local circuit = type(r.Circuit) == "table" and r.Circuit or {}
        local location = type(circuit.Location) == "table" and circuit.Location or {}
        rawSessions = shared.buildSessions(r)
        local newRace = {
            season = shared.safe(r.season, 8),
            round = shared.safe(r.round, 4),
            name = shared.safe(r.raceName, 48),
            circuitId = shared.safe(circuit.circuitId, 40),
            circuitName = shared.safe(circuit.circuitName, 48),
            locality = shared.safe(location.locality, 32),
            country = shared.safe(location.country, 32),
            url = tostring(r.url or ""),
            sessions = {},
        }
        local changed = race == nil or race.round ~= newRace.round or race.season ~= newRace.season
        race = newRace
        if changed then resetPerRaceData() end
        republishRace()
        setStatus(false, "")
    end, function(reason)
        busy.schedule = false
        due.schedule = shared.nowSec() + 120
        setStatus(false, reason)
    end)
end

-- ── Session times from F1's timing feed ──────────────────────────────────────

-- Feed session names -> our session ids.
local FEED_SESSIONS = {
    ["Practice 1"] = "fp1", ["Practice 2"] = "fp2", ["Practice 3"] = "fp3",
    ["Sprint Qualifying"] = "sprint_quali", ["Sprint Shootout"] = "sprint_quali",
    ["Sprint"] = "sprint", ["Qualifying"] = "quali", ["Race"] = "race",
}
local MAX_FEED_SHIFT = 12 * 3600          -- ignore a feed time further than this from the calendar
local SESSION_INFO_EVERY = 60             -- seconds, inside the weekend window
local sessionInfoAt = 0

local function loadSessionInfo()
    if busy.sessionInfo or race == nil then return end
    busy.sessionInfo = true
    getJson(shared.F1_TIMING .. "SessionInfo.json", function(info)
        busy.sessionInfo = false
        local meeting = type(info.Meeting) == "table" and info.Meeting or {}
        -- Only the weekend this plugin is showing: the feed carries one session
        -- at a time and keeps the last one between weekends.
        if tonumber(meeting.Number) ~= tonumber(race.round) then return end
        local id = FEED_SESSIONS[tostring(info.Name or "")]
        local ts = shared.parseLocal(info.StartDate, info.GmtOffset)
        if id == nil or ts == nil then return end
        for _, base in ipairs(rawSessions) do
            if base.id == id then
                if math.abs(ts - base.ts) > MAX_FEED_SHIFT then return end
                if autoTs[id] ~= ts then
                    autoTs[id] = ts
                    republishRace()
                end
                return
            end
        end
    end, function()
        busy.sessionInfo = false
    end)
end

-- ── Standings, results, grid ─────────────────────────────────────────────────

local function loadDrivers()
    if busy.drivers then return end
    busy.drivers = true
    getJson(JOLPICA .. "current/driverStandings.json", function(data)
        busy.drivers = false
        local lists = shared.bounded(path(data, "MRData", "StandingsTable", "StandingsLists"), 4)
        local entries = shared.bounded(lists[1] and lists[1].DriverStandings, 60)
        local leader = entries[1] and tonumber(entries[1].points) or 0
        local rows = {}
        for i, e in ipairs(entries) do
            local con = lastOf(e.Constructors)
            local pts = tonumber(e.points) or 0
            rows[#rows + 1] = {
                pos = shared.safe(e.position, 3),
                code = driverCode(e.Driver),
                team = con and shared.safe(con.name, 32) or "",
                teamId = con and shared.safe(con.constructorId, 32) or "",
                pts = shared.safe(e.points, 6),
                gap = i == 1 and 0 or (leader - pts),
                url = type(e.Driver) == "table" and tostring(e.Driver.url or "") or "",
            }
        end
        noctalia.state.set("drivers", { loaded = true, rows = shared.bounded(rows, 30) })
    end, function()
        busy.drivers = false
        noctalia.state.set("drivers", { loaded = true, rows = {} })
    end)
end

local function loadConstructors()
    if busy.constructors then return end
    busy.constructors = true
    getJson(JOLPICA .. "current/constructorStandings.json", function(data)
        busy.constructors = false
        local lists = shared.bounded(path(data, "MRData", "StandingsTable", "StandingsLists"), 4)
        local entries = shared.bounded(lists[1] and lists[1].ConstructorStandings, 60)
        local leader = entries[1] and tonumber(entries[1].points) or 0
        local rows = {}
        for i, e in ipairs(entries) do
            local c = type(e.Constructor) == "table" and e.Constructor or {}
            local pts = tonumber(e.points) or 0
            rows[#rows + 1] = {
                pos = shared.safe(e.position, 3),
                name = shared.safe(c.name, 32),
                teamId = shared.safe(c.constructorId, 32),
                pts = shared.safe(e.points, 6),
                gap = i == 1 and 0 or (leader - pts),
                url = tostring(c.url or ""),
            }
        end
        noctalia.state.set("constructors", { loaded = true, rows = shared.bounded(rows, 15) })
    end, function()
        busy.constructors = false
        noctalia.state.set("constructors", { loaded = true, rows = {} })
    end)
end

local function loadResults()
    if busy.results then return end
    busy.results = true
    getJson(JOLPICA .. "current/last/results.json", function(data)
        busy.results = false
        local races = shared.bounded(path(data, "MRData", "RaceTable", "Races"), 4)
        local r0 = races[1]
        local entries = shared.bounded(r0 and r0.Results, 60)
        local rows = {}
        for _, e in ipairs(entries) do
            local con = type(e.Constructor) == "table" and e.Constructor or {}
            local detail = (type(e.Time) == "table" and e.Time.time) or e.status or ""
            rows[#rows + 1] = {
                pos = shared.safe(e.positionText, 3),
                code = driverCode(e.Driver),
                team = shared.safe(con.name, 32),
                teamId = shared.safe(con.constructorId, 32),
                detail = shared.safe(detail, 24),
                pts = shared.safe(e.points, 6),
                url = type(e.Driver) == "table" and tostring(e.Driver.url or "") or "",
            }
        end
        noctalia.state.set("results", {
            loaded = true,
            raceName = r0 and shared.safe(r0.raceName, 48) or "",
            rows = shared.bounded(rows, 30),
        })
    end, function()
        busy.results = false
        noctalia.state.set("results", { loaded = true, raceName = "", rows = {} })
    end)
end

local function loadGrid()
    if busy.grid then return end
    busy.grid = true
    local url
    if forceTabs then
        url = JOLPICA .. "current/last/qualifying.json"
    else
        url = JOLPICA .. "current/" .. tostring(race and race.round or "") .. "/qualifying.json"
    end
    gridRound = race and race.round or nil
    gridDebug = forceTabs
    getJson(url, function(data)
        busy.grid = false
        local races = shared.bounded(path(data, "MRData", "RaceTable", "Races"), 4)
        local entries = shared.bounded(races[1] and races[1].QualifyingResults, 60)
        local rows = {}
        for _, q in ipairs(entries) do
            local con = type(q.Constructor) == "table" and q.Constructor or {}
            rows[#rows + 1] = {
                pos = shared.safe(q.position, 3),
                code = driverCode(q.Driver),
                team = shared.safe(con.name, 32),
                teamId = shared.safe(con.constructorId, 32),
                detail = shared.safe(q.Q3 or q.Q2 or q.Q1 or "", 16),
                url = type(q.Driver) == "table" and tostring(q.Driver.url or "") or "",
            }
        end
        noctalia.state.set("grid", { loaded = true, rows = shared.bounded(rows, 30) })
    end, function()
        busy.grid = false
        gridRound = nil
        noctalia.state.set("grid", { loaded = true, rows = {} })
    end, { scoped = true })
end

-- ── Live timing (OpenF1) ─────────────────────────────────────────────────────

-- OpenF1 serves real-time data (and, while a session runs, everything) only to
-- authenticated accounts. Credentials are optional and come from the
-- environment, never from this plugin's settings, so no password is written
-- into Noctalia's configuration:
--   OPENF1_USERNAME, OPENF1_PASSWORD   -> POST /token -> bearer token (1 hour)
local TOKEN_URL = "https://api.openf1.org/token"
local liveBackoffUntilMs = 0          -- after a refusal, poll slowly for a while

local function credentials()
    local user = noctalia.getenv("OPENF1_USERNAME")
    local pass = noctalia.getenv("OPENF1_PASSWORD")
    if user ~= nil and user ~= "" and pass ~= nil and pass ~= "" then return user, pass end
    return nil, nil
end

local liveSession, liveClock = nil, nil
local liveSourceName = "openf1"

local function publishLive()
    noctalia.state.set("live", {
        rows = liveRows,
        flag = liveFlag,
        latestSec = liveLatest,
        error = liveError or "",
        source = liveSourceName,
        session = liveSession or false,
        clock = liveClock or false,
    })
end

local function liveFailure(reason, status)
    -- 401/403: OpenF1 keeps real-time data behind an account during sessions.
    if status == 401 or status == 403 then
        liveError = (token ~= nil) and "token" or "auth"
        token = nil
        liveBackoffUntilMs = noctalia.nowMs() + 60000
    elseif status == 429 then
        liveError = "rate"
        liveBackoffUntilMs = noctalia.nowMs() + 60000
    else
        liveError = "net"
    end
    publishLive()
end

-- Run `fn` once a valid token is held (or straight away without credentials).
local function withToken(fn)
    local user, pass = credentials()
    if user == nil then
        token = nil
        fn()
        return
    end
    if token ~= nil and shared.nowSec() < tokenExpiresAt - 120 then
        fn()
        return
    end
    if busy.token then return end
    busy.token = true
    local body = "username=" .. noctalia.string.urlEncode(user) .. "&password=" .. noctalia.string.urlEncode(pass)
    local started = noctalia.http({
        url = TOKEN_URL,
        method = "POST",
        headers = { shared.USER_AGENT, "Content-Type: application/x-www-form-urlencoded", "Accept: application/json" },
        body = body,
    }, function(res)
        busy.token = false
        local decoded = (res.ok and res.status == 200 and #(res.body or "") < 4096)
            and noctalia.json.decode(res.body) or nil
        if type(decoded) == "table" and type(decoded.access_token) == "string" then
            token = decoded.access_token
            tokenExpiresAt = shared.nowSec() + (tonumber(decoded.expires_in) or 3600)
            fn()
        else
            token = nil
            liveError = "login"
            liveBackoffUntilMs = noctalia.nowMs() + 300000
            publishLive()
        end
    end)
    if not started then busy.token = false end
end

local function loadDriversMap()
    if busy.ofDrivers then return end
    busy.ofDrivers = true
    getJson(OPENF1 .. "drivers?session_key=latest", function(arr)
        busy.ofDrivers = false
        local map = {}
        for _, d in ipairs(shared.bounded(arr, 60)) do
            local key = tostring(d.driver_number == nil and "" or d.driver_number)
            if key:match("^%d%d?%d?$") then
                map[key] = {
                    acr = shared.safe(d.name_acronym or ("#" .. key), 8),
                    color = shared.hexColor(d.team_colour) or "",
                    team = shared.safe(d.team_name, 32),
                }
            end
        end
        driversMap = map
    end, function(reason, status)
        busy.ofDrivers = false
        liveFailure(reason, status)
    end, { scoped = true, auth = true })
end

local function loadPositions()
    if busy.ofPos then return end
    busy.ofPos = true
    getJson(OPENF1 .. "position?session_key=latest", function(arr)
        busy.ofPos = false
        -- Latest reading per driver. Keys are held to the shape a driver number
        -- really has, since both key and value come straight from the API.
        local latest = {}
        for _, r in ipairs(shared.bounded(arr, 20000)) do
            local n = tostring(r.driver_number == nil and "" or r.driver_number)
            local pos = tonumber(r.position)
            local date = type(r.date) == "string" and r.date or ""
            if n:match("^%d%d?%d?$") and pos ~= nil and pos >= 1 and pos <= 99 then
                local old = latest[n]
                if old == nil or date > old.date then latest[n] = { pos = pos, date = date } end
            end
        end
        local rows, newest = {}, 0
        for n, v in pairs(latest) do
            local ts = shared.parseIso(v.date) or 0
            if ts > newest then newest = ts end
            local info = driversMap and driversMap[n] or {}
            rows[#rows + 1] = {
                pos = v.pos,
                code = info.acr or ("#" .. n),
                color = info.color or "",
                team = info.team or "",
            }
        end
        table.sort(rows, function(a, b) return a.pos < b.pos end)
        liveRows, liveLatest, liveError = shared.bounded(rows, 30), newest, nil
        publishLive()
    end, function(reason, status)
        busy.ofPos = false
        liveFailure(reason, status)
    end, { scoped = true, auth = true })
end

local function loadFlag()
    if busy.ofFlag then return end
    busy.ofFlag = true
    getJson(OPENF1 .. "race_control?session_key=latest", function(arr)
        busy.ofFlag = false
        local last = ""
        for _, m in ipairs(shared.bounded(arr, 2000)) do
            if m.category == "Flag" and m.scope == "Track" and type(m.flag) == "string" and m.flag ~= "" then
                last = shared.safe(m.flag, 16)
            end
        end
        liveFlag = last
        publishLive()
    end, function()
        busy.ofFlag = false
    end, { scoped = true, auth = true })
end

local function pollLive()
    withToken(function()
        if driversMap == nil then loadDriversMap() end
        loadPositions()
        loadFlag()
    end)
end

-- ── Notification ─────────────────────────────────────────────────────────────

-- ── Experimental: F1's live-timing stream ───────────────────────────────────

-- Off by default (setting live_source). It reads the same stream F1's own live
-- timing page uses, through f1-live.sh (curl), because the server needs a
-- cookie that noctalia.http cannot read back. Needs no account, but the stream
-- is unofficial and undocumented.
local streamRunning = false
local streamRetryAtMs = 0
local feedDirty = false

local function useF1Feed()
    return noctalia.getConfig("live_source") == "f1_feed"
end

local function startF1Stream(now)
    if streamRunning or noctalia.nowMs() < streamRetryAtMs then return end
    local dir = noctalia.pluginDir()
    if dir == nil then return end
    if not noctalia.commandExists("curl") then
        liveError = "nocurl"
        publishLive()
        streamRetryAtMs = noctalia.nowMs() + 300000
        return
    end
    local untilTs = shared.windowEnd(sessions, now) or (now + 3600)
    local seconds = math.max(120, math.min(untilTs - now, 4 * 3600))
    -- The path comes from the host, not from the network; quoting keeps spaces safe.
    local quoted = "'" .. (dir:gsub("'", "'\\''")) .. "/f1-live.sh'"
    streamRunning = true
    local started = noctalia.runStream("sh " .. quoted .. " " .. tostring(math.floor(seconds)), function(line)
        if line == "closed" then
            streamRunning = false
            streamRetryAtMs = noctalia.nowMs() + 15000
            return
        end
        if f1feed.handleLine(line) then feedDirty = true end
    end)
    if not started then
        streamRunning = false
        streamRetryAtMs = noctalia.nowMs() + 60000
        liveError = "net"
        publishLive()
    end
end

local function runF1Feed(now)
    liveSourceName = "f1_feed"
    startF1Stream(now)
    if not feedDirty then return end
    feedDirty = false
    local view = f1feed.view(now)
    if view == nil then return end
    liveRows, liveFlag, liveLatest, liveError = view.rows, view.flag, view.latestSec, nil
    liveSession, liveClock = view.session, view.clock
    publishLive()
end

local function checkNotify(now)
    if noctalia.getConfig("notify_race") ~= true or race == nil then return end
    local raceTs = shared.sessionTs(sessions, "race")
    if raceTs == nil then return end
    local round = tonumber(race.round) or -1
    if noctalia.state.get("notified_round") == round then return end
    local lead = (tonumber(noctalia.getConfig("notify_lead_min")) or 10) * 60
    if now >= raceTs - lead and now < raceTs + 300 then
        noctalia.state.set("notified_round", round)
        noctalia.notify(race.name, noctalia.tr("notify.lights_out", { time = shared.fmtLong(raceTs - now) }))
    end
end

-- ── Scheduler ────────────────────────────────────────────────────────────────

local function refreshAll()
    local now = shared.nowSec()
    due.schedule, due.standings, due.results = now, now, now
    gridRound = nil
end

function update()
    local now = shared.nowSec()

    if now >= due.schedule then loadSchedule() end
    if now >= due.standings then
        due.standings = now + STANDINGS_EVERY
        loadDrivers()
        loadConstructors()
    end
    if now >= due.results then
        due.results = now + STANDINGS_EVERY
        loadResults()
    end

    -- Right after a race ends the standings and the result change, and the
    -- schedule moves on to the next round: refresh both once per round.
    local raceTs = shared.sessionTs(sessions, "race")
    if raceTs ~= nil and race ~= nil and now > raceTs + 3 * 3600 + 900 and postRaceRound ~= race.round then
        postRaceRound = race.round
        due.schedule, due.standings, due.results = now, now, now
    end

    -- F1's timing feed: follow delays from a few hours before the first session
    -- until a few hours after the race, once a minute.
    if race ~= nil and #rawSessions > 0 and now - sessionInfoAt >= SESSION_INFO_EVERY then
        local first, last = rawSessions[1].ts, rawSessions[#rawSessions].ts
        for _, base in ipairs(rawSessions) do
            if base.ts < first then first = base.ts end
            if base.ts > last then last = base.ts end
        end
        if now >= first - 3 * 3600 and now <= last + 4 * 3600 then
            sessionInfoAt = now
            loadSessionInfo()
        end
    end

    -- Starting grid: needed once qualifying is over, or always in debug mode.
    if race ~= nil and (forceTabs or shared.gridApplicable(sessions, now)) then
        if gridRound ~= race.round or gridDebug ~= forceTabs then loadGrid() end
    end

    -- Live timing: only near a session.
    if shared.nearSession(sessions, now) or forceTabs then
        if useF1Feed() then
            runF1Feed(now)
        else
            liveSourceName, liveSession, liveClock = "openf1", nil, nil
            local ms = noctalia.nowMs()
            if ms - lastLiveMs >= LIVE_EVERY_MS and ms >= liveBackoffUntilMs then
                lastLiveMs = ms
                pollLive()
            end
        end
    elseif #liveRows > 0 or liveLatest ~= 0 or liveError ~= nil then
        liveRows, liveFlag, liveLatest, liveError, driversMap = {}, "", 0, nil, nil
        liveSession, liveClock = nil, nil
        f1feed.reset()
        publishLive()
    end

    checkNotify(now)
end

local lastSourceF1 = false

function onConfigChanged()
    if useF1Feed() ~= lastSourceF1 then
        lastSourceF1 = useF1Feed()
        liveRows, liveFlag, liveLatest, liveError, driversMap = {}, "", 0, nil, nil
        liveSession, liveClock = nil, nil
        f1feed.reset()
        feedDirty = false
        lastLiveMs = 0
        publishLive()
    end
    local nowForced = noctalia.getConfig("debug_force_tabs") == true
    if nowForced ~= forceTabs then
        forceTabs = nowForced
        generation += 1
        busy = {}
        gridRound = nil
        liveRows, liveFlag, liveLatest, liveError, driversMap = {}, "", 0, nil, nil
        publishLive()
        lastLiveMs = 0
    end
end

function onIpc(event, payload)
    if event == "delay" and type(payload) == "string" then
        -- delay <session> <minutes>, e.g. "delay quali 30"; 0 undoes one session.
        local id, minutes = payload:match("^(%l[%l%d_]*)%s+([+-]?%d+)$")
        minutes = tonumber(minutes)
        if id == nil or KNOWN_SESSIONS[id] ~= true or minutes == nil or minutes < -720 or minutes > 720 then
            noctalia.log("f1: usage: delay <fp1|fp2|fp3|sprint_quali|sprint|quali|race> <minutes -720..720>")
            return
        end
        for _, base in ipairs(rawSessions) do
            if base.id == id then
                fixedTs[id] = minutes ~= 0 and (base.ts + minutes * 60) or nil
                republishRace()
                return
            end
        end
        noctalia.log("f1: no session '" .. id .. "' this weekend")
        return
    end
    if event == "delay_clear" then
        fixedTs = {}
        sessionInfoAt = 0
        republishRace()
        return
    end
    if event == "refresh" then
        local ms = noctalia.nowMs()
        if ms - lastRefreshMs < MIN_REFRESH_GAP_MS then return end
        lastRefreshMs = ms
        refreshAll()
    end
end

-- The panel asks for a refresh through shared state (key "r" in the panel).
noctalia.state.watch("command", function(value)
    if type(value) == "table" and value.action == "refresh" then onIpc("refresh") end
end)

noctalia.setUpdateInterval(1000)
noctalia.state.set("drivers", noctalia.state.get("drivers") or { loaded = false, rows = {} })
noctalia.state.set("constructors", noctalia.state.get("constructors") or { loaded = false, rows = {} })
noctalia.state.set("results", noctalia.state.get("results") or { loaded = false, raceName = "", rows = {} })
noctalia.state.set("grid", noctalia.state.get("grid") or { loaded = false, rows = {} })
noctalia.state.set("live", noctalia.state.get("live") or { rows = {}, flag = "", latestSec = 0, error = "" })
setStatus(true, "")
