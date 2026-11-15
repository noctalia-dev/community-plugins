--!nonstrict
-- Shared by the panel, bar widget and shortcut.

local M = {}

M.STATE_KEY = "td_state"
M.COMMAND_KEY = "td_command"
M.PANEL_ID = "iwasironman/tablet-display:panel"

local counter = 0

function M.tr(key, subst)
  return noctalia.tr(key, subst)
end
local tr = M.tr

-- Asks the service to run an action. Each request carries a unique serial,
-- because every entry is its own VM with its own counter.
function M.send(action, extra)
  counter += 1
  local command = { action = action, serial = `{noctalia.nowMs()}-{counter}-{math.random(1, 1000000)}` }
  if type(extra) == "table" then
    for k, v in pairs(extra) do
      command[k] = v
    end
  end
  noctalia.state.set(M.COMMAND_KEY, command)
end

function M.snapshot()
  local s = noctalia.state.get(M.STATE_KEY)
  if type(s) ~= "table" then
    return { loading = true, mode = "off" }
  end
  return s
end

function M.isActive(s)
  return s.mode == "extend" or s.mode == "mirror"
end

local function hz(r)
  return tostring(math.floor((tonumber(r) or 0) + 0.5))
end

-- One line describing what is going on.
function M.statusLine(s)
  if s.loading then
    return tr("status.loading")
  end
  if s.available == false then
    return tr("status.script_failed")
  end
  local pending = s.pending or ""
  if pending == "extend" then return tr("status.starting_extend") end
  if pending == "mirror" then return tr("status.starting_mirror") end
  if pending == "off" then return tr("status.stopping") end
  if s.mode == "extend" then
    local m = s.monitor
    if type(m) == "table" then
      return tr("status.extended_on", { output = m.name, width = m.width, height = m.height, hz = hz(m.refresh) })
    end
    return tr("status.extended")
  elseif s.mode == "mirror" then
    return tr("status.mirroring", { output = s.target or "?" })
  end
  return tr("status.off")
end

function M.clientLine(s)
  local c = s.client
  if type(c) == "table" and c.width then
    return tr("status.client_connected", { width = c.width, height = c.height, fps = c.fps })
  end
  if M.isActive(s) then
    return tr("status.client_waiting")
  end
  return ""
end

return M
