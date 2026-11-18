--!nonstrict
-- Headless service: owns the single usbeehive watcher for the whole plugin and
-- publishes a digested snapshot to noctalia.state("snapshot").
--
-- Data flow:
--   1. `usbeehive --watch --json | jq -c` stream: one snapshot line at start and
--      one per hotplug (usbeehive pretty-prints its JSON; jq compacts it so
--      runStream gets one snapshot per line). If the pipeline dies, the wrapper
--      prints a sentinel carrying usbeehive's / jq's own error text.
--   2. while a USB-C port is charging, poll `usbeehive --json` every
--      poll_interval_s: the watcher only listens to usb/typec uevents, so a PD
--      renegotiation (power_supply) would otherwise go unnoticed.
--
-- Settings changes restart this runtime (no onConfigChanged), which also
-- restarts the stream with the new binary path.

local model = require("./lib/model.luau")

local EXIT_MARK = "__USBEEHIVE_EXIT__"
local IDLE_INTERVAL_MS = 5000
local RESTART_DELAY_MS = 10000

local bin = noctalia.getConfig("usbeehive_path")
if bin == nil or bin == "" then
  bin = "usbeehive"
elseif string.sub(bin, 1, 1) == "~" then
  bin = noctalia.expandPath(bin)
end

local options = {
  hideInternal = noctalia.getConfig("hide_internal") == true,
  showHubs = noctalia.getConfig("show_hubs") == true,
}
local pollMs = math.max(1, noctalia.getConfig("poll_interval_s") or 5) * 1000
local notifyHotplug = noctalia.getConfig("notify_hotplug") == true
local notifyWarnings = noctalia.getConfig("notify_warnings") == true

local streaming = false
local restartAt = nil -- nowMs at which to retry a failed/exited watcher
local polling = false -- update() runs at pollMs and polls while true
local pollInFlight = false
local lastText = nil -- raw output behind the current snapshot; identical polls are skipped
local current = model.emptySnapshot()
local known = nil -- key -> headline; nil until the first snapshot so startup is silent
local knownWarnings = {}

local function shellQuote(value)
  return "'" .. string.gsub(value, "'", [['"'"']]) .. "'"
end

local function publish(snap)
  current = snap
  noctalia.state.set("snapshot", snap)
end

-- Keep the last good data on screen and flag the error; retry later.
local function fail(message)
  noctalia.log("usbeehive: " .. message)
  local snap = table.clone(current)
  snap.status = "error"
  snap.error = message
  publish(snap)
  streaming = false
  lastText = nil
  restartAt = noctalia.nowMs() + RESTART_DELAY_MS
end

local function notifyChanges(snap)
  local devices = {}
  for _, d in ipairs(snap.devices) do
    if d.isPeripheral then
      devices[d.key] = d.headline
    end
  end
  local warnings = {}
  for _, w in ipairs(snap.warnings) do
    warnings[w.key .. "|" .. w.summary] = w
  end

  if known ~= nil then
    if notifyHotplug then
      for key, headline in pairs(devices) do
        if known[key] == nil then
          noctalia.notify(noctalia.tr("notify.connected"), headline)
        end
      end
      for key, headline in pairs(known) do
        if devices[key] == nil then
          noctalia.notify(noctalia.tr("notify.disconnected"), headline)
        end
      end
    end
    if notifyWarnings then
      for id, w in pairs(warnings) do
        if knownWarnings[id] == nil then
          noctalia.notify(w.summary, w.detail)
        end
      end
    end
  end

  known = devices
  knownWarnings = warnings
end

local function applyJson(text)
  if text == lastText then
    return
  end
  local raw, err = noctalia.json.decode(text)
  if type(raw) ~= "table" then
    noctalia.log("usbeehive: could not parse output: " .. tostring(err))
    return
  end
  lastText = text
  local snap = model.buildSnapshot(raw, options)
  notifyChanges(snap)
  publish(snap)

  local shouldPoll = snap.flow.mw > 0
  if shouldPoll ~= polling then
    polling = shouldPoll
    noctalia.setUpdateInterval(polling and pollMs or IDLE_INTERVAL_MS)
  end
end

local function pollOnce()
  if pollInFlight then
    return
  end
  pollInFlight = noctalia.runAsync({ bin, "--json" }, function(res)
    pollInFlight = false
    if res.exitCode == 0 then
      applyJson(res.stdout)
    end
  end)
end

local function refresh()
  if streaming then
    pollOnce()
  end
end

local function onStreamLine(line)
  if string.sub(line, 1, #EXIT_MARK) ~= EXIT_MARK then
    applyJson(line)
    return
  end
  local reason = noctalia.string.trim(string.sub(line, #EXIT_MARK + 1))
  fail(noctalia.tr("error.watcher_exited", { reason = reason ~= "" and reason or noctalia.tr("error.no_reason") }))
end

-- usbeehive and jq stay direct children of the wrapper so its TERM trap can
-- reap them on reload; their stderr goes to a temp file for the sentinel.
local function streamCommand()
  return table.concat({
    "err=$(mktemp)",
    shellQuote(bin) .. ' --watch --json 2>"$err" | jq -c --unbuffered . 2>>"$err" &',
    [[trap 'pkill -P $$ 2>/dev/null; rm -f "$err"; exit 0' INT TERM HUP]],
    "wait $!",
    "pkill -P $$ 2>/dev/null",
    'echo "' .. EXIT_MARK .. ' $(grep -m 1 -i error "$err" || tail -n 1 "$err")"',
    'rm -f "$err"',
  }, "\n")
end

local function startWatcher()
  streaming = noctalia.runStream(streamCommand(), onStreamLine)
  if not streaming then
    fail(noctalia.tr("error.stream_failed"))
  end
end

function update()
  if not streaming and restartAt ~= nil and noctalia.nowMs() >= restartAt then
    restartAt = nil
    startWatcher()
  elseif streaming and polling then
    pollOnce()
  end
end

-- Widget right-click / panel refresh button.
noctalia.state.watch("command", function(cmd)
  if type(cmd) == "table" and cmd.action == model.REFRESH then
    refresh()
  end
end)

-- noctalia msg plugin yangkx/usbeehive:monitor all refresh
function onIpc(event)
  if event == model.REFRESH then
    refresh()
  end
end

noctalia.setUpdateInterval(IDLE_INTERVAL_MS)
startWatcher()
