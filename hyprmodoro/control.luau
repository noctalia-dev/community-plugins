local util = require("./lib/util.luau")
local hypr = require("./lib/hypr.luau")

local T = hypr.TRANSPORT

local pollRunning = 1000
local pollIdle = 5000
local state = "STOPPED"
local paused = false
local busy = false

local lastTime = nil
local stillTicks = 0
local STILL_THRESHOLD = 2

local absentTicks = 0

local PHASE = {
  STOPPED = "IDLE",
  FINISHED = "IDLE",
  WORKING = "WORK",
  RESTING = "REST",
  WAITING_FOR_REST = "WAITING",
  WAITING_FOR_WORK = "WAITING",
}

local function isLive(s) return s == "WORKING" or s == "RESTING" end
local function isWaiting(s) return s == "WAITING_FOR_REST" or s == "WAITING_FOR_WORK" end
local function isIdle(s) return s == "STOPPED" or s == "FINISHED" end

local durations = { work = 25, rest = 5 }

local function seedDurations()
  durations.work = util.clamp(util.round(noctalia.getConfig("work_duration") or 25), 1, 180)
  durations.rest = util.clamp(util.round(noctalia.getConfig("rest_duration") or 5), 1, 60)
end

local function publishDurations()
  noctalia.state.set("hm.work", durations.work)
  noctalia.state.set("hm.rest", durations.rest)
end

local function inferDuration(reading)
  if not isLive(reading.state) then return end
  local progress = tonumber(reading.progress) or 0
  if progress < 0.05 or progress > 0.97 then return end
  local remaining = util.parseClock(reading.time)
  if remaining == nil or remaining <= 0 then return end

  local minutes = util.clamp(util.round((remaining / progress) / 60), 1, 180)
  local key = reading.state == "WORKING" and "work" or "rest"
  if durations[key] ~= minutes then
    durations[key] = minutes
    publishDurations()
  end
end

local function plan(cmd, arg)
  local live, waiting, idle = isLive(state), isWaiting(state), isIdle(state)

  if cmd == "START" then
    if idle then return { { "start" } } end
    if waiting then return { { "skip" } } end
    if live and paused then return { { "pause" } } end
    return {}

  elseif cmd == "PAUSE" then
    return live and { { "pause" } } or {}

  elseif cmd == "STOP" then
    return { { "stop" } }

  elseif cmd == "RESET" then
    if idle then return { { "start" } } end
    return { { "stop" }, { "start" } }

  elseif cmd == "SKIP" then
    return (live or waiting) and { { "skip" } } or {}

  elseif cmd == "TO_REST" then
    if state == "WORKING" or state == "WAITING_FOR_REST" then return { { "skip" } } end
    if idle then return { { "start" }, { "skip" } } end
    return {}

  elseif cmd == "TO_WORK" then
    if state == "RESTING" or state == "WAITING_FOR_WORK" then return { { "skip" } } end
    if idle then return { { "start" } } end
    return {}

  elseif cmd == "SET_WORK" then
    if tonumber(arg) == nil then return {} end
    local n = util.clamp(util.round(arg), 1, 180)
    durations.work = n
    if idle then return { { "set", n } } end
    return { { "stop" }, { "set", n }, { "start" } }

  elseif cmd == "SET_REST" then
    if tonumber(arg) == nil then return {} end
    local n = util.clamp(util.round(arg), 1, 60)
    durations.rest = n
    return { { "setRest", n } }

  elseif cmd == "PRESET" then
    local w, r = tostring(arg):match("^(%d+)/(%d+)$")
    w, r = tonumber(w), tonumber(r)
    if w == nil or r == nil then return {} end
    durations.work = util.clamp(util.round(w), 1, 180)
    durations.rest = util.clamp(util.round(r), 1, 60)
    if idle then
      return { { "set", durations.work }, { "setRest", durations.rest } }
    end
    return {
      { "stop" },
      { "set", durations.work },
      { "setRest", durations.rest },
      { "start" },
    }
  end

  return nil
end

local function publishTransport(t)
  noctalia.state.set("hm.transport", t)
  noctalia.state.set("hm.config_type", hypr.configType)
  noctalia.state.set("hm.controllable", hypr.canControl())
end

local function applyPollRate()
  local live = isLive(state) and not paused
  noctalia.setUpdateInterval(live and pollRunning or pollIdle)
end

local function publish(reading)
  if reading == nil then
    if hypr.transport == T.ABSENT then
      noctalia.state.set("hm.state", "STOPPED")
      noctalia.state.set("hm.phase", "IDLE")
      noctalia.state.set("hm.time", "--:--")
      noctalia.state.set("hm.progress", 0)
    end
    return
  end

  local previous = state
  state = reading.state

  if reading.paused ~= nil then
    paused = reading.paused
    stillTicks = 0
  elseif isLive(state) then
    if reading.time == lastTime and state == previous then
      stillTicks = stillTicks + 1
    else
      stillTicks = 0
    end
    paused = stillTicks >= STILL_THRESHOLD
  else
    stillTicks = 0
    paused = false
  end
  lastTime = reading.time

  noctalia.state.set("hm.state", state)
  noctalia.state.set("hm.phase", PHASE[state] or "IDLE")
  noctalia.state.set("hm.paused", paused)
  noctalia.state.set("hm.time", reading.time)
  noctalia.state.set("hm.progress", reading.progress)

  if not paused then inferDuration(reading) end

  if hypr.hasGetRound and state ~= previous then
    hypr.readRound(function(round)
      if round ~= nil then noctalia.state.set("hm.round", round) end
    end)
  end
end

local function poll()
  hypr.read(function(reading)
    publish(reading)
    applyPollRate()
  end)
end

local function fail(message)
  noctalia.state.set("hm.error", message or "")
  if message ~= nil and message ~= "" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("err.action_failed", { message = message }))
  end
end

local function handle(raw)
  if type(raw) ~= "string" or raw == "" then return end

  local cmd, arg = raw:match("^([A-Z_]+):(.*)$")
  if cmd == nil then cmd = raw end

  if cmd == "PROBE" then
    hypr.probe(function(t)
      publishTransport(t)
      poll()
    end)
    return
  end

  if hypr.transport == T.ABSENT then
    fail(noctalia.tr("err.absent_body"))
    return
  end
  if not hypr.canControl() then
    noctalia.notifyError(noctalia.tr("err.readonly_title"), noctalia.tr("err.readonly_body"))
    return
  end
  if busy then return end

  local steps = plan(cmd, arg)
  if steps == nil then
    noctalia.log("hyprmodoro: unknown command " .. raw)
    return
  end

  publishDurations()

  if #steps == 0 then
    poll()
    return
  end

  busy = true
  hypr.sequence(steps, function(ok, message)
    busy = false
    if ok then
      noctalia.state.set("hm.error", "")

      stillTicks = 0
      lastTime = nil
      poll()
    else
      fail(message)
      poll()
    end
  end)
end

noctalia.state.watch("hm.cmd", function(cmd)
  if type(cmd) ~= "string" or cmd == "" then return end

  noctalia.state.set("hm.cmd", "")
  handle(cmd)
end)

local function readIntervals()
  pollRunning = util.clamp(util.round(noctalia.getConfig("poll_interval_running") or 1000), 250, 5000)
  pollIdle = util.clamp(util.round(noctalia.getConfig("poll_interval_idle") or 5000), 1000, 30000)
end

function update()
  if hypr.transport == T.ABSENT or hypr.transport == T.UNKNOWN then
    absentTicks = absentTicks + 1
    if absentTicks >= 6 then
      absentTicks = 0
      hypr.probe(function(t)
        publishTransport(t)
        if t ~= T.ABSENT then poll() end
      end)
    end
    return
  end
  absentTicks = 0
  poll()
end

function onConfigChanged()
  readIntervals()
  applyPollRate()

  if isIdle(state) then
    seedDurations()
    publishDurations()
  end
end

function onIpc(event, payload)
  local verb = tostring(event or ""):upper():gsub("-", "_")
  local arg = util.trim(payload or "")
  if arg ~= "" then verb = verb .. ":" .. arg end
  handle(verb)
end

function onExit(_signal, _reason)
end

readIntervals()
noctalia.setUpdateInterval(pollIdle)
noctalia.state.set("hm.error", "")
noctalia.state.set("hm.round", 0)
seedDurations()
publishDurations()

hypr.probe(function(t)
  publishTransport(t)
  if t == T.ABSENT then
    noctalia.state.set("hm.state", "STOPPED")
    noctalia.state.set("hm.phase", "IDLE")
    noctalia.state.set("hm.time", "--:--")
    noctalia.state.set("hm.progress", 0)
    return
  end
  if t == T.READONLY then
    noctalia.notifyError(noctalia.tr("err.readonly_title"), noctalia.tr("err.readonly_body"))
  end
  poll()
end)
