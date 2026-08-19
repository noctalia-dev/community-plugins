--!nonstrict
-- /opn launcher for OPNsense.

local STATE_KEY = "opn_snapshot"
local COMMAND_KEY = "opn_command"
local PANEL_ID = "davemhammer/opnsense:manager"
local MAX_ROWS = 40

local snapshot = noctalia.state.get(STATE_KEY) or {
  available = false,
  configured = false,
  loading = true,
  widgets = {},
  interfaces = {},
  gateways = {},
  services = {},
  issueCount = 0,
  host = "",
  error = "",
}

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
  end
end)

local function trim(s)
  return noctalia.string.trim(tostring(s or ""))
end

local function lower(s)
  return string.lower(tostring(s or ""))
end

local function send(action, values)
  local command = { action = action, requestId = "launcher-" .. tostring(os.time()) }
  if type(values) == "table" then
    for k, v in pairs(values) do command[k] = v end
  end
  noctalia.state.set(COMMAND_KEY, command)
end

local function scoreText(filter, ...)
  if filter == "" then return 1 end
  local best = nil
  for i = 1, select("#", ...) do
    local text = tostring(select(i, ...) or "")
    if text ~= "" then
      local s = noctalia.fuzzyScore(filter, text)
      if s ~= nil and (best == nil or s > best) then best = s end
      if best == nil and lower(text):find(lower(filter), 1, true) then best = 0.5 end
    end
  end
  return best
end

local function statusRow(title, subtitle, glyph)
  return { id = "", title = title, subtitle = subtitle, glyph = glyph or "shield" }
end

local function topCategories()
  return {
    { id = "cat:status", title = noctalia.tr("launcher.cat.status"), subtitle = noctalia.tr("launcher.cat.status-sub"), glyph = "heart-rate-monitor", score = 100 },
    { id = "cat:interfaces", title = noctalia.tr("launcher.cat.interfaces"), subtitle = noctalia.tr("launcher.cat.interfaces-sub"), glyph = "network", score = 90 },
    { id = "cat:gateways", title = noctalia.tr("launcher.cat.gateways"), subtitle = noctalia.tr("launcher.cat.gateways-sub"), glyph = "router", score = 85 },
    { id = "cat:services", title = noctalia.tr("launcher.cat.services"), subtitle = noctalia.tr("launcher.cat.services-sub"), glyph = "settings", score = 80 },
    { id = "cat:rules", title = noctalia.tr("launcher.cat.rules"), subtitle = noctalia.tr("launcher.cat.rules-sub"), glyph = "list-check", score = 75 },
    { id = "cat:logs", title = noctalia.tr("launcher.cat.logs"), subtitle = noctalia.tr("launcher.cat.logs-sub"), glyph = "file-text", score = 72 },
    { id = "act:panel", title = noctalia.tr("launcher.cat.panel"), subtitle = noctalia.tr("launcher.cat.panel-sub"), glyph = "layout-dashboard", score = 70 },
    { id = "act:ui", title = noctalia.tr("launcher.cat.ui"), subtitle = noctalia.tr("launcher.cat.ui-sub"), glyph = "external-link", score = 60 },
    { id = "act:refresh", title = noctalia.tr("launcher.cat.refresh"), subtitle = noctalia.tr("launcher.cat.refresh-sub"), glyph = "refresh", score = 50 },
  }
end

local function listStatus(filter)
  local rows = {}
  for _, w in ipairs(snapshot.widgets or {}) do
    local s = scoreText(filter, w.name, w.status, w.message)
    if s ~= nil then
      table.insert(rows, {
        id = "st:" .. w.id,
        title = w.name,
        subtitle = w.status .. (w.message ~= "" and (" · " .. w.message) or ""),
        glyph = w.ok and "circle-check" or "circle-x",
        score = s,
      })
    end
  end
  if #rows == 0 then rows[1] = statusRow(noctalia.tr("launcher.no-matches"), filter, "search") end
  return rows
end

local function listIfaces(filter)
  local rows = {}
  for _, i in ipairs(snapshot.interfaces or {}) do
    local s = scoreText(filter, i.name, i.description, i.status, i.ipv4)
    if s ~= nil then
      table.insert(rows, {
        id = "if:" .. i.id,
        title = i.name,
        subtitle = `{i.status} · {i.ipv4}`,
        glyph = "network",
        score = s,
      })
    end
  end
  if #rows == 0 then rows[1] = statusRow(noctalia.tr("launcher.no-matches"), filter, "search") end
  return rows
end

local function listGateways(filter)
  local rows = {}
  for _, g in ipairs(snapshot.gateways or {}) do
    local s = scoreText(filter, g.name, g.status, g.address)
    if s ~= nil then
      table.insert(rows, {
        id = "gw:" .. g.id,
        title = g.name,
        subtitle = `{g.status} · {g.address}`,
        glyph = "router",
        score = s,
      })
    end
  end
  if #rows == 0 then rows[1] = statusRow(noctalia.tr("launcher.no-matches"), filter, "search") end
  return rows
end

local function serviceActions(name)
  return {
    { id = "svcact:restart:" .. name, title = noctalia.tr("launcher.action.restart"), subtitle = name, glyph = "refresh", score = 100 },
    { id = "svcact:start:" .. name, title = noctalia.tr("launcher.action.start"), subtitle = name, glyph = "player-play", score = 90 },
    { id = "svcact:stop:" .. name, title = noctalia.tr("launcher.action.stop"), subtitle = name, glyph = "player-stop", score = 80 },
    { id = "svcact:copy:" .. name, title = noctalia.tr("launcher.action.copy"), subtitle = name, glyph = "copy", score = 70 },
  }
end

local function listServices(filter)
  local rows = {}
  for _, s in ipairs(snapshot.services or {}) do
    local sc = scoreText(filter, s.name, s.status, s.description)
    if sc ~= nil then
      table.insert(rows, {
        id = "svc:" .. s.id,
        title = s.name,
        subtitle = s.status .. (s.description ~= "" and (" · " .. s.description) or ""),
        glyph = s.running and "player-play" or "player-stop",
        score = sc,
      })
    end
  end
  table.sort(rows, function(a, b) return (a.score or 0) > (b.score or 0) end)
  while #rows > MAX_ROWS do table.remove(rows) end
  if #rows == 0 then rows[1] = statusRow(noctalia.tr("launcher.no-matches"), filter, "search") end
  return rows
end

local function findService(name)
  name = trim(name)
  for _, s in ipairs(snapshot.services or {}) do
    if s.name == name or s.id == name then return s end
  end
  local hits = {}
  local q = lower(name)
  for _, s in ipairs(snapshot.services or {}) do
    if lower(s.name):find(q, 1, true) then table.insert(hits, s) end
  end
  if #hits == 1 then return hits[1] end
  return nil
end

function onQuery(query)
  if not snapshot.configured then
    launcher.setResults(query, {
      statusRow(noctalia.tr("panel.not_configured"), "", "settings"),
      { id = "act:panel", title = noctalia.tr("launcher.cat.panel"), subtitle = "Configure in plugin settings", glyph = "layout-dashboard" },
    })
    return
  end

  if snapshot.loading and not snapshot.available then
    send("refresh")
    launcher.setResults(query, { statusRow(noctalia.tr("launcher.loading"), snapshot.host, "loader") })
    return
  end

  if not snapshot.available then
    launcher.setResults(query, {
      statusRow(noctalia.tr("launcher.unavailable"), snapshot.error or "", "cloud-off"),
      { id = "act:refresh", title = noctalia.tr("launcher.cat.refresh"), subtitle = "", glyph = "refresh" },
    })
    return
  end

  local text = trim(query)
  if text == "" then
    launcher.setResults(query, topCategories())
    return
  end

  local tokens = {}
  for t in text:gmatch("%S+") do table.insert(tokens, t) end
  local head = lower(tokens[1] or "")
  local rest = table.concat(tokens, " ", 2)

  local function is(name, aliases)
    if head == name then return true end
    for _, a in ipairs(aliases) do if head == a then return true end end
    return false
  end

  if is("status", { "st", "health" }) then
    launcher.setResults(query, listStatus(rest))
    return
  end
  if is("interfaces", { "iface", "if", "int" }) then
    launcher.setResults(query, listIfaces(rest))
    return
  end
  if is("gateways", { "gw", "gateway" }) then
    launcher.setResults(query, listGateways(rest))
    return
  end
  if is("services", { "svc", "service", "s" }) then
    local svc = findService(rest)
    if svc and (lower(rest) == lower(svc.name) or rest:find(svc.name, 1, true)) and rest ~= "" then
      if lower(rest) == lower(svc.name) then
        launcher.setResults(query, serviceActions(svc.name))
        return
      end
    end
    launcher.setResults(query, listServices(rest))
    return
  end

  local rows = {}
  for _, row in ipairs(topCategories()) do
    local s = scoreText(text, row.title, row.id)
    if s ~= nil then
      row.score = s
      table.insert(rows, row)
    end
  end
  for _, r in ipairs(listServices(text)) do
    if r.id ~= "" then table.insert(rows, r) end
  end
  if #rows == 0 then rows[1] = statusRow(noctalia.tr("launcher.no-matches"), text, "search") end
  launcher.setResults(query, rows)
end

function onActivate(id)
  if id == nil or id == "" then return end

  if id == "cat:status" then launcher.setQuery("status "); return end
  if id == "cat:interfaces" then launcher.setQuery("interfaces "); return end
  if id == "cat:gateways" then launcher.setQuery("gateways "); return end
  if id == "cat:services" then launcher.setQuery("services "); return end
  if id == "cat:rules" then noctalia.togglePanel(PANEL_ID); return end
  if id == "cat:logs" then noctalia.togglePanel(PANEL_ID); return end

  if id == "act:panel" then noctalia.togglePanel(PANEL_ID); return end
  if id == "act:ui" then send("open_ui"); return end
  if id == "act:refresh" then
    send("refresh")
    noctalia.notify(noctalia.tr("title"), noctalia.tr("widget.refresh_requested"))
    return
  end

  local svc = id:match("^svc:(.+)$")
  if svc then
    launcher.setQuery("services " .. svc .. " ")
    return
  end

  local act, name = id:match("^svcact:([%w]+):(.+)$")
  if act and name then
    if act == "restart" then send("restart_service", { name = name })
    elseif act == "start" then send("start_service", { name = name })
    elseif act == "stop" then send("stop_service", { name = name })
    elseif act == "copy" then send("copy", { name = name })
    end
    return
  end

  local st = id:match("^st:(.+)$")
  if st then send("copy", { name = st }); return end
  local iface = id:match("^if:(.+)$")
  if iface then send("copy", { name = iface }); return end
  local gw = id:match("^gw:(.+)$")
  if gw then send("copy", { name = gw }); return end
end
