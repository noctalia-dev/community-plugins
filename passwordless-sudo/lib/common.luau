--!nonstrict
-- Shared constants and formatting for every entry.

local M = {}

M.PLUGIN = "crsmthw/passwordless-sudo"
M.PANEL = M.PLUGIN .. ":panel"
M.HELPER = "/usr/local/bin/noctalia-sudo-passwordless"

-- Same choices as Omarchy's picker.
M.DURATIONS = {
  { value = "15", key = "duration.15m" },
  { value = "60", key = "duration.1h" },
  { value = "1440", key = "duration.1d" },
  { value = "permanent", key = "duration.permanent" },
}

function M.nowSec()
  return math.floor(noctalia.nowMs() / 1000)
end

-- "45 s", "12 min", "3 h 5 min"
function M.formatRemaining(seconds)
  seconds = math.max(0, math.floor(seconds))
  if seconds < 60 then
    return noctalia.tr("time.seconds", { n = seconds })
  end
  local minutes = math.ceil(seconds / 60)
  if minutes < 60 then
    return noctalia.tr("time.minutes", { n = minutes })
  end
  local h = math.floor(minutes / 60)
  local m = minutes % 60
  if m == 0 then
    return noctalia.tr("time.hours", { h = h })
  end
  return noctalia.tr("time.hours_minutes", { h = h, m = m })
end

-- Compact form for the bar: "45s", "12m", "3h".
function M.formatShort(seconds)
  seconds = math.max(0, math.floor(seconds))
  if seconds < 60 then
    return `{seconds}s`
  end
  local minutes = math.ceil(seconds / 60)
  if minutes < 60 then
    return `{minutes}m`
  end
  return `{math.floor(minutes / 60)}h`
end

function M.formatClock(epoch)
  return noctalia.formatTime(noctalia.timeFormat(), epoch)
end

-- "for 15 minutes" / "permanently"
function M.durationPhrase(duration)
  if duration == "permanent" then
    return noctalia.tr("phrase.permanently")
  end
  return noctalia.tr("phrase.for", { span = M.formatRemaining(tonumber(duration) * 60) })
end

function M.status()
  local s = noctalia.state.get("status")
  if type(s) ~= "table" then
    return { known = false, active = false, mode = "off", deadline = 0, busy = false }
  end
  return s
end

function M.send(action, duration)
  noctalia.state.set("command", { action = action, duration = duration, nonce = noctalia.nowMs() })
end

return M
