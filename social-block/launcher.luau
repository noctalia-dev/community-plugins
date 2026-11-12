--!nonstrict
-- Launcher provider: /block, /block 30, /block slack, /block off, ...
local PLUGIN = "treeonlinux/social-block"
local SERVICE = PLUGIN .. ":service"

local function send(event, payload)
  local args = { "noctalia", "msg", "plugin", SERVICE, "all", event }
  if payload then args[#args + 1] = payload end
  noctalia.runAsync(args)
end

local function statusText()
  local blocked = noctalia.state.get("blocked") == true
  if not blocked then return "Off" end
  local rem = noctalia.state.get("remaining") or 0
  if rem > 0 then return "On · " .. rem .. "m left" end
  return "On until you turn it off"
end

local function standardResults()
  return {
    { id = "on",      title = "Block enabled services",   subtitle = "Until you turn it off", glyph = "shield-lock" },
    { id = "15",      title = "Block for 15 minutes",     subtitle = "Timer",                 glyph = "clock" },
    { id = "30",      title = "Block for 30 minutes",     subtitle = "Timer",                 glyph = "clock" },
    { id = "60",      title = "Block for 1 hour",         subtitle = "Timer",                 glyph = "clock" },
    { id = "forever", title = "Clear my timer",           subtitle = "Keep blocking",         glyph = "infinity" },
    { id = "off",     title = "Turn Social Block off",    subtitle = "Restore sites and DNS", glyph = "shield-off" },
    { id = "status",  title = "Show status",              subtitle = statusText(),            glyph = "info-circle" },
  }
end

local function matches(text, query)
  return string.find(string.lower(text or ""), query, 1, true) ~= nil
end

function onQuery(text)
  local q = string.lower(text or "")
  local base = standardResults()
  if q == "" then
    launcher.setResults(text, base)
    return
  end

  local out = {}
  for _, r in ipairs(base) do
    if matches(r.title, q) or matches(r.id, q) then
      out[#out + 1] = r
    end
  end

  for _, s in ipairs(noctalia.state.get("services") or {}) do
    if matches(s.name, q) or matches(s.id, q) then
      out[#out + 1] = {
        id = "allow:" .. s.id,
        title = "Allow " .. s.name,
        subtitle = s.blocked and "Currently blocked" or "Already allowed",
        glyph = "circle-check",
      }
      out[#out + 1] = {
        id = "block:" .. s.id,
        title = "Block " .. s.name,
        subtitle = s.blocked and "Already blocked" or "Currently allowed",
        glyph = "circle-x",
      }
    end
  end
  launcher.setResults(text, out)
end

function onActivate(id)
  local action, service = string.match(id or "", "^(allow|block):([a-z0-9-]+)$")
  if action then
    send(action, service)
    return
  end

  if id == "on" or id == "off" or id == "forever" then
    send(id)
  elseif id == "15" or id == "30" or id == "60" then
    send("timer", id)
  elseif id == "status" then
    noctalia.notify("Social Block", statusText())
  end
end
