--!nonstrict
-- Shared by the bar widget, the panel and the Control Center tile.
--
-- Every entry runs in its own VM, so the timer lives outside of them:
--   * the chosen minutes: a file in the plugin data dir + noctalia.state "minutes"
--   * a running timer: a transient systemd user timer owned by the plugin. That unit is the
--     source of truth; a "deadline" file in the plugin data dir caches its end time and the
--     boot it belongs to, so every entry can draw the countdown without asking systemd.
-- noctalia.state "scheduled" is bumped after start/cancel so the other entries redraw at once.
--
-- The plugin never reads or changes logind's shutdown schedule (`shutdown -h`/`-c`): it
-- only starts and stops its own timer unit, so a shutdown or reboot scheduled by anything
-- else is never replaced or cancelled.

local M = {}

M.STEP_MINUTES = 15
M.DEFAULT_MINUTES = 30
M.MINUTES_PER_LAP = 60
M.MAX_MINUTES = 24 * 60 - 1
M.PANEL_ID = "nid25/sleep_timer:panel"

-- The plugin's own systemd user timer; systemd refuses a second unit with this name,
-- so a timer can never be started twice
local UNIT = "noctalia-sleep-timer"
local BOOT_ID_FILE = "/proc/sys/kernel/random/boot_id"

M.dataDir = noctalia.pluginDataDir()
local minutesFile = M.dataDir and (M.dataDir .. "/minutes")
local deadlineFile = M.dataDir and (M.dataDir .. "/deadline")

function M.loadMinutes()
  local shared = noctalia.state.get("minutes")
  if type(shared) == "number" then
    return shared
  end
  local raw = minutesFile and noctalia.readFile(minutesFile)
  local saved = raw and tonumber(raw)
  if saved and saved >= 1 then
    return math.min(math.floor(saved), M.MAX_MINUTES)
  end
  return M.DEFAULT_MINUTES
end

-- Saves and publishes the chosen minutes; returns the value actually stored
function M.setMinutes(value)
  value = math.clamp(math.floor(value), 1, M.MAX_MINUTES)
  if minutesFile then
    noctalia.writeFile(minutesFile, tostring(value))
  end
  noctalia.state.set("minutes", value)
  return value
end

local function bootId()
  local raw = noctalia.readFile(BOOT_ID_FILE)
  return raw and raw:match("[%x%-]+") or ""
end

local function clearDeadline()
  if deadlineFile and noctalia.fileExists(deadlineFile) then
    noctalia.removeFile(deadlineFile)
  end
end

-- Last known shutdown time in unix seconds, or nil. This is only a cache for drawing the
-- countdown: the timer unit in systemd is the source of truth, and M.verify() keeps this
-- in step with it. Wall-clock time never clears it (the timer is monotonic, so a clock
-- change or a suspend moves the real deadline); only a new boot does, because user timers
-- never survive a reboot.
function M.scheduledAt()
  local raw = deadlineFile and noctalia.readFile(deadlineFile)
  local at, boot = (raw or ""):match("^(%d+)%s*([%x%-]*)")
  at = tonumber(at)
  if not at then
    return nil
  end
  if boot ~= "" and boot ~= bootId() then
    clearDeadline()
    return nil
  end
  return at
end

-- Set only when systemd confirmed that no timer of ours is armed. Without it and without
-- a cached deadline the state is unknown, which the entries never treat as idle.
local IDLE_KEY = "idleConfirmed"

-- "armed" (with the cached end time), "idle" (confirmed by systemd) or "unknown" (not
-- read yet, or systemd could not be asked): then both Start and Cancel are offered
function M.status()
  local at = M.scheduledAt()
  if at then
    return "armed", at
  end
  if noctalia.state.get(IDLE_KEY) == true then
    return "idle", nil
  end
  return "unknown", nil
end

local function setIdle(confirmed)
  noctalia.state.set(IDLE_KEY, confirmed)
end

function M.remainingMinutes(at)
  return math.max(1, math.ceil((at - os.time()) / 60))
end

-- "1:05" style, used inside the dial and on the tile
function M.formatClock(value)
  return string.format("%d:%02d", value // 60, value % 60)
end

-- "1 h 05 min" style, used under the dial and in tooltips and notifications
function M.formatLong(value)
  if value < 60 then
    return noctalia.tr("duration.minutes", { m = tostring(value) })
  end
  return noctalia.tr("duration.hours", { h = tostring(value // 60), mm = string.format("%02d", value % 60) })
end

-- Font for the numbers drawn into the dial images: the plugin setting, else the shell font
function M.fontFamily()
  local family = noctalia.getConfig("font_family")
  if type(family) ~= "string" or family == "" then
    family = noctalia.getSetting("shell.font_family")
  end
  if type(family) ~= "string" or family == "" then
    return "sans-serif"
  end
  -- The name goes into an SVG attribute
  local clean = family:gsub('[<>&"]', "")
  return clean .. ", sans-serif"
end

-- Every lap of the dial paints over the previous one:
-- lap 1 neutral over dim neutral, lap 2 accent over neutral, lap 3 neutral over accent...
-- Returns how much of the current lap is lit (0..1] and the colors to draw it with.
function M.lapStyle(value, neutral, accent)
  local lap = math.max(1, math.ceil(value / M.MINUTES_PER_LAP))
  local inLap = value - (lap - 1) * M.MINUTES_PER_LAP
  local style = {
    lap = lap,
    fraction = inLap / M.MINUTES_PER_LAP,
    lit = lap % 2 == 0 and accent or neutral,
    unlit = lap % 2 == 0 and neutral or accent,
    unlitOpacity = 1,
  }
  if lap == 1 then
    style.unlit = neutral
    style.unlitOpacity = 0.3
  end
  return style
end

-- Keeps at most two dial images per entry on disk: the one shown and the one before it.
-- The previous file is removed one change later, so it is never deleted while still on screen.
function M.imageTracker()
  local shown, previous = nil, nil
  return function(path)
    if path == shown then
      return
    end
    if previous and previous ~= path then
      noctalia.removeFile(previous)
    end
    previous, shown = shown, path
  end
end

local function announce()
  -- Any changing value works; the watchers only re-read the deadline file
  noctalia.state.set("scheduled", noctalia.nowMs())
end

-- Every systemctl call gets an answer, so the busy flag below is always released
local COMMAND_TIMEOUT_MS = 10000
-- Start and Cancel can come from any entry; while one is talking to systemd the others
-- wait, so a quick Start then Cancel can never run in the wrong order. The flag holds a
-- time and expires on its own in case an entry is unloaded mid-command.
local BUSY_KEY = "busy"
local BUSY_EXPIRES_MS = COMMAND_TIMEOUT_MS + 2000

local function busy()
  local since = noctalia.state.get(BUSY_KEY)
  return type(since) == "number" and noctalia.nowMs() - since < BUSY_EXPIRES_MS
end

-- Bumped when a Start or Cancel begins and when it ends. A status reply is applied only
-- if no Start or Cancel began or ended since its query was sent, so an older "no timer"
-- answer can never delete the deadline of a timer started after it.
local GENERATION_KEY = "generation"

local function generation()
  return tonumber(noctalia.state.get(GENERATION_KEY)) or 0
end

local function setBusy(on)
  noctalia.state.set(GENERATION_KEY, generation() + 1)
  noctalia.state.set(BUSY_KEY, on and noctalia.nowMs() or false)
end

local function finish(onDone)
  setBusy(false)
  announce()
  if onDone then
    onDone()
  end
end

local function systemctl(argv, onResult)
  noctalia.runAsync(argv, onResult, COMMAND_TIMEOUT_MS)
end

local function errorText(result)
  local text = (result.stderr or ""):match("^%s*(.-)%s*$")
  if text == "" then
    return noctalia.tr("notify.command_failed")
  end
  return text
end

local function writeDeadline(at)
  noctalia.writeFile(deadlineFile, string.format("%d %s", at, bootId()))
end

local verify

function M.start(value, onDone)
  if not deadlineFile or busy() or M.scheduledAt() then
    return
  end
  setBusy(true)
  local at = os.time() + value * 60
  -- RemainAfterElapse=no unloads the timer once it fires, so the name is free again even
  -- when the power-off was refused
  systemctl({
    "systemd-run", "--user", "--unit=" .. UNIT, "--collect",
    "--description=Sleep Timer: power off",
    "--on-active=" .. (value * 60) .. "s",
    "--timer-property=AccuracySec=1s", "--timer-property=RemainAfterElapse=no",
    "systemctl", "poweroff",
  }, function(result)
    if result.exitCode ~= 0 then
      noctalia.notifyError(noctalia.tr("notify.title"), errorText(result))
      -- The unit may exist after all (that is the usual reason systemd-run fails)
      setIdle(false)
      finish(onDone)
      -- Most likely a timer of ours the cache lost: pick it up so Cancel is offered
      verify(onDone)
      return
    end
    writeDeadline(at)
    setIdle(false)
    noctalia.notify(noctalia.tr("notify.started_title"), noctalia.tr("notify.started_body", {
      time = M.formatLong(value),
      clock = os.date("%H:%M", at),
    }))
    finish(onDone)
  end)
end

-- systemctl's exit code when the unit is not loaded: the timer is already gone
local NOT_LOADED = 5

-- Always asks systemd, even when no deadline is known, so a timer whose status could not
-- be read can still be cancelled. The countdown is cleared only once systemd confirms the
-- unit is stopped or gone; on any other error it stays, and Cancel with it.
function M.cancel(onDone)
  if busy() then
    return
  end
  setBusy(true)
  local known = M.scheduledAt() ~= nil
  systemctl({ "systemctl", "--user", "stop", UNIT .. ".timer" }, function(result)
    if result.exitCode == 0 or result.exitCode == NOT_LOADED then
      clearDeadline()
      setIdle(true)
      if known or result.exitCode == 0 then
        noctalia.notify(noctalia.tr("notify.cancelled_title"), noctalia.tr("notify.cancelled_body"))
      end
    else
      noctalia.notifyError(noctalia.tr("notify.title"), errorText(result))
    end
    finish(onDone)
  end)
end

-- Next power-off of the plugin's timer from `systemctl list-timers` JSON: unix seconds when
-- armed, false when systemd confirms nothing is pending, nil when the answer is unusable
local function parseTimers(stdout)
  stdout = (stdout or ""):match("^%s*(.-)%s*$")
  if stdout == "" or stdout:match("^%[%s*%]$") then
    -- No timer matches: an empty list ("[]"), or no output at all
    return false
  end
  local ok, timers = pcall(noctalia.json.decode, stdout)
  if not ok or type(timers) ~= "table" then
    return nil
  end
  for _, entry in ipairs(timers) do
    if type(entry) == "table" and entry.unit == UNIT .. ".timer" then
      local elapse = tonumber(entry.next)
      -- No next elapse: the timer already fired and will not fire again
      return (elapse and elapse > 0) and math.floor(elapse / 1000000) or false
    end
  end
  return false
end

-- Seconds after the deadline during which a missing unit means "shutting down", not "refused"
local POWEROFF_GRACE = 15
local VERIFIED_KEY = "verifiedAt"
-- How often a cached countdown is checked against systemd
local VERIFY_EVERY_MS = 30000

-- Syncs the cached deadline with the timer unit: picks up its real end time (it moves with
-- clock changes and suspends), adopts a timer the cache lost, and drops the cache only
-- when systemd confirms no timer of ours is armed. A failed query changes nothing.
verify = function(onDone)
  if not deadlineFile or busy() then
    -- A running Start or Cancel settles the state itself
    return
  end
  local sentIn = generation()
  noctalia.state.set(VERIFIED_KEY, noctalia.nowMs())
  systemctl({
    "systemctl", "--user", "list-timers", "--all", "--no-pager", "--output=json", UNIT .. ".timer",
  }, function(result)
    if busy() or generation() ~= sentIn then
      -- A Start or Cancel began or ended meanwhile: this answer may predate it
      return
    end
    -- Not "exitCode == 0 and parseTimers(...) or nil": that would turn false into nil
    local armedAt = nil
    if result.exitCode == 0 then
      armedAt = parseTimers(result.stdout)
    end
    if armedAt == nil then
      -- No usable answer: the state stays what it was, unknown included
      noctalia.log(string.format("sleep_timer: unusable timer status (exit %s, timed out %s): stdout %q, stderr %q",
        tostring(result.exitCode), tostring(result.timedOut), (result.stdout or ""):sub(1, 200),
        (result.stderr or ""):sub(1, 200)))
      return
    end
    local status, cached = M.status()
    if armedAt == false then
      if cached and cached <= os.time() and os.time() - cached < POWEROFF_GRACE then
        -- Just fired: the power-off may still be under way, so decide on the next check
        return
      end
      if status == "idle" then
        return
      end
      clearDeadline()
      setIdle(true)
      if cached and cached <= os.time() then
        -- The timer fired and the system is still up: the power-off was refused
        noctalia.notifyError(noctalia.tr("notify.title"), noctalia.tr("notify.poweroff_failed"))
      end
    elseif not cached or math.abs(cached - armedAt) >= 2 then
      writeDeadline(armedAt)
      setIdle(false)
    else
      return
    end
    announce()
    if onDone then
      onDone()
    end
  end)
end
M.verify = verify

-- Called from every entry's update(): unless systemd confirmed that no timer runs, one of
-- them checks the state every 30 seconds, so an unknown state keeps being retried.
-- Runs nothing while the plugin is confirmed idle.
function M.poll(onDone)
  if M.status() == "idle" then
    return
  end
  local last = noctalia.state.get(VERIFIED_KEY)
  if type(last) == "number" and noctalia.nowMs() - last < VERIFY_EVERY_MS then
    return
  end
  verify(onDone)
end

return M
