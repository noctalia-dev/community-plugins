--!nonstrict
-- Agent Glow session panel — real session names, projects, and freshness.
-- Opened by clicking the bar tile.

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
  if age < 3600 then
    return `{math.floor(age / 60)}m ago`
  end
  return `{math.floor(age / 3600)}h ago`
end

local function shortName(name)
  if type(name) ~= "string" or name == "" then
    return "?"
  end
  if #name > 54 then
    return string.sub(name, 1, 53) .. "…"
  end
  return name
end

local function render()
  local sessions = status.sessions
  if type(sessions) ~= "table" then
    sessions = {}
  end

  -- Only working sessions belong here; idle shows the empty state below.
  local ordered = {}
  for _, session in ipairs(sessions) do
    if type(session) == "table" and session.is_hot == true then
      table.insert(ordered, session)
    end
  end
  table.sort(ordered, function(a, b)
    return (tonumber(a.last_active) or 0) > (tonumber(b.last_active) or 0)
  end)

  if #ordered == 0 then
    panel.render(ui.column({ gap = 10, align = "center" }, {
      ui.glyph({ name = "sparkles", color = "on_surface_variant", size = 28 }),
      ui.label({ text = noctalia.tr("panel.idle"), color = "on_surface_variant", fontSize = 14 }),
    }))
    return
  end

  local nodes = {}
  for _, session in ipairs(ordered) do
    local hot = session.is_hot == true
    local family = tostring(session.family or "?")
    local project = session.project
    if type(project) ~= "string" then
      project = ""
    end
    local detail = `{family} · {ageText(session.last_active)}`
    local projectBase = basename(project)
    if projectBase ~= "" then
      detail ..= ` · {projectBase}`
    end
    local cpu = tonumber(session.cpu) or 0
    if cpu >= 1 then
      detail ..= ` · {string.format("%.0f", cpu)}%`
    end
    table.insert(nodes, ui.column({ gap = 2 }, {
      ui.label({
        text = shortName(session.name),
        color = hot and "on_surface" or "on_surface_variant",
        fontSize = 13,
        fontWeight = hot and "bold" or "normal",
        maxLines = 1,
        maxWidth = 440,
      }),
      ui.label({
        text = detail,
        color = hot and "primary" or "on_surface_variant",
        fontSize = 12,
        maxLines = 1,
        maxWidth = 440,
      }),
    }))
  end

  panel.render(ui.column({ gap = 12 }, nodes))
end

noctalia.state.watch("status", function(value)
  if type(value) == "table" then
    status = value
  else
    status = { active = false, count = 0, hot = {}, sessions = {} }
  end
  render()
end)

function onOpen()
  local current = noctalia.state.get("status")
  if type(current) == "table" then
    status = current
  end
  render()
end

render()
