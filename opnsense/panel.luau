--!nonstrict
-- OPNsense manager panel.

local STATE_KEY = "opn_snapshot"
local COMMAND_KEY = "opn_command"
local RESULT_KEY = "opn_action_result"

local snapshot = noctalia.state.get(STATE_KEY) or {
  available = false,
  configured = false,
  loading = true,
  busy = false,
  host = "",
  error = "",
  instances = {},
  issueCount = 0,
  okCount = 0,
  updatedAt = 0,
  revision = 0,
}

-- Blank slice used before a firewall is selected and when none is configured.
local EMPTY_VIEW = {
  id = "",
  name = "",
  host = "",
  available = false,
  loading = false,
  logsLoading = false,
  error = "",
  widgets = {},
  interfaces = {},
  gateways = {},
  services = {},
  rules = {},
  logs = {},
  info = {},
  resources = {},
  issueCount = 0,
  okCount = 0,
  blockLogCount = 0,
  updatedAt = 0,
}

local view = EMPTY_VIEW

local tab = "overview"
local tabTouched = false
local instanceId = ""
local selectedId = ""
local filterText = ""
local filterKey = 0
local requestCounter = 0
local feedback = ""
local feedbackError = false
local dirty = true

local render

local function instanceList()
  return type(snapshot.instances) == "table" and snapshot.instances or {}
end

local function instanceById(id)
  for _, inst in ipairs(instanceList()) do
    if inst.id == id then
      return inst
    end
  end
  return nil
end

local function selectedInstance()
  return instanceById(instanceId) or instanceList()[1]
end

local function syncView()
  local inst = selectedInstance()
  if inst == nil then
    instanceId = ""
    view = EMPTY_VIEW
    return
  end
  instanceId = inst.id
  view = inst
end

local function instanceIssues(inst)
  local n = tonumber(inst.issueCount) or 0
  if inst.available ~= true then
    n += 1
  end
  return n
end

local function selectInstance(id)
  if instanceById(id) == nil then
    return
  end
  instanceId = id
  selectedId = ""
  filterKey += 1
  syncView()
  dirty = true
end

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function nextRequestId()
  requestCounter += 1
  return `panel-{requestCounter}`
end

local function send(action, values)
  local command = { action = action, requestId = nextRequestId() }
  if type(values) == "table" then
    for k, v in pairs(values) do
      command[k] = v
    end
  end
  noctalia.state.set(COMMAND_KEY, command)
  return command.requestId
end

local function lower(s)
  return string.lower(tostring(s or ""))
end

local function haystackContains(needle, ...)
  if needle == "" then return true end
  for i = 1, select("#", ...) do
    local part = lower(select(i, ...))
    if part ~= "" and part:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local function matchesFilter(...)
  local q = noctalia.string.trim(filterText)
  if q == "" then return true end
  for raw in q:gmatch("%S+") do
    local neg = false
    local term = raw
    if term:sub(1, 1) == "!" then
      neg = true
      term = term:sub(2)
    end
    term = lower(term)
    if term ~= "" then
      local hit = haystackContains(term, ...)
      if neg then
        if hit then return false end
      else
        if not hit then return false end
      end
    end
  end
  return true
end

local function statusColor(ok)
  return ok and "tertiary" or "error"
end

local function listButton(props)
  props.contentAlign = "start"
  props.controlSize = props.controlSize or "md"
  return ui.button(props)
end

local function selectedService()
  if tab ~= "services" then return nil end
  for _, s in ipairs(view.services or {}) do
    if s.id == selectedId then return s end
  end
  return nil
end

local function selectedIface()
  if tab ~= "interfaces" then return nil end
  for _, i in ipairs(view.interfaces or {}) do
    if i.id == selectedId then return i end
  end
  return nil
end

local function selectedGw()
  if tab ~= "gateways" then return nil end
  for _, g in ipairs(view.gateways or {}) do
    if g.id == selectedId then return g end
  end
  return nil
end

local function selectedWidget()
  if tab ~= "status" then return nil end
  for _, w in ipairs(view.widgets or {}) do
    if w.id == selectedId then return w end
  end
  return nil
end

local function selectedRule()
  if tab ~= "rules" then return nil end
  for _, r in ipairs(view.rules or {}) do
    if r.id == selectedId then return r end
  end
  return nil
end

local function selectedLog()
  if tab ~= "logs" then return nil end
  for _, l in ipairs(view.logs or {}) do
    if l.id == selectedId then return l end
  end
  return nil
end

local function emptyList(msg)
  return ui.column({
    key = "empty-" .. tab,
    align = "center",
    justify = "center",
    padding = 24,
    gap = 8,
    flexGrow = 1,
  }, {
    ui.glyph({ name = "search", size = 36, color = "on_surface_variant" }),
    ui.label({ text = msg, color = "on_surface_variant", textAlign = "center" }),
  })
end

local function itemColumn(rows)
  return ui.column({
    key = "items-" .. tab,
    align = "stretch",
    justify = "start",
    gap = 8,
    flexGrow = 1,
  }, rows)
end

local function statusRows()
  local rows = {}
  for _, w in ipairs(view.widgets or {}) do
    if matchesFilter(w.name, w.status, w.message) then
      local selected = w.id == selectedId
      table.insert(rows, listButton({
        key = "st-" .. w.id,
        text = `{w.name}  ·  {w.status}` .. (w.message ~= "" and (`  ·  {w.message}`) or ""),
        glyph = w.ok and "circle-check" or "circle-x",
        variant = selected and "primary" or "outline",
        selected = selected,
        onClick = function()
          selectedId = w.id
          feedback = ""
          render()
        end,
      }))
    end
  end
  return rows
end

local function ifaceRows()
  local rows = {}
  for _, i in ipairs(view.interfaces or {}) do
    if matchesFilter(i.name, i.description, i.status, i.ipv4) then
      local selected = i.id == selectedId
      local label = i.description ~= "" and (`{i.name} ({i.description})`) or i.name
      table.insert(rows, listButton({
        key = "if-" .. i.id,
        text = `{label}  ·  {i.status}  ·  {i.ipv4}  ·  ↓{i.inBytes} ↑{i.outBytes}`,
        glyph = "network",
        variant = selected and "primary" or "outline",
        selected = selected,
        onClick = function()
          selectedId = i.id
          feedback = ""
          render()
        end,
      }))
    end
  end
  return rows
end

local function gwRows()
  local rows = {}
  for _, g in ipairs(view.gateways or {}) do
    if matchesFilter(g.name, g.status, g.address, g.rtt) then
      local selected = g.id == selectedId
      table.insert(rows, listButton({
        key = "gw-" .. g.id,
        text = `{g.name}  ·  {g.status}  ·  {g.address}  ·  rtt {g.rtt}`,
        glyph = "router",
        variant = selected and "primary" or "outline",
        selected = selected,
        onClick = function()
          selectedId = g.id
          feedback = ""
          render()
        end,
      }))
    end
  end
  return rows
end

local function serviceRows()
  local rows = {}
  for _, s in ipairs(view.services or {}) do
    if matchesFilter(s.name, s.status, s.description) then
      local selected = s.id == selectedId
      table.insert(rows, listButton({
        key = "svc-" .. s.id,
        text = `{s.name}  ·  {s.status}` .. (s.description ~= "" and (`  ·  {s.description}`) or ""),
        glyph = s.running and "player-play" or "player-stop",
        variant = selected and "primary" or "outline",
        selected = selected,
        onClick = function()
          selectedId = s.id
          feedback = ""
          render()
        end,
      }))
    end
  end
  return rows
end

local function ruleRows()
  local rows = {}
  for _, r in ipairs(view.rules or {}) do
    if matchesFilter(
      r.description, r.action, r.direction, r.source, r.destination,
      r.protocol, r.interface, r.enabled and "enabled" or "disabled",
      r.automatic and "automatic" or "manual"
    ) then
      local selected = r.id == selectedId
      local en = r.enabled and "" or " [off]"
      local auto = r.automatic and " auto" or ""
      local text = `{r.action}{en}{auto}  ·  {r.direction}  ·  {r.description}  ·  {r.source} → {r.destination}`
      table.insert(rows, listButton({
        key = "rule-" .. r.id,
        text = text,
        glyph = lower(r.action) == "block" and "ban" or "shield-check",
        variant = selected and "primary" or "outline",
        selected = selected,
        onClick = function()
          selectedId = r.id
          feedback = ""
          render()
        end,
      }))
    end
  end
  return rows
end

local function logRows()
  local rows = {}
  for _, l in ipairs(view.logs or {}) do
    if matchesFilter(
      l.action, l.direction, l.interface, l.protocol,
      l.src, l.dst, l.label, l.time
    ) then
      local selected = l.id == selectedId
      local text = `{l.time}  ·  {l.action} {l.direction}  ·  {l.interface}  ·  {l.protocol}  ·  {l.src} → {l.dst}`
      table.insert(rows, listButton({
        key = "log-" .. l.id,
        text = text,
        glyph = l.blocked and "ban" or "arrow-right",
        variant = selected and "primary" or "outline",
        selected = selected,
        onClick = function()
          selectedId = l.id
          feedback = ""
          render()
        end,
      }))
    end
  end
  return rows
end

-- One row per firewall: the "all firewalls" view.
local function overviewRows()
  local rows = {}
  for _, inst in ipairs(instanceList()) do
    local issues = instanceIssues(inst)
    local ok = inst.available == true and issues == 0
    local status
    if inst.available ~= true then
      status = tr("panel.instance_down", { error = inst.error ~= "" and inst.error or "unknown" })
    elseif issues > 0 then
      status = tr("panel.instance_issues", { n = issues })
    else
      status = tr("panel.instance_ok")
    end
    local selected = inst.id == instanceId
    table.insert(rows, listButton({
      key = "fw-" .. inst.id,
      text = `{inst.name}  ·  {inst.host}  ·  {status}`,
      glyph = ok and "shield-check" or "shield-x",
      variant = selected and "primary" or "outline",
      selected = selected,
      onClick = function()
        selectInstance(inst.id)
        tab = "status"
        render()
      end,
    }))
  end
  return rows
end

-- Firewall picker; only worth showing once more than one is configured.
local function instanceSwitcher()
  local list = instanceList()
  local buttons = {}
  for _, inst in ipairs(list) do
    local issues = instanceIssues(inst)
    table.insert(buttons, ui.button({
      text = issues > 0 and `{inst.name} ({issues})` or inst.name,
      selected = inst.id == instanceId,
      variant = inst.id == instanceId and "primary" or "ghost",
      onClick = function()
        selectInstance(inst.id)
        render()
      end,
    }))
  end
  return ui.row({
    gap = 4,
    align = "center",
    visible = #list > 1,
  }, buttons)
end

local function itemList()
  local rows
  if tab == "overview" then rows = overviewRows()
  elseif tab == "status" then rows = statusRows()
  elseif tab == "interfaces" then rows = ifaceRows()
  elseif tab == "gateways" then rows = gwRows()
  elseif tab == "services" then rows = serviceRows()
  elseif tab == "rules" then rows = ruleRows()
  else rows = logRows()
  end
  if #rows == 0 then
    return emptyList(tr("panel.empty"))
  end
  return itemColumn(rows)
end

local function toolbar()
  local busy = snapshot.busy == true
  if tab == "overview" then
    return ui.label({ text = tr("panel.overview_hint"), color = "on_surface_variant" })
  end
  if tab == "services" then
    local s = selectedService()
    if not s then
      return ui.label({ text = tr("panel.select_hint"), color = "on_surface_variant" })
    end
    return ui.column({ gap = 4, padding = 10, fill = "surface_variant/0.45", radius = 10, align = "stretch" }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = "settings", size = 18, color = s.running and "tertiary" or "on_surface_variant" }),
        ui.label({ text = s.name, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
        ui.label({ text = s.status, color = s.running and "tertiary" or "on_surface_variant", fontSize = 12 }),
      }),
      ui.label({
        text = s.description,
        color = "on_surface_variant",
        fontSize = 12,
        visible = s.description ~= "",
        maxLines = 2,
      }),
      ui.row({ gap = 6 }, {
        ui.button({ text = tr("actions.restart"), glyph = "refresh", variant = "primary", enabled = not busy, onClick = "onRestart" }),
        ui.button({ text = tr("actions.start"), glyph = "player-play", variant = "outline", enabled = not busy and not s.running, onClick = "onStart" }),
        ui.button({ text = tr("actions.stop"), glyph = "player-stop", variant = "outline", enabled = not busy and s.running, onClick = "onStop" }),
        ui.button({ text = tr("actions.copy"), glyph = "copy", variant = "ghost", onClick = "onCopyService" }),
      }),
    })
  end

  if tab == "rules" then
    local r = selectedRule()
    if not r then
      return ui.label({ text = tr("panel.select_hint"), color = "on_surface_variant" })
    end
    return ui.column({ gap = 4, padding = 10, fill = "surface_variant/0.45", radius = 10, align = "stretch" }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({
          name = lower(r.action) == "block" and "ban" or "shield-check",
          size = 18,
          color = lower(r.action) == "block" and "error" or "tertiary",
        }),
        ui.label({ text = r.description, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
        ui.label({
          text = `{r.action} · {r.direction}` .. (r.enabled and "" or " · off"),
          color = lower(r.action) == "block" and "error" or "tertiary",
          fontSize = 12,
        }),
      }),
      ui.label({
        text = tr("rule.detail", {
          src = r.source ~= "" and r.source or "any",
          dst = r.destination ~= "" and r.destination or "any",
          proto = r.protocol ~= "" and r.protocol or "any",
          iface = r.interface ~= "" and r.interface or "—",
        }),
        color = "on_surface_variant",
        fontSize = 12,
        maxLines = 2,
      }),
      ui.label({
        text = tr("rule.stats", {
          packets = r.packets,
          bytes = r.bytes,
          evaluations = r.evaluations,
        }),
        color = "on_surface_variant",
        fontSize = 11,
      }),
      ui.row({ gap = 6 }, {
        ui.button({ text = tr("actions.copy"), glyph = "copy", variant = "outline", onClick = "onCopyRule" }),
      }),
    })
  end

  if tab == "logs" then
    local l = selectedLog()
    if not l then
      return ui.label({
        text = tr("logs.hint", { n = #(view.logs or {}), blocks = view.blockLogCount or 0 }),
        color = "on_surface_variant",
      })
    end
    return ui.column({ gap = 4, padding = 10, fill = "surface_variant/0.45", radius = 10, align = "stretch" }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({
          name = l.blocked and "ban" or "arrow-right",
          size = 18,
          color = l.blocked and "error" or "tertiary",
        }),
        ui.label({
          text = `{l.action} {l.direction} · {l.protocol}`,
          fontWeight = "bold",
          flexGrow = 1,
          maxLines = 1,
        }),
        ui.label({ text = l.time, color = "on_surface_variant", fontSize = 12 }),
      }),
      ui.label({
        text = tr("logs.flow", { src = l.src, dst = l.dst, iface = l.interface }),
        color = "on_surface_variant",
        fontSize = 12,
        maxLines = 2,
      }),
      ui.label({
        text = l.label,
        color = "on_surface_variant",
        fontSize = 11,
        visible = l.label ~= "",
        maxLines = 2,
      }),
      ui.row({ gap = 6 }, {
        ui.button({ text = tr("actions.copy"), glyph = "copy", variant = "outline", onClick = "onCopyLog" }),
      }),
    })
  end

  local item = selectedWidget() or selectedIface() or selectedGw()
  if not item then
    return ui.label({ text = tr("panel.select_hint"), color = "on_surface_variant" })
  end
  local title = item.name or item.id
  local detail = item.message or item.description or item.address or ""
  return ui.column({ gap = 4, padding = 10, fill = "surface_variant/0.45", radius = 10, align = "stretch" }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "info-circle", size = 18, color = statusColor(item.ok ~= false) }),
      ui.label({ text = tostring(title), fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
      ui.label({
        text = tostring(item.status or ""),
        color = statusColor(item.ok ~= false),
        fontSize = 12,
      }),
    }),
    ui.label({
      text = tostring(detail),
      color = "on_surface_variant",
      fontSize = 12,
      visible = detail ~= "",
      maxLines = 3,
    }),
    ui.row({ gap = 6 }, {
      ui.button({ text = tr("actions.copy"), glyph = "copy", variant = "outline", onClick = "onCopySelected" }),
    }),
  })
end

local function tabButton(label, id, cb)
  return ui.button({
    text = label,
    selected = tab == id,
    variant = tab == id and "primary" or "ghost",
    onClick = cb,
  })
end

render = function()
  dirty = false
  local overview = tab == "overview"
  local notes = {}
  if not snapshot.configured then
    table.insert(notes, ui.label({ text = tr("panel.not_configured"), color = "error", maxLines = 3 }))
  end
  local loading = overview and snapshot.loading or view.loading
  if loading then
    table.insert(notes, ui.label({ text = tr("panel.loading"), color = "on_surface_variant" }))
  end
  if view.logsLoading and not overview then
    table.insert(notes, ui.label({ text = tr("panel.logs_loading"), color = "on_surface_variant" }))
  end
  if snapshot.busy then
    table.insert(notes, ui.label({ text = tr("panel.busy"), color = "primary" }))
  end
  local problem = overview and snapshot.error or view.error
  if type(problem) == "string" and problem ~= "" then
    table.insert(notes, ui.label({ text = problem, color = "error", maxLines = 3 }))
  end
  if feedback ~= "" then
    table.insert(notes, ui.label({
      text = feedback,
      color = feedbackError and "error" or "tertiary",
      maxLines = 2,
    }))
  end

  local load = ""
  if not overview and type(view.resources) == "table" then
    load = tostring(view.resources.load or "")
  end
  local summary = overview and tr("panel.summary", {
    ok = snapshot.okCount or 0,
    issues = snapshot.issueCount or 0,
    load = "—",
  }) or tr("panel.summary", {
    ok = view.okCount or 0,
    issues = view.issueCount or 0,
    load = load ~= "" and load or "—",
  })
  local version = ""
  if not overview and type(view.info) == "table" then
    version = tostring(view.info.version or "")
  end

  local titleIssues = overview and (snapshot.issueCount or 0) or (view.issueCount or 0)
  local up = overview and (snapshot.available == true) or (view.available == true)
  local titleIcon = "assets/opnsense-grey.png"
  if up == true then
    titleIcon = titleIssues == 0 and "assets/opnsense-orange.png" or "assets/opnsense-red.png"
  end

  panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
    ui.row({ align = "center", gap = 10 }, {
      ui.image({
        path = titleIcon,
        width = 28,
        height = 28,
        fit = "contain",
      }),
      ui.column({ flexGrow = 1, gap = 0 }, {
        ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold" }),
        ui.label({
          text = tr("panel.host", {
            host = overview and (snapshot.host ~= "" and snapshot.host or "—")
              or (view.host ~= "" and view.host or "—"),
          }) .. (version ~= "" and (` · {version}`) or ""),
          fontSize = 11,
          color = "on_surface_variant",
        }),
      }),
      ui.button({ text = tr("actions.open_ui"), glyph = "external-link", variant = "outline", onClick = "onOpenUi" }),
      ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefresh" }),
      ui.button({ glyph = "close", onClick = "onClose" }),
    }),

    ui.row({ gap = 4, align = "center" }, {
      tabButton(tr("tabs.overview"), "overview", "onTabOverview"),
      tabButton(tr("tabs.status"), "status", "onTabStatus"),
      tabButton(tr("tabs.interfaces"), "interfaces", "onTabInterfaces"),
      tabButton(tr("tabs.gateways"), "gateways", "onTabGateways"),
      tabButton(tr("tabs.services"), "services", "onTabServices"),
      tabButton(tr("tabs.rules"), "rules", "onTabRules"),
      tabButton(tr("tabs.logs"), "logs", "onTabLogs"),
    }),

    instanceSwitcher(),

    ui.label({
      text = summary .. (
        tab == "logs" and (` · {tr("logs.summary", { n = #(view.logs or {}), blocks = view.blockLogCount or 0 })}`)
        or (tab == "rules" and (` · {tr("rules.summary", { n = #(view.rules or {}) })}`) or "")
      ),
      color = "on_surface_variant",
      fontSize = 11,
      maxLines = 1,
    }),

    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = `filter-{tab}-{filterKey}`,
        value = filterText,
        placeholder = tr("filter.placeholder"),
        flexGrow = 1,
        controlSize = "sm",
        onChange = "onFilterChange",
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        visible = filterText ~= "",
        onClick = "onClearFilter",
      }),
    }),

    toolbar(),
    ui.column({ gap = 3, align = "stretch" }, notes),
    ui.scroll({
      key = "scroll-" .. tab,
      flexGrow = 1,
      gap = 8,
      align = "stretch",
    }, { itemList() }),
    ui.label({
      text = (view.updatedAt or 0) > 0
        and tr("panel.updated", { time = noctalia.formatTime("%H:%M:%S", view.updatedAt) })
        or (overview and (snapshot.updatedAt or 0) > 0
          and tr("panel.updated", { time = noctalia.formatTime("%H:%M:%S", snapshot.updatedAt) })
          or ""),
      color = "on_surface_variant",
      fontSize = 11,
    }),
  }))
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) ~= "table" then return end
  local previousRevision = snapshot.revision
  local previousBusy = snapshot.busy
  local previousHost = (selectedInstance() or {}).host
  local previousIssues = view.issueCount
  local previousBlocked = view.blockLogCount
  local previousLogs = #(view.logs or {})
  local previousRules = #(view.rules or {})

  snapshot = value
  syncView()

  local changed = value.revision ~= previousRevision
    or value.busy ~= previousBusy
    or view.host ~= previousHost
    or view.issueCount ~= previousIssues
    or view.blockLogCount ~= previousBlocked
    or #(view.logs or {}) ~= previousLogs
    or #(view.rules or {}) ~= previousRules
  if selectedId ~= "" then
    if not (selectedWidget() or selectedIface() or selectedGw() or selectedService()
      or selectedRule() or selectedLog()) then
      selectedId = ""
    end
  end
  if changed then dirty = true end
end)

noctalia.state.watch(RESULT_KEY, function(result)
  if type(result) ~= "table" then return end
  if type(result.requestId) ~= "string" or not result.requestId:match("^panel%-") then return end
  feedback = tostring(result.message or "")
  feedbackError = result.ok ~= true
  dirty = true
end)

panel.setWantsSecondTicks(true)

function onOpen(_context)
  feedback = ""
  if not tabTouched and #instanceList() <= 1 then
    tab = "status"
  end
  syncView()
  send("refresh")
  render()
end

function update()
  if dirty then render() end
end

function onClose() panel.close() end
function onRefresh()
  send("refresh")
  if tab == "logs" then
    send("fetch_logs", { instance = instanceId })
  end
end
function onOpenUi() send("open_ui", { instance = instanceId }) end

local function switchTab(next)
  tab = next
  tabTouched = true
  selectedId = ""
  filterKey += 1
  render()
end

function onTabOverview() switchTab("overview") end
function onTabStatus() switchTab("status") end
function onTabInterfaces() switchTab("interfaces") end
function onTabGateways() switchTab("gateways") end
function onTabServices() switchTab("services") end
function onTabRules() switchTab("rules") end
function onTabLogs()
  switchTab("logs")
  -- Logs are large; fetch only when viewing the Logs tab.
  if not view.logsLoading then
    send("fetch_logs", { instance = instanceId })
  end
end

function onFilterChange(value)
  filterText = if type(value) == "string" then value else ""
  render()
end

function onClearFilter()
  filterText = ""
  filterKey += 1
  render()
end

function onRestart()
  local s = selectedService()
  if s then send("restart_service", { name = s.name, instance = instanceId }) end
end
function onStart()
  local s = selectedService()
  if s then send("start_service", { name = s.name, instance = instanceId }) end
end
function onStop()
  local s = selectedService()
  if s then send("stop_service", { name = s.name, instance = instanceId }) end
end
function onCopyService()
  local s = selectedService()
  if s then send("copy", { name = s.name }) end
end
function onCopySelected()
  local item = selectedWidget() or selectedIface() or selectedGw()
  if item then send("copy", { name = item.name or item.id }) end
end
function onCopyRule()
  local r = selectedRule()
  if r then
    send("copy", {
      name = `{r.action} {r.direction} {r.description} {r.source} -> {r.destination}`,
    })
  end
end
function onCopyLog()
  local l = selectedLog()
  if l then
    send("copy", {
      name = `{l.time} {l.action} {l.direction} {l.interface} {l.protocol} {l.src} -> {l.dst} {l.label}`,
    })
  end
end
