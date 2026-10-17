--!nonstrict
-- Reads the snapshot daemon.py publishes and formats it. Shared by the bar
-- widget and the panel, which are separate VMs and each poll the file.

local M = {}

-- The theme's accent. Deliberately not Anthropic's brand colour: Bloom is
-- unofficial and should not look like an Anthropic product.
M.ACCENT = "primary"

-- The CLI's thinking spinner; idle shows the resting flower, dimmed.
M.IDLE_GLYPH = "✽"
M.FRAMES = { "·", "✢", "✳", "∗", "✻", "✽", "✻", "∗", "✳", "✢" }

local stateHome = noctalia.getenv("XDG_STATE_HOME")
if stateHome == nil or stateHome == "" then
  stateHome = "~/.local/state"
end
M.STATUS_PATH = stateHome .. "/claude-tray/status.json"
M.FOCUS = "~/.local/share/claude-tray/focus.sh"

local EMPTY = { state = "idle", sessions = {}, usage = {}, limits = {}, updated = 0 }

-- Polled rather than watched: the daemon publishes by atomic rename, which
-- swaps the inode out from under a watcher. A half-written or missing file
-- keeps the previous snapshot.
function M.read(cb, previous)
  local queued = noctalia.readFileAsync(M.STATUS_PATH, function(text)
    local data = text and noctalia.json.decode(text)
    cb(type(data) == "table" and data or previous or EMPTY)
  end)
  if not queued then
    cb(previous or EMPTY)
  end
end

function M.label(s)
  if s == "working" then return "Working" end
  if s == "waiting" then return "Needs permission" end
  if s == "done" then return "Done" end
  return "Idle"
end

function M.colour(s)
  if s == "working" or s == "done" then return M.ACCENT end
  if s == "waiting" then return "error" end
  return "outline"
end

-- Accent while there is room, tertiary when it is getting close, red at the wall.
function M.limitColour(pct)
  if pct >= 90 then return "error" end
  if pct >= 70 then return "tertiary" end
  return M.ACCENT
end

function M.fmtTokens(n)
  n = tonumber(n) or 0
  if n >= 1e9 then return string.format("%.1fB", n / 1e9) end
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1e3 then return string.format("%.1fK", n / 1e3) end
  return tostring(math.floor(n + 0.5))
end

function M.fmtAgo(ts)
  local d = math.max(0, os.time() - math.floor(tonumber(ts) or 0))
  if d < 60 then return d .. "s" end
  if d < 3600 then return math.floor(d / 60) .. "m" end
  return math.floor(d / 3600) .. "h"
end

-- "20:40" for something within the day, "Mon 09:00" beyond that.
function M.fmtReset(ts)
  ts = tonumber(ts)
  if not ts or ts <= 0 then return "" end
  local soon = ts - os.time() < 20 * 3600
  return "resets " .. os.date(soon and "%H:%M" or "%a %H:%M", math.floor(ts))
end

function M.home(path)
  local home = noctalia.getenv("HOME") or ""
  if home ~= "" and string.sub(path, 1, #home) == home then
    return "~" .. string.sub(path, #home + 1)
  end
  return path
end

function M.basename(path)
  return string.match(path or "", "([^/]+)/*$") or "session"
end

return M
