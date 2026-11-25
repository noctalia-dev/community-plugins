--!nonstrict
-- Shared by the bar widget, the panel and the Control Center tile.
--
-- Every entry runs in its own VM, so the timer lives outside of them:
--   * the chosen minutes: a file in the plugin data dir + noctalia.state "minutes"
--   * a running timer: a transient systemd user timer owned by the plugin, plus a
--     "deadline" file in the plugin data dir with its end time and the boot it belongs to.
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

-- Shutdown time in unix seconds while the plugin's timer runs, or nil
function M.scheduledAt()
  local raw = deadlineFile and noctalia.readFile(deadlineFile)
  local at, boot = (raw or ""):match("^(%d+)%s*([%x%-]*)")
  at = tonumber(at)
  if not at then
    return nil
  end
  -- Left from an earlier boot (user timers do not survive a reboot), or the deadline
  -- passed and the system is still up because the power-off was refused
  if (boot ~= "" and boot ~= bootId()) or at < os.time() - 5 then
    clearDeadline()
    return nil
  end
  return at
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

local function finish(onDone)
  announce()
  if onDone then
    onDone()
  end
end

function M.start(value, onDone)
  if not deadlineFile or M.scheduledAt() then
    return
  end
  local at = os.time() + value * 60
  noctalia.runAsync({
    "systemd-run", "--user", "--unit=" .. UNIT, "--collect",
    "--description=Sleep Timer: power off",
    "--on-active=" .. (value * 60) .. "s", "--timer-property=AccuracySec=1s",
    "systemctl", "poweroff",
  }, function(result)
    if result.exitCode ~= 0 then
      noctalia.notifyError(noctalia.tr("notify.title"), result.stderr)
    else
      noctalia.writeFile(deadlineFile, string.format("%d %s", at, bootId()))
      noctalia.notify(noctalia.tr("notify.started_title"), noctalia.tr("notify.started_body", {
        time = M.formatLong(value),
        clock = os.date("%H:%M", at),
      }))
    end
    finish(onDone)
  end)
end

-- systemctl's exit code when the unit is not loaded: the timer is already gone
local NOT_LOADED = 5

function M.cancel(onDone)
  if not M.scheduledAt() then
    return
  end
  noctalia.runAsync({ "systemctl", "--user", "stop", UNIT .. ".timer" }, function(result)
    if result.exitCode ~= 0 and result.exitCode ~= NOT_LOADED then
      noctalia.notifyError(noctalia.tr("notify.title"), result.stderr)
    else
      clearDeadline()
      noctalia.notify(noctalia.tr("notify.cancelled_title"), noctalia.tr("notify.cancelled_body"))
    end
    finish(onDone)
  end)
end

-- Drops the deadline when the timer unit is gone (stopped from a terminal, or the user
-- manager restarted). Cheap to call: it runs nothing while no timer is set.
function M.verify(onDone)
  if not M.scheduledAt() then
    return
  end
  noctalia.runAsync({ "systemctl", "--user", "is-active", "--quiet", UNIT .. ".timer" }, function(result)
    if result.exitCode ~= 0 and M.scheduledAt() then
      clearDeadline()
      finish(onDone)
    end
  end)
end

return M
