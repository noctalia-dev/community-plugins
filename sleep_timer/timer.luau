--!nonstrict
-- Shared by the bar widget, the panel and the Control Center tile.
--
-- Every entry runs in its own VM, so the timer lives outside of them:
--   * the chosen minutes: a file in the plugin data dir + noctalia.state "minutes"
--   * a running timer: logind's shutdown schedule, which `shutdown -h +N` writes.
-- noctalia.state "scheduled" is bumped after start/cancel so the other entries redraw at once.

local M = {}

M.STEP_MINUTES = 15
M.DEFAULT_MINUTES = 30
M.MINUTES_PER_LAP = 60
M.MAX_MINUTES = 24 * 60 - 1
M.PANEL_ID = "nid25/sleep_timer:panel"

-- Written by logind while a shutdown is scheduled, also when set from a terminal
local SCHEDULED_FILE = "/run/systemd/shutdown/scheduled"

M.dataDir = noctalia.pluginDataDir()
local minutesFile = M.dataDir and (M.dataDir .. "/minutes")

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

-- Schedule modes that count as this timer; a scheduled reboot is left alone
local SHUTDOWN_MODES = { poweroff = true, halt = true }

-- Shutdown time in unix seconds, or nil when nothing is scheduled
function M.scheduledAt()
  local raw = noctalia.readFile(SCHEDULED_FILE)
  if not raw then
    return nil
  end
  local mode = raw:match("MODE=([%w%-]+)")
  if mode and not SHUTDOWN_MODES[mode] then
    return nil
  end
  local usec = raw:match("USEC=(%d+)")
  return usec and math.floor(tonumber(usec) / 1000000)
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
  -- Any changing value works; the watchers only re-read the logind schedule
  noctalia.state.set("scheduled", noctalia.nowMs())
end

local function runShutdown(args, onSuccess, onDone)
  noctalia.runAsync(args, function(result)
    if result.exitCode ~= 0 then
      noctalia.notifyError(noctalia.tr("notify.title"), result.stderr)
    else
      onSuccess()
    end
    announce()
    if onDone then
      onDone()
    end
  end)
end

function M.start(value, onDone)
  if M.scheduledAt() then
    return
  end
  if noctalia.fileExists(SCHEDULED_FILE) then
    -- Something else (a reboot) is scheduled; `shutdown -h` would silently replace it
    noctalia.notifyError(noctalia.tr("notify.title"), noctalia.tr("notify.other_scheduled"))
    return
  end
  runShutdown({ "shutdown", "-h", "+" .. value }, function()
    noctalia.notify(noctalia.tr("notify.started_title"), noctalia.tr("notify.started_body", {
      time = M.formatLong(value),
      clock = os.date("%H:%M", os.time() + value * 60),
    }))
  end, onDone)
end

function M.cancel(onDone)
  if not M.scheduledAt() then
    return
  end
  runShutdown({ "shutdown", "-c" }, function()
    noctalia.notify(noctalia.tr("notify.cancelled_title"), noctalia.tr("notify.cancelled_body"))
  end, onDone)
end

return M
