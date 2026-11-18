--!nonstrict
-- Background service: polls the UPS through pwrstat or NUT, feeds the tracker,
-- runs panel actions, and publishes everything through noctalia.state for the
-- desktop widget, bar item and panel. Parsing lives in source_*.luau,
-- change-tracking in tracker.luau, display rules in shared.luau.

local shared = require("./shared.luau")
local pwrstat = require("./source_pwrstat.luau")
local nut = require("./source_nut.luau")
local tracker = require("./tracker.luau")

local KEYS = shared.KEYS
local MAX_EVENTS = 200
local LOST_AFTER_FAILURES = 3
local RETRY_SEC = 30 -- how often to look for a UPS again while none is found
local POLICY_REFRESH_SEC = 600
local COMMAND_TIMEOUT_MS = 4000
local PWRSTAT_PATHS = { "/usr/bin/pwrstat", "/usr/sbin/pwrstat", "/usr/local/bin/pwrstat" }

-- Stat key -> snapshot field, for the graph history
local STAT_FIELDS = {}
for key, stat in shared.STATS do
  STAT_FIELDS[key] = stat.field
end

-- Stand-in UPS so simulations also work on a machine without one.
local DEMO = {
  source = "demo",
  model = "Simulated UPS",
  status = "normal",
  supply = "utility",
  onBattery = false,
  ratingVoltage = 120,
  ratingPowerW = 1000,
  ratingPowerVA = 1500,
  inputV = 120,
  outputV = 120,
  batteryPct = 100,
  runtimeSec = 2700,
  loadPct = 18,
  loadW = 180,
  line = "none",
}

-- Fields each simulation overrides; "lost" and "no_ups" replace the link instead.
local SIMULATIONS = {
  on_battery = { status = "on_battery", supply = "battery", onBattery = true, inputV = 0, batteryPct = 87, runtimeSec = 2280 },
  low_battery = {
    status = "low_battery",
    supply = "battery",
    onBattery = true,
    lowBattery = true,
    inputV = 0,
    batteryPct = 9,
    runtimeSec = 240,
  },
  overload = { overload = true, loadPct = 104, loadW = 1040 },
  lost = true,
  no_ups = true,
}

-- Settings

local config

local function readConfig()
  config = {
    source = noctalia.getConfig("data_source") or "auto",
    nutUps = noctalia.string.trim(noctalia.getConfig("nut_ups") or ""),
    pollSec = tonumber(noctalia.getConfig("poll_interval")) or 1,
    log = {
      outages = noctalia.getConfig("log_outages") == true,
      communication = noctalia.getConfig("log_communication") == true,
      self_test = noctalia.getConfig("log_self_test") == true,
      voltage = noctalia.getConfig("log_voltage") == true,
      line_events = noctalia.getConfig("log_line_events") == true,
    },
  }
end

-- Saved data

local dataDir = noctalia.pluginDataDir()

local function dataPath(name: string): string?
  return if dataDir then `{dataDir}/{name}` else nil
end

local function loadJson(name: string)
  local path = dataPath(name)
  if path == nil or not noctalia.fileExists(path) then
    return nil
  end
  local text = noctalia.readFile(path)
  local value = text and noctalia.json.decode(text)
  return if type(value) == "table" then value else nil
end

-- Written to a temporary file first, so a crash never leaves half a file.
local function saveText(name: string, text: string)
  local path = dataPath(name)
  if path == nil then
    return
  end
  local ok, err = noctalia.writeFile(path .. ".tmp", text)
  if ok then
    ok, err = noctalia.renameFile(path .. ".tmp", path)
  end
  if not ok then
    noctalia.log(`cutemonitor-ups: could not save {name}: {err}`)
  end
end

-- Runtime state

local events = loadJson("events.json") or {}
local trackState = tracker.newState(loadJson("state.json"))
local savedStateText = noctalia.json.encode(tracker.saved(trackState))
local history = tracker.newHistory()
local active = nil -- { kind = "pwrstat" } or { kind = "nut", ups = "name@host" }
local link = { state = "starting" }
local lastGood = nil
local failures = 0
local polling = false
local resolving = false
local resolveGen = 0 -- lets a running search notice it has been superseded
local nextResolveAt = 0
local policyAt = 0
local seriesAt = {}
local simulation = nil
local lastRequestId = nil

-- Publishing

local function withRuntimeReference(snap)
  local copy = table.clone(snap)
  copy.runtimeFullSec = trackState.runtimeFullSec
  return copy
end

-- What the entries see: the real snapshot and link, or a simulation of them.
local function publish()
  local snap, shown = lastGood, link
  if simulation == "no_ups" then
    snap = nil
    shown = { state = "unavailable", message = noctalia.tr("reason.simulated") }
  elseif simulation == "lost" then
    snap = snap or DEMO
    shown = { state = "lost", message = noctalia.tr("reason.simulated"), lastOkAt = os.time() - 12 }
  elseif simulation ~= nil then
    local copy = table.clone(snap or DEMO)
    for field, value in SIMULATIONS[simulation] do
      copy[field] = value
    end
    snap = copy
    shown = { state = "ok", source = link.source, ups = link.ups, lastOkAt = os.time() }
  end
  noctalia.state.set(KEYS.snapshot, if snap then withRuntimeReference(snap) else nil)
  noctalia.state.set(KEYS.link, shown)
end

local function setLink(state: string, kind: string?, message: string?)
  link = {
    state = state,
    kind = kind,
    message = message,
    source = active and active.kind,
    ups = active and active.ups,
    lastOkAt = link.lastOkAt,
  }
  if state == "ok" then
    link.lastOkAt = os.time()
  end
  publish()
end

-- The 2-minute series follows every poll; longer spans update once per bucket.
local function publishSeries(now: number)
  for span, seconds in shared.SPAN_SECONDS do
    local bucket = seconds / shared.GRAPH_POINTS
    if now - (seriesAt[span] or 0) >= bucket then
      seriesAt[span] = now
      noctalia.state.set(
        shared.seriesKey(span),
        tracker.series(history, now, seconds, shared.GRAPH_POINTS, shared.STAT_ORDER)
      )
    end
  end
end

-- Adds events whose log switch is on, newest first, and saves the log.
local function record(newEvents)
  local added = false
  for _, event in newEvents do
    if config.log[event.category] then
      table.insert(events, 1, {
        key = event.key,
        text = event.text,
        at = event.at,
        durationSec = event.durationSec,
        category = event.category,
      })
      added = true
    end
  end
  if added then
    while #events > MAX_EVENTS do
      table.remove(events)
    end
    noctalia.state.set(KEYS.events, events)
    local text = noctalia.json.encode(events)
    if text then
      saveText("events.json", text)
    end
  end
end

local function saveTrackerState()
  local text = noctalia.json.encode(tracker.saved(trackState))
  if text and text ~= savedStateText then
    savedStateText = text
    saveText("state.json", text)
    noctalia.state.set(KEYS.test, trackState.test)
  end
end

-- Poll results

-- A poll without a usable status. `immediate` marks failures the source
-- reports itself; anything else needs LOST_AFTER_FAILURES in a row.
local function onFailure(kind: string, message: string, now: number, immediate: boolean)
  failures += 1
  if lastGood == nil then
    setLink("unavailable", kind, message)
  elseif link.state ~= "lost" and (immediate or failures >= LOST_AFTER_FAILURES) then
    record(tracker.linkChange(trackState, link.state, "lost", now))
    setLink("lost", kind, message)
  end
end

local function onSnapshot(snap, now: number)
  if snap.status == "lost_comm" then
    onFailure("lost_comm", noctalia.tr("status.lost_comm"), now, true)
    return
  end
  shared.enrich(snap)
  failures = 0
  local newEvents = tracker.observe(trackState, snap, now)
  if link.state == "lost" then
    for _, event in tracker.linkChange(trackState, "lost", "ok", now) do
      table.insert(newEvents, event)
    end
  end
  record(newEvents)
  saveTrackerState()
  tracker.push(history, snap, now, STAT_FIELDS)
  lastGood = snap
  setLink("ok")
  publishSeries(now)
end

local function sourceLabel(kind: string): string
  return if kind == "pwrstat" then "pwrstat" else "NUT"
end

local function poll()
  if polling or active == nil then
    return
  end
  local current = active
  local parser = if current.kind == "pwrstat" then pwrstat else nut
  local argv = if current.kind == "pwrstat" then pwrstat.STATUS_ARGV else nut.statusArgv(current.ups)
  polling = true
  local started = noctalia.runAsync(argv, function(result)
    polling = false
    if active ~= current then
      return
    end
    local now = os.time()
    if result.timedOut then
      onFailure("timeout", noctalia.tr("reason.timeout"), now, false)
      return
    end
    local snap, kind, message = parser.parseStatus(result.stdout .. result.stderr)
    if snap then
      onSnapshot(snap, now)
    else
      onFailure(kind, `{sourceLabel(current.kind)}: {message}`, now, kind == "stale" or kind == "driver")
    end
  end, COMMAND_TIMEOUT_MS)
  if not started then
    polling = false
  end
end

-- Finding the UPS

-- "ok", "permission" (installed but not runnable by this user) or "missing"
local function pwrstatAvailability(): string
  if noctalia.commandExists("pwrstat") then
    return "ok"
  end
  for _, path in PWRSTAT_PATHS do
    if noctalia.fileExists(path) then
      return "permission"
    end
  end
  return "missing"
end

-- Picks the data source: the configured one, or under Auto the first that
-- answers with a real status (pwrstat, then NUT on this machine).
local function resolve()
  resolving = true
  resolveGen += 1
  local gen = resolveGen
  local candidates = {}
  if config.source ~= "nut" then
    table.insert(candidates, "pwrstat")
  end
  if config.source ~= "pwrstat" then
    table.insert(candidates, "nut")
  end
  local reasons = {}

  local tryNext

  local function accept(source, snap)
    resolving = false
    active = source
    failures = 0
    onSnapshot(snap, os.time())
  end

  local function tryStatus(source, argv, parser)
    local started = noctalia.runAsync(argv, function(result)
      if gen ~= resolveGen then
        return -- the data source settings changed while this search ran
      end
      local snap, _, message = parser.parseStatus(result.stdout .. result.stderr)
      if snap and snap.status ~= "lost_comm" then
        accept(source, snap)
      else
        local why = if snap then noctalia.tr("status.lost_comm") else message
        table.insert(reasons, `{sourceLabel(source.kind)}: {why}`)
        tryNext()
      end
    end, COMMAND_TIMEOUT_MS)
    if not started then
      table.insert(reasons, noctalia.tr("reason.busy"))
      tryNext()
    end
  end

  local index = 0
  tryNext = function()
    index += 1
    local kind = candidates[index]
    if kind == nil then
      resolving = false
      active = nil
      nextResolveAt = os.time() + RETRY_SEC
      setLink("unavailable", "none", table.concat(reasons, " · "))
    elseif kind == "pwrstat" then
      local availability = pwrstatAvailability()
      if availability == "ok" then
        tryStatus({ kind = "pwrstat" }, pwrstat.STATUS_ARGV, pwrstat)
      else
        table.insert(reasons, noctalia.tr("reason.pwrstat_" .. availability))
        tryNext()
      end
    elseif not noctalia.commandExists("upsc") then
      table.insert(reasons, noctalia.tr("reason.nut_missing"))
      tryNext()
    elseif config.nutUps ~= "" then
      if nut.isValidUps(config.nutUps) then
        tryStatus({ kind = "nut", ups = config.nutUps }, nut.statusArgv(config.nutUps), nut)
      else
        table.insert(reasons, noctalia.tr("reason.nut_invalid", { ups = config.nutUps }))
        tryNext()
      end
    else
      local started = noctalia.runAsync(nut.listArgv(nil), function(result)
        if gen ~= resolveGen then
          return
        end
        local names = if result.exitCode == 0 then nut.parseList(result.stdout) else {}
        if #names > 0 then
          tryStatus({ kind = "nut", ups = names[1] }, nut.statusArgv(names[1]), nut)
        else
          local _, message = nut.classifyFailure(result.stdout .. result.stderr)
          table.insert(reasons, `NUT: {if message ~= "" then message else noctalia.tr("reason.nut_none")}`)
          tryNext()
        end
      end, COMMAND_TIMEOUT_MS)
      if not started then
        table.insert(reasons, noctalia.tr("reason.busy"))
        tryNext()
      end
    end
  end

  tryNext()
end

-- Protection policy, for the panel

local function refreshPolicy(now: number)
  if active == nil or now - policyAt < POLICY_REFRESH_SEC then
    return
  end
  policyAt = now
  if active.kind ~= "pwrstat" then
    -- NUT's thresholds arrive with every snapshot (battery.charge.low / runtime.low).
    noctalia.state.set(KEYS.policy, { source = "nut" })
    return
  end
  local current = active
  noctalia.runAsync(pwrstat.CONFIG_ARGV, function(result)
    if active ~= current then
      return
    end
    local policy = pwrstat.parseConfig(result.stdout .. result.stderr)
    if policy then
      noctalia.state.set(KEYS.policy, { source = "pwrstat", config = policy })
    end
  end, COMMAND_TIMEOUT_MS)
end

-- Panel actions

local ACTIONS = { test = true, mute = true, alarm_on = true, alarm_off = true }

local function reply(id, ok: boolean, message: string)
  noctalia.state.set(KEYS.reply, { id = id, ok = ok, message = message })
end

local function runAction(id, action: string)
  if not ACTIONS[action] or active == nil then
    reply(id, false, noctalia.tr("reply.no_ups"))
    return
  end
  if active.kind == "nut" then
    -- upscmd asks for the NUT username and password, so it runs in a terminal.
    local command = nut.terminalCommand(active.ups, action)
    local opened = command ~= nil and noctalia.runInTerminal(command)
    reply(id, opened, noctalia.tr(if opened then "reply.terminal" else "reply.failed"))
    return
  end
  local argv = if action == "test"
    then pwrstat.TEST_ARGV
    elseif action == "mute" then pwrstat.MUTE_ARGV
    else pwrstat.alarmArgv(action == "alarm_on")
  local started = noctalia.runAsync(argv, function(result)
    local ok = result.exitCode == 0 and not result.timedOut
    local text = noctalia.string.trim(result.stdout .. "\n" .. result.stderr)
    reply(id, ok, if text ~= "" then text else noctalia.tr(if ok then "reply.done" else "reply.failed"))
    policyAt = 0 -- the alarm state may have changed
    poll()
  end, COMMAND_TIMEOUT_MS)
  if not started then
    reply(id, false, noctalia.tr("reply.busy"))
  end
end

noctalia.state.watch(KEYS.request, function(request)
  if type(request) ~= "table" or request.id == nil or request.id == lastRequestId then
    return
  end
  lastRequestId = request.id
  runAction(request.id, request.action)
end)

-- Entry points

-- Noctalia calls update() right after this script loads, then on the interval.
function update()
  local now = os.time()
  if active ~= nil then
    poll()
    refreshPolicy(now)
  elseif not resolving and now >= nextResolveAt then
    resolve()
  end
end

-- noctalia msg plugin cutecaption/cutemonitor-ups:service all <event> [payload]
--   simulate on_battery|low_battery|overload|lost|no_ups|off   preview a state
--   refresh                                                    poll now
--   dump                                                       log the current state
function onIpc(event, payload)
  if event == "simulate" then
    local name = noctalia.string.trim(payload or "")
    if name == "off" or name == "" then
      simulation = nil
    elseif SIMULATIONS[name] then
      simulation = name
    else
      noctalia.log(`cutemonitor-ups: unknown simulation "{name}"`)
      return
    end
    publish()
  elseif event == "refresh" then
    if active ~= nil then
      poll()
    elseif not resolving then
      resolve()
    end
  elseif event == "dump" then
    local text = noctalia.json.encode({ active = active, link = link, snapshot = lastGood, simulation = simulation }, true)
    noctalia.log(`cutemonitor-ups state: {text}`)
  end
end

function onConfigChanged()
  local before = `{config.source}|{config.nutUps}`
  local beforePoll = config.pollSec
  readConfig()
  if `{config.source}|{config.nutUps}` ~= before then
    resolveGen += 1 -- a search still running belongs to the old settings
    resolving = false
    active = nil
    lastGood = nil
    failures = 0
    nextResolveAt = 0
    policyAt = 0
    history = tracker.newHistory()
    seriesAt = {}
    trackState.prev = nil
    link.lastOkAt = nil -- that reading came from the old source
    setLink("starting")
  end
  if config.pollSec ~= beforePoll then
    noctalia.setUpdateInterval(config.pollSec * 1000)
  end
end

readConfig()
noctalia.state.set(KEYS.events, events)
noctalia.state.set(KEYS.test, trackState.test)
setLink("starting")
noctalia.setUpdateInterval(config.pollSec * 1000)
