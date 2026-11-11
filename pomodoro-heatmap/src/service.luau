--!nonstrict
-- Pomodoro Heatmap - timer engine, preferences, persistence and analytics.
--
-- The timer is anchored on wall-clock deadlines (endsAt), not on tick counts,
-- so it stays correct across suspend, lag spikes and shell restarts.
--
-- Shared state (noctalia.state):
--   pomo.timer   snapshot for the bar widget and panel (published each second)
--   pomo.config  effective preferences (published on change)
--   pomo.stats   analytics (published on change and at midnight)
--   pomo.cmd     { cmd = "...", arg = ..., n = nonce } commands from widget/panel

local Stats = require("./src/stats.luau")

local DATA_DIR = noctalia.pluginDataDir()
local HISTORY_PATH = DATA_DIR .. "/history.json"
local STATE_PATH = DATA_DIR .. "/state.json"
local PREFS_PATH = DATA_DIR .. "/prefs.json"
local MIN_LOGGED_SEC = 60
local SOUND_DIR = noctalia.pluginDir() .. "/resources/sounds/"
local SYSTEM_SOUND_DIR = "/usr/share/sounds/freedesktop/stereo/"

noctalia.mkdirAll(DATA_DIR)

-- ------------------------------------------------------------------ persistence

local function readJson(path)
    if not noctalia.fileExists(path) then return nil end
    local raw = noctalia.readFile(path)
    if not raw or raw == "" then return nil end
    local ok, data = pcall(noctalia.json.decode, raw)
    return ok and type(data) == "table" and data or nil
end

local function writeJson(path, data)
    local tmp = path .. ".tmp"
    noctalia.writeFile(tmp, noctalia.json.encode(data))
    noctalia.renameFile(tmp, path)
end

-- ------------------------------------------------------------------ preferences
--
-- Values come from Noctalia's plugin settings, but the panel can override them
-- (plugins can't write their own settings). Whichever was changed last wins:
-- editing a setting in Noctalia's settings drops the panel override for it.

local SCHEMA = {
    ["work-minutes"] = { kind = "int", default = 25, min = 1, max = 180 },
    ["short-break-minutes"] = { kind = "int", default = 5, min = 1, max = 60 },
    ["long-break-minutes"] = { kind = "int", default = 15, min = 1, max = 120 },
    ["rounds"] = { kind = "int", default = 4, min = 1, max = 12 },
    ["breaks-enabled"] = { kind = "bool", default = true },
    ["auto-start-breaks"] = { kind = "bool", default = true },
    ["auto-start-work"] = { kind = "bool", default = false },
    ["daily-goal-minutes"] = { kind = "int", default = 120, min = 0, max = 960 },
    ["log-partial"] = { kind = "bool", default = true },
    ["notify"] = { kind = "bool", default = true },
    ["focus-end-sound"] = { kind = "string", default = "soft-chime" },
    ["break-end-sound"] = { kind = "string", default = "wood" },
    ["sound-volume"] = { kind = "int", default = 60, min = 0, max = 100 },
    ["custom-sound-file"] = { kind = "string", default = "" },
}

local prefs = readJson(PREFS_PATH) or {}
local seenConfig = {}

local function coerce(spec, v)
    if v == nil then return nil end
    if spec.kind == "int" then
        v = tonumber(v)
        if not v then return nil end
        return math.clamp(math.floor(v), spec.min, spec.max)
    elseif spec.kind == "bool" then
        if type(v) == "boolean" then return v end
        if v == "true" then return true end
        if v == "false" then return false end
        return nil
    end
    return tostring(v)
end

local function value(key)
    local spec = SCHEMA[key]
    local v = coerce(spec, prefs[key])
    if v == nil then v = coerce(spec, noctalia.getConfig(key)) end
    if v == nil then v = spec.default end
    return v
end

local cfg = {}
local function loadConfig()
    cfg = {
        work = value("work-minutes") * 60,
        short = value("short-break-minutes") * 60,
        long = value("long-break-minutes") * 60,
        rounds = value("rounds"),
        breaks = value("breaks-enabled"),
        autoBreaks = value("auto-start-breaks"),
        autoWork = value("auto-start-work"),
        goal = value("daily-goal-minutes"),
        logPartial = value("log-partial"),
        notify = value("notify"),
        focusSound = value("focus-end-sound"),
        breakSound = value("break-end-sound"),
        volume = value("sound-volume"),
        customSound = noctalia.expandPath(value("custom-sound-file")),
    }
end

for key in pairs(SCHEMA) do seenConfig[key] = noctalia.getConfig(key) end
loadConfig()

local function phaseLength(phase)
    return (cfg[phase] or cfg.work) * 1000
end

local function publishConfig()
    noctalia.state.set("pomo.config", {
        work = cfg.work / 60,
        short = cfg.short / 60,
        long = cfg.long / 60,
        rounds = cfg.rounds,
        breaks = cfg.breaks,
        autoBreaks = cfg.autoBreaks,
        autoWork = cfg.autoWork,
        goal = cfg.goal,
        notify = cfg.notify,
        focusSound = cfg.focusSound,
        breakSound = cfg.breakSound,
        volume = cfg.volume,
    })
end

-- ------------------------------------------------------------------ history

local history = readJson(HISTORY_PATH)
if not history or type(history.sessions) ~= "table" then
    history = { version = 1, sessions = {} }
end

-- ------------------------------------------------------------------ timer state

-- phase: "work" | "short" | "long";  status: "idle" | "running" | "paused"
local T = {
    phase = "work",
    status = "idle",
    endsAt = nil,        -- ms, while running
    remainingMs = phaseLength("work"),
    totalMs = phaseLength("work"),
    round = 1,           -- which focus session of the cycle (1..rounds)
    startedAt = nil,     -- sec, first start of the current phase
}

local saved = readJson(STATE_PATH)
if saved and saved.phase and saved.status then
    for k, v in pairs(saved) do T[k] = v end
    if T.round > cfg.rounds then T.round = 1 end
end

local function saveState()
    writeJson(STATE_PATH, {
        phase = T.phase, status = T.status, endsAt = T.endsAt,
        remainingMs = T.remainingMs, totalMs = T.totalMs,
        round = T.round, startedAt = T.startedAt,
    })
end

local function remainingNow()
    if T.status == "running" and T.endsAt then
        return math.max(0, T.endsAt - noctalia.nowMs())
    end
    return T.remainingMs
end

local function elapsedSec()
    return math.floor((T.totalMs - remainingNow()) / 1000 + 0.5)
end

-- ------------------------------------------------------------------ publishing

local currentStats = nil
local statsDay = Stats.dayKey(os.time())

local function publishStats()
    currentStats = Stats.compute(history.sessions, os.time(), cfg.goal)
    statsDay = Stats.dayKey(os.time())
    noctalia.state.set("pomo.stats", currentStats)
end

local lastPublishedSec = -1
local function publishTimer(force)
    local rem = remainingNow()
    local sec = math.ceil(rem / 1000)
    if not force and sec == lastPublishedSec then return end
    lastPublishedSec = sec
    noctalia.state.set("pomo.timer", {
        phase = T.phase,
        status = T.status,
        remaining = sec,
        total = math.floor(T.totalMs / 1000),
        defaultTotal = math.floor(phaseLength(T.phase) / 1000),
        round = T.round,
        rounds = cfg.rounds,
        breaks = cfg.breaks,
        todayMin = currentStats and currentStats.today.min or 0,
        todayCount = currentStats and currentStats.today.count or 0,
        goal = cfg.goal,
        streak = currentStats and currentStats.streak or 0,
    })
end

-- ------------------------------------------------------------------ logging

-- mode: "complete" (ran to the end), "early" (user finished it), "partial" (skipped/stopped)
local function logFocus(mode)
    if T.phase ~= "work" or not T.startedAt then return end
    local focused = mode == "complete" and math.floor(T.totalMs / 1000) or elapsedSec()
    if focused < MIN_LOGGED_SEC then return end
    if mode == "partial" and not cfg.logPartial then return end
    table.insert(history.sessions, {
        s = T.startedAt,
        e = os.time(),
        d = focused,
        p = math.floor(T.totalMs / 1000),
        c = mode ~= "partial",
    })
    writeJson(HISTORY_PATH, history)
    publishStats()
end

-- ------------------------------------------------------------------ sounds & alerts

local function soundPath(id)
    if id == "soft-chime" or id == "gentle-bell" or id == "wood" then
        return SOUND_DIR .. id .. ".wav"
    elseif id == "system-bell" then
        return SYSTEM_SOUND_DIR .. "bell.oga"
    elseif id == "system-message" then
        return SYSTEM_SOUND_DIR .. "message.oga"
    elseif id == "system-complete" then
        return SYSTEM_SOUND_DIR .. "complete.oga"
    elseif id == "custom" then
        return cfg.customSound
    end
    return nil
end

local function playSound(id)
    local path = soundPath(id)
    if not path or path == "" or cfg.volume <= 0 or not noctalia.fileExists(path) then return end
    noctalia.runAsync({ "pw-play", string.format("--volume=%.2f", cfg.volume / 100), path })
end

local MESSAGES = {
    work = { "Focus session complete", "Nice work, time for a break." },
    short = { "Break over", "Ready for the next focus session?" },
    long = { "Long break over", "Cycle complete. Ready for a fresh one?" },
}

local function alert(finishedPhase)
    local msg = MESSAGES[finishedPhase]
    if cfg.notify and msg then
        local body = msg[2]
        if finishedPhase == "work" then
            if not cfg.breaks then body = "Nice work. On to the next one." end
            if currentStats then
                body = string.format("%s  Today: %d min · %d sessions", body, currentStats.today.min, currentStats.today.count)
            end
        end
        noctalia.notify("Pomodoro · " .. msg[1], body)
    end
    playSound(finishedPhase == "work" and cfg.focusSound or cfg.breakSound)
end

-- ------------------------------------------------------------------ transitions

local function enterPhase(phase, autostart)
    T.phase = phase
    T.totalMs = phaseLength(phase)
    T.remainingMs = T.totalMs
    T.startedAt = nil
    T.endsAt = nil
    T.status = "idle"
    if autostart then
        T.status = "running"
        T.startedAt = os.time()
        T.endsAt = noctalia.nowMs() + T.totalMs
    end
end

local function advance(auto)
    local nxt
    if T.phase == "work" then
        if cfg.breaks then
            nxt = T.round >= cfg.rounds and "long" or "short"
        else
            nxt = "work"
            T.round = (T.round % cfg.rounds) + 1
        end
    else
        T.round = T.phase == "long" and 1 or (T.round % cfg.rounds) + 1
        nxt = "work"
    end
    local start = auto and ((nxt == "work" and cfg.autoWork) or (nxt ~= "work" and cfg.autoBreaks))
    enterPhase(nxt, start)
end

local actions = {}

function actions.start(minutes) -- optional length, applied if the stage hasn't started yet
    if T.status == "running" then return end
    if minutes ~= nil then actions.length(minutes) end
    if not T.startedAt then T.startedAt = os.time() end
    T.endsAt = noctalia.nowMs() + T.remainingMs
    T.status = "running"
end

function actions.pause()
    if T.status ~= "running" then return end
    T.remainingMs = remainingNow()
    T.endsAt = nil
    T.status = "paused"
end

function actions.toggle()
    if T.status == "running" then actions.pause() else actions.start() end
end

function actions.skip() -- move on without counting the session as done
    logFocus("partial")
    advance(false)
end

function actions.finish() -- end now and count it as done (focus) / end the break
    if T.phase == "work" and T.startedAt then
        logFocus("early")
        advance(true)
    else
        advance(false)
    end
end

function actions.reset() -- restart the current stage
    logFocus("partial")
    enterPhase(T.phase, false)
end

function actions.stop() -- stop and go back to the start of a cycle
    logFocus("partial")
    T.round = 1
    enterPhase("work", false)
end

function actions.focus() -- jump straight into a focus session now
    if T.phase ~= "work" then enterPhase("work", false) end
    actions.start()
end

function actions.adjust(deltaSec) -- +/- on the clock, any state
    local newRem = math.max(60 * 1000, remainingNow() + deltaSec * 1000)
    T.totalMs = math.max(T.totalMs + deltaSec * 1000, newRem)
    if T.status == "running" then
        T.endsAt = noctalia.nowMs() + newRem
    else
        T.remainingMs = newRem
    end
end

function actions.length(minutes) -- set this stage's length before it starts
    minutes = tonumber(minutes)
    if not minutes or T.status ~= "idle" then return end
    T.totalMs = math.clamp(math.floor(minutes), 1, 600) * 60 * 1000
    T.remainingMs = T.totalMs
end

function actions.pref(arg) -- { key = "...", value = ... } from the panel
    if type(arg) ~= "table" or not SCHEMA[arg.key] then return end
    local v = coerce(SCHEMA[arg.key], arg.value)
    if v == nil then return end
    local wasDefault = T.status == "idle" and T.totalMs == phaseLength(T.phase)
    prefs[arg.key] = v
    writeJson(PREFS_PATH, prefs)
    loadConfig()
    if wasDefault then -- an untouched idle stage follows its new default length
        T.totalMs = phaseLength(T.phase)
        T.remainingMs = T.totalMs
    end
    if T.round > cfg.rounds then T.round = 1 end
    publishConfig()
    publishStats()
end

function actions.preview(id)
    playSound(id)
end

-- Battery: only wake when something visible can change. While running, tick right
-- after the displayed second flips; otherwise sleep until local midnight (capped at an
-- hour, so a suspend or clock change is noticed soon enough).
local currentInterval = 0
local function schedule()
    local ms
    if T.status == "running" and T.endsAt then
        local rem = math.max(0, T.endsAt - noctalia.nowMs())
        ms = rem % 1000 + 20
    else
        local t = os.date("*t")
        local untilMidnight = ((23 - t.hour) * 3600 + (59 - t.min) * 60 + (60 - t.sec)) * 1000
        ms = math.min(untilMidnight + 1000, 3600000)
    end
    ms = math.max(50, math.floor(ms))
    if ms ~= currentInterval then
        currentInterval = ms
        noctalia.setUpdateInterval(ms)
    end
end

local ALIASES = {
    plus = function() actions.adjust(60) end,
    minus = function() actions.adjust(-60) end,
    ["skip-break"] = function() if T.phase ~= "work" then actions.skip() end end,
    ["refresh-stats"] = function() publishStats() end,
}

local function run(cmd, arg)
    local fn = ALIASES[cmd]
    if fn then
        fn()
    elseif actions[cmd] and cmd ~= "adjust" then
        actions[cmd](arg)
    else
        noctalia.log("pomodoro-heatmap: unknown command " .. tostring(cmd))
        return
    end
    saveState()
    publishTimer(true)
    schedule()
end

-- ------------------------------------------------------------------ wiring

noctalia.state.watch("pomo.cmd", function(msg)
    if type(msg) == "table" and msg.cmd then run(msg.cmd, msg.arg) end
end)

-- noctalia msg plugin adam-gassem/pomodoro-heatmap:engine all <event> [payload]
function onIpc(event, payload)
    if event == "length" then
        run("length", payload)
    elseif event == "set" then -- payload "key=value", e.g. "work-minutes=50"
        local key, v = tostring(payload or ""):match("^%s*([%w%-]+)%s*=%s*(.-)%s*$")
        if key then run("pref", { key = key, value = v }) end
    else
        run(event)
    end
end

function onConfigChanged()
    -- A setting edited in Noctalia's settings beats an older panel override.
    local dropped = false
    for key in pairs(SCHEMA) do
        local now = noctalia.getConfig(key)
        if now ~= seenConfig[key] then
            seenConfig[key] = now
            if prefs[key] ~= nil then
                prefs[key] = nil
                dropped = true
            end
        end
    end
    if dropped then writeJson(PREFS_PATH, prefs) end
    local wasDefault = T.status == "idle" and T.totalMs == phaseLength(T.phase)
    loadConfig()
    if wasDefault then
        T.totalMs = phaseLength(T.phase)
        T.remainingMs = T.totalMs
    end
    if T.round > cfg.rounds then T.round = 1 end
    saveState()
    publishConfig()
    publishStats()
    publishTimer(true)
    schedule()
end

function update()
    if T.status == "running" and remainingNow() <= 0 then
        local finished = T.phase
        T.remainingMs = 0
        logFocus("complete")
        alert(finished)
        advance(true)
        saveState()
        publishTimer(true)
    else
        publishTimer(false)
    end
    -- Midnight rollover: today's numbers and the heatmap move on.
    if Stats.dayKey(os.time()) ~= statsDay then
        publishStats()
        publishTimer(true)
    end
    schedule()
end

publishConfig()
publishStats()
publishTimer(true)
schedule()
