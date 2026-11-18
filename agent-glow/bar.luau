--!nonstrict
-- Agent Glow bar widget — dim spark when idle, lit + agent count when working.
-- Hover lists hot sessions with project and age; click opens the session panel.

local showIdle = noctalia.getConfig("show_when_idle")
if showIdle == nil then
  showIdle = true
end

local status = noctalia.state.get("status")
if type(status) ~= "table" then
  status = { active = false, count = 0, hot = {}, sessions = {} }
end

local function basename(path)
  if type(path) ~= "string" or path == "" then
    return ""
  end
  return string.match(path, "([^/]+)$") or path
end

local function ageText(lastActive)
  local age = os.time() - (tonumber(lastActive) or os.time())
  if age < 0 then
    age = 0
  end
  if age < 60 then
    return `{math.floor(age)}s ago`
  end
  return `{math.floor(age / 60)}m ago`
end

local function liveSessions()
  local out = {}
  local sessions = status.sessions
  if type(sessions) ~= "table" then
    return out
  end
  for _, session in ipairs(sessions) do
    if type(session) == "table" and session.live == true then
      table.insert(out, session)
    end
  end
  return out
end

local function sessionRow(session)
  local name = tostring(session.name or "?")
  if #name > 48 then
    name = string.sub(name, 1, 47) .. "…"
  end
  local where = basename(session.project)
  local value = ageText(session.last_active)
  if where ~= "" then
    value = where .. " · " .. value
  end
  return { key = name, value = value }
end

local function render()
  local live = status.active == true
  barWidget.setVisible(true)
  barWidget.setGlyph("sparkles")
  if live then
    barWidget.setGlyphColor("primary")
    barWidget.setText(tostring(status.count or 1))
    local rows = {}
    local sessions = status.sessions
    if type(sessions) ~= "table" then
      sessions = {}
    end
    for _, session in ipairs(sessions) do
      if type(session) == "table" and session.is_hot == true then
        table.insert(rows, sessionRow(session))
      end
      if #rows >= 8 then
        break
      end
    end
    if #rows == 0 then
      table.insert(rows, { key = noctalia.tr("tooltip.working"), value = tostring(status.count or 1) })
    end
    barWidget.setTooltip(rows)
  else
    -- Idle but present: dim tile keeps the live-session count so open
    -- agents stay visible; lit + count means actually working.
    local idle = liveSessions()
    barWidget.setGlyphColor("on_surface_variant")
    if #idle > 0 and showIdle then
      barWidget.setText(tostring(#idle))
      local rows = {}
      for _, session in ipairs(idle) do
        table.insert(rows, sessionRow(session))
        if #rows >= 8 then
          break
        end
      end
      barWidget.setTooltip(rows)
    else
      barWidget.setText("")
      barWidget.setTooltip(noctalia.tr("tooltip.idle"))
    end
    if not showIdle and #idle == 0 then
      barWidget.setVisible(false)
    end
  end
end

noctalia.state.watch("status", function(value)
  if type(value) == "table" then
    status = value
  else
    status = { active = false, count = 0, hot = {}, sessions = {} }
  end
  render()
end)

function update()
  noctalia.setUpdateInterval(5000)
  render()
end

function onClick()
  noctalia.togglePanel("fel/agent-glow:status")
end

render()
