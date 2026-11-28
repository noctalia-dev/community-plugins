--!nonstrict
-- Shared by every entry: state keys, the command helper, and time formatting.

local M = {}

M.PLUGIN = "jonfriesen/caffeinate-plus"
M.PANEL = M.PLUGIN .. ":panel"
M.STATUS = "caffeinate.status"
M.CMD = "caffeinate.cmd"

local seq = 0

-- Sends a command to the service. The nonce makes repeated identical commands
-- still count as a change for noctalia.state.watch.
function M.send(action, arg)
  seq += 1
  noctalia.state.set(M.CMD, { action = action, arg = arg, nonce = `{noctalia.nowMs()}-{seq}` })
end

function M.status()
  local s = noctalia.state.get(M.STATUS)
  if type(s) == "table" then
    return s
  end
  return {
    active = false,
    session = false,
    owned = false,
    lidEnabled = false,
    lidHeld = false,
    dimEnabled = true,
    dimmed = false,
    busy = false,
  }
end

-- Compact remaining time for the bar: "45s", "12m", "3h 05m".
function M.short(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  if seconds < 60 then
    return `{seconds}s`
  end
  -- Round up so a fresh 15m preset reads 15m, not 14m.
  local mins = math.ceil(seconds / 60)
  if mins < 60 then
    return `{mins}m`
  end
  return string.format("%dh %02dm", mins // 60, mins % 60)
end

-- Preset button label: 5 -> "5m", 60 -> "1h", 90 -> "1h 30m".
function M.presetLabel(minutes)
  if minutes < 60 then
    return `{minutes}m`
  end
  local h, m = minutes // 60, minutes % 60
  if m == 0 then
    return `{h}h`
  end
  return `{h}h {m}m`
end

-- Configured presets as whole minutes, in order, skipping junk entries.
function M.presets()
  local raw = noctalia.getConfig("presets_minutes")
  local out = {}
  if type(raw) == "table" then
    for _, v in raw do
      local n = tonumber(v)
      if n and n > 0 and n < 100000 then
        table.insert(out, math.floor(n))
      end
    end
  end
  if #out == 0 then
    out = { 5, 15, 30, 60, 240, 480 }
  end
  return out
end

return M
