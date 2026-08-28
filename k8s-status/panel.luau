--!nonstrict
-- K8s Status panel: nodes, pods, deployments, namespaces.

local STATE_KEY = "k8s_snapshot"
local COMMAND_KEY = "k8s_command"
local RESULT_KEY = "k8s_action_result"

local snapshot = noctalia.state.get(STATE_KEY) or {
  available = false,
  loading = true,
  busy = false,
  context = "",
  nodes = {},
  pods = {},
  deployments = {},
  namespaces = {},
  readyNodes = 0,
  nodeCount = 0,
  problemPods = 0,
  podCount = 0,
  error = "",
  updatedAt = 0,
  revision = 0,
}

local tab = "nodes" -- nodes | pods | deploys | namespaces
local selectedId = ""
local problemsOnly = noctalia.getConfig("problems_only") == true
local filterText = ""
local filterKey = 0
local requestCounter = 0
local feedback = ""
local feedbackError = false
local dirty = true

-- Prefer neutral cluster icons (avoid missing glyphs / grim fallbacks)
local ICON_MAIN = "hexagon"
local ICON_NODE = "server"
local ICON_POD = "box"
local ICON_POD_BAD = "circle-x"
local ICON_DEPLOY = "packages"
local ICON_NS = "folder"

local render

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function nextRequestId()
  requestCounter += 1
  return `panel-{requestCounter}`
end

local function sendCommand(action, values)
  local command = {
    action = action,
    requestId = nextRequestId(),
  }
  if type(values) == "table" then
    for key, value in pairs(values) do
      command[key] = value
    end
  end
  noctalia.state.set(COMMAND_KEY, command)
  return command.requestId
end

local function lower(s)
  return string.lower(tostring(s or ""))
end

local function haystackContains(needle, ...)
  if needle == "" then
    return true
  end
  for i = 1, select("#", ...) do
    local part = lower(select(i, ...))
    if part ~= "" and part:find(needle, 1, true) then
      return true
    end
  end
  return false
end

-- Space-separated terms; prefix a term with ! to exclude matches.
-- Examples:  !Running   gitea !Completed   !Ready
local function matchesFilter(...)
  local q = noctalia.string.trim(filterText)
  if q == "" then
    return true
  end
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
        if hit then
          return false
        end
      else
        if not hit then
          return false
        end
      end
    end
  end
  return true
end

local function selectedNode()
  if tab ~= "nodes" then return nil end
  for _, n in ipairs(snapshot.nodes or {}) do
    if n.id == selectedId then return n end
  end
  return nil
end

local function selectedPod()
  if tab ~= "pods" then return nil end
  for _, p in ipairs(snapshot.pods or {}) do
    if p.id == selectedId then return p end
  end
  return nil
end

local function selectedDeploy()
  if tab ~= "deploys" then return nil end
  for _, d in ipairs(snapshot.deployments or {}) do
    if d.id == selectedId then return d end
  end
  return nil
end

local function selectedNs()
  if tab ~= "namespaces" then return nil end
  for _, n in ipairs(snapshot.namespaces or {}) do
    if n.id == selectedId then return n end
  end
  return nil
end

local function statusColor(ok)
  return ok and "tertiary" or "error"
end

local function listButton(props)
  -- Full-width list rows, left-aligned content (never centered chips).
  props.contentAlign = "start"
  props.controlSize = props.controlSize or "md"
  return ui.button(props)
end

local function nodeCard(node)
  local selected = node.id == selectedId
  local text = `{node.name}  ·  {node.status}  ·  {node.version}  ·  {node.ip}`
  return listButton({
    key = "node-" .. node.id,
    text = text,
    glyph = ICON_NODE,
    variant = selected and "primary" or "outline",
    selected = selected,
    onClick = function()
      selectedId = node.id
      feedback = ""
      render()
    end,
  })
end

local function podCard(pod)
  local selected = pod.id == selectedId
  local text = `{pod.namespace}/{pod.name}  ·  {pod.ready}  ·  {pod.status}  ·  r{pod.restarts}`
  return listButton({
    key = "pod-" .. pod.id,
    text = text,
    glyph = pod.problem and ICON_POD_BAD or ICON_POD,
    variant = selected and "primary" or "outline",
    selected = selected,
    onClick = function()
      selectedId = pod.id
      feedback = ""
      render()
    end,
  })
end

local function deployCard(dep)
  local selected = dep.id == selectedId
  local text = `{dep.namespace}/{dep.name}  ·  {dep.ready}/{dep.desired}`
  return listButton({
    key = "deploy-" .. dep.id,
    text = text,
    glyph = ICON_DEPLOY,
    variant = selected and "primary" or "outline",
    selected = selected,
    onClick = function()
      selectedId = dep.id
      feedback = ""
      render()
    end,
  })
end

local function nsCard(ns)
  local selected = ns.id == selectedId
  return listButton({
    key = "ns-" .. ns.id,
    text = `{ns.name}  ·  {ns.phase}`,
    glyph = ICON_NS,
    variant = selected and "primary" or "outline",
    selected = selected,
    onClick = function()
      selectedId = ns.id
      feedback = ""
      render()
    end,
  })
end

local function toolbar()
  local busy = snapshot.busy == true
  if tab == "nodes" then
    local node = selectedNode()
    if not node then
      return ui.label({ text = tr("panel.select_hint"), color = "on_surface_variant" })
    end
    return ui.column({ gap = 4, padding = 10, fill = "surface_variant/0.45", radius = 10 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = ICON_NODE, size = 18, color = statusColor(node.ready) }),
        ui.label({ text = node.name, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
        ui.label({ text = node.status, color = statusColor(node.ready), fontSize = 12 }),
      }),
      ui.label({ text = tr("node.version", { version = node.version }), color = "on_surface_variant", fontSize = 12 }),
      ui.label({ text = tr("node.ip", { ip = node.ip }), color = "on_surface_variant", fontSize = 12 }),
      ui.row({ gap = 6 }, {
        ui.button({
          text = tr("actions.describe"),
          glyph = "file-description",
          variant = "outline",
          enabled = not busy,
          onClick = "onDescribeNode",
        }),
      }),
    })
  end

  if tab == "pods" then
    local pod = selectedPod()
    if not pod then
      return ui.label({ text = tr("panel.select_hint"), color = "on_surface_variant" })
    end
    return ui.column({ gap = 4, padding = 10, fill = "surface_variant/0.45", radius = 10 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = ICON_POD, size = 18, color = statusColor(not pod.problem) }),
        ui.label({ text = `{pod.namespace}/{pod.name}`, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
        ui.label({ text = pod.status, color = statusColor(not pod.problem), fontSize = 12 }),
      }),
      ui.label({
        text = `{pod.ready} · {tr("pod.restarts", { count = pod.restarts })}`,
        color = "on_surface_variant",
        fontSize = 12,
      }),
      ui.label({
        text = pod.node ~= "" and tr("pod.node", { node = pod.node }) or "",
        color = "on_surface_variant",
        fontSize = 12,
        visible = pod.node ~= "",
      }),
      ui.row({ gap = 6 }, {
        ui.button({ text = tr("actions.logs"), glyph = "file-text", variant = "primary", enabled = not busy, onClick = "onLogs" }),
        ui.button({ text = tr("actions.describe"), glyph = "file-description", variant = "outline", enabled = not busy, onClick = "onDescribePod" }),
        ui.button({ text = tr("actions.delete_pod"), glyph = "trash", variant = "destructive", enabled = not busy, onClick = "onDeletePod" }),
      }),
    })
  end

  if tab == "deploys" then
    local dep = selectedDeploy()
    if not dep then
      return ui.label({ text = tr("panel.select_hint"), color = "on_surface_variant" })
    end
    return ui.column({ gap = 4, padding = 10, fill = "surface_variant/0.45", radius = 10 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = ICON_DEPLOY, size = 18, color = statusColor(not dep.problem) }),
        ui.label({ text = `{dep.namespace}/{dep.name}`, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
        ui.label({
          text = tr("deploy.replicas", { ready = dep.ready, desired = dep.desired }),
          color = statusColor(not dep.problem),
          fontSize = 12,
        }),
      }),
      ui.row({ gap = 6 }, {
        ui.button({ text = tr("actions.restart"), glyph = "refresh", variant = "primary", enabled = not busy, onClick = "onRestart" }),
        ui.button({ text = tr("actions.describe"), glyph = "file-description", variant = "outline", enabled = not busy, onClick = "onDescribeDeploy" }),
      }),
    })
  end

  local ns = selectedNs()
  if not ns then
    return ui.label({ text = tr("panel.select_hint"), color = "on_surface_variant" })
  end
  return ui.column({ gap = 4, padding = 10, fill = "surface_variant/0.45", radius = 10 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = ICON_NS, size = 18, color = "primary" }),
      ui.label({ text = ns.name, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
      ui.label({ text = tr("ns.phase", { phase = ns.phase }), color = "on_surface_variant", fontSize = 12 }),
    }),
    ui.row({ gap = 6 }, {
      ui.button({ text = tr("actions.describe"), glyph = "file-description", variant = "outline", enabled = not busy, onClick = "onDescribeNs" }),
    }),
  })
end

local function filteredNodes()
  local out = {}
  for _, n in ipairs(snapshot.nodes or {}) do
    if matchesFilter(n.name, n.status, n.version, n.ip, n.roles) then
      table.insert(out, n)
    end
  end
  return out
end

local function filteredPods()
  local out = {}
  for _, p in ipairs(snapshot.pods or {}) do
    if (not problemsOnly or p.problem)
      and matchesFilter(p.namespace, p.name, p.status, p.node, p.ready, p.id)
    then
      table.insert(out, p)
    end
  end
  return out
end

local function filteredDeploys()
  local out = {}
  for _, d in ipairs(snapshot.deployments or {}) do
    if matchesFilter(d.namespace, d.name, d.id, tostring(d.ready), tostring(d.desired)) then
      table.insert(out, d)
    end
  end
  return out
end

local function filteredNamespaces()
  local out = {}
  for _, n in ipairs(snapshot.namespaces or {}) do
    if matchesFilter(n.name, n.phase) then
      table.insert(out, n)
    end
  end
  return out
end

local function emptyList(message)
  -- Distinct key from the item list so align="center" is never retained on results.
  return ui.column({
    key = "empty-" .. tab,
    align = "center",
    justify = "center",
    padding = 24,
    gap = 8,
    flexGrow = 1,
  }, {
    ui.glyph({ name = "search", size = 36, color = "on_surface_variant" }),
    ui.label({ text = message, color = "on_surface_variant", textAlign = "center" }),
  })
end

local function itemColumn(rows)
  -- Always stretch full width; unique key per tab+mode so filter toggles
  -- do not reuse empty-state layout props.
  return ui.column({
    key = "items-" .. tab,
    align = "stretch",
    justify = "start",
    gap = 8,
    flexGrow = 1,
  }, rows)
end

local function itemList()
  if tab == "nodes" then
    local nodes = filteredNodes()
    if #nodes == 0 then
      return emptyList(tr("panel.empty_nodes"))
    end
    local rows = {}
    for _, n in ipairs(nodes) do
      table.insert(rows, nodeCard(n))
    end
    return itemColumn(rows)
  end
  if tab == "pods" then
    local pods = filteredPods()
    if #pods == 0 then
      return emptyList(tr("panel.empty_pods"))
    end
    local rows = {}
    for _, p in ipairs(pods) do
      table.insert(rows, podCard(p))
    end
    return itemColumn(rows)
  end
  if tab == "deploys" then
    local deps = filteredDeploys()
    if #deps == 0 then
      return emptyList(tr("panel.empty_deploys"))
    end
    local rows = {}
    for _, d in ipairs(deps) do
      table.insert(rows, deployCard(d))
    end
    return itemColumn(rows)
  end
  local nss = filteredNamespaces()
  if #nss == 0 then
    return emptyList(tr("panel.empty_namespaces"))
  end
  local rows = {}
  for _, n in ipairs(nss) do
    table.insert(rows, nsCard(n))
  end
  return itemColumn(rows)
end

local function tabButton(label, id, cb)
  return ui.button({
    text = label,
    selected = tab == id,
    variant = tab == id and "primary" or "ghost",
    onClick = cb,
  })
end

local function filterPlaceholder()
  if tab == "nodes" then
    return tr("filter.placeholder_nodes")
  end
  if tab == "pods" then
    return tr("filter.placeholder_pods")
  end
  if tab == "deploys" then
    return tr("filter.placeholder_deploys")
  end
  return tr("filter.placeholder_namespaces")
end

render = function()
  dirty = false
  local statusRows = {}
  if snapshot.loading == true and not snapshot.available then
    table.insert(statusRows, ui.label({ text = tr("panel.loading"), color = "on_surface_variant" }))
  end
  if snapshot.busy == true then
    table.insert(statusRows, ui.label({ text = tr("panel.busy"), color = "primary" }))
  end
  if type(snapshot.error) == "string" and snapshot.error ~= "" then
    table.insert(statusRows, ui.label({ text = snapshot.error, color = "error", maxLines = 3 }))
  end
  if feedback ~= "" then
    table.insert(statusRows, ui.label({
      text = feedback,
      color = feedbackError and "error" or "tertiary",
      maxLines = 2,
    }))
  end

  local summary = tr("panel.summary", {
    ready = snapshot.readyNodes or 0,
    nodes = snapshot.nodeCount or 0,
    problems = snapshot.problemPods or 0,
    pods = snapshot.podCount or 0,
  })

  panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({
        name = ICON_MAIN,
        size = 24,
        color = snapshot.available and "primary" or "on_surface_variant",
      }),
      ui.column({ flexGrow = 1, gap = 0 }, {
        ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold" }),
        ui.label({
          text = tr("panel.context", { name = snapshot.context ~= "" and snapshot.context or "—" }),
          fontSize = 11,
          color = "on_surface_variant",
        }),
      }),
      ui.button({
        text = tr("actions.open_k9s"),
        glyph = "terminal-2",
        variant = "outline",
        onClick = "onK9s",
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        onClick = "onRefresh",
      }),
      ui.button({ glyph = "close", onClick = "onClose" }),
    }),

    -- Tabs only (summary lives on its own row so it cannot overflow)
    ui.row({ gap = 4, align = "center" }, {
      tabButton(tr("tabs.nodes"), "nodes", "onTabNodes"),
      tabButton(tr("tabs.pods"), "pods", "onTabPods"),
      tabButton(tr("tabs.deploys"), "deploys", "onTabDeploys"),
      tabButton(tr("tabs.namespaces"), "namespaces", "onTabNamespaces"),
    }),

    ui.label({
      text = summary,
      color = "on_surface_variant",
      fontSize = 11,
      maxLines = 1,
    }),

    -- Search filter for every tab
    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = `filter-{tab}-{filterKey}`,
        value = filterText,
        placeholder = filterPlaceholder(),
        flexGrow = 1,
        controlSize = "sm",
        onChange = "onFilterChange",
      }),
      ui.button({
        text = problemsOnly and tr("filter.problems") or tr("filter.all"),
        glyph = "filter",
        variant = problemsOnly and "primary" or "outline",
        visible = tab == "pods",
        onClick = "onToggleFilter",
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        visible = filterText ~= "",
        onClick = "onClearFilter",
      }),
    }),

    toolbar(),
    ui.column({ gap = 3, align = "stretch" }, statusRows),
    -- Scroll owns the list; stretch so rows span the panel width while filtering.
    ui.scroll({
      key = "scroll-" .. tab,
      flexGrow = 1,
      gap = 8,
      align = "stretch",
    }, {
      itemList(),
    }),
    ui.label({
      text = (snapshot.updatedAt or 0) > 0
        and tr("panel.updated", { time = noctalia.formatTime("%H:%M:%S", snapshot.updatedAt) })
        or "",
      color = "on_surface_variant",
      fontSize = 11,
    }),
  }))
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) ~= "table" then
    return
  end
  local changed = value.revision ~= snapshot.revision
    or value.busy ~= snapshot.busy
    or value.error ~= snapshot.error
    or value.problemPods ~= snapshot.problemPods
    or value.loading ~= snapshot.loading
    or value.available ~= snapshot.available
    or value.nodeCount ~= snapshot.nodeCount
    or value.podCount ~= snapshot.podCount
  snapshot = value
  if selectedId ~= "" then
    local still = selectedNode() or selectedPod() or selectedDeploy() or selectedNs()
    if not still then
      selectedId = ""
    end
  end
  if changed then
    dirty = true
  end
end)

noctalia.state.watch(RESULT_KEY, function(result)
  if type(result) ~= "table" then
    return
  end
  if type(result.requestId) ~= "string" or not result.requestId:match("^panel%-") then
    return
  end
  feedback = tostring(result.message or "")
  feedbackError = result.ok ~= true
  dirty = true
end)

panel.setWantsSecondTicks(true)

function onOpen(_context)
  feedback = ""
  sendCommand("refresh")
  render()
end

function update()
  if dirty then
    render()
  end
end

function onClose() panel.close() end
function onRefresh() sendCommand("refresh") end

local function switchTab(next)
  tab = next
  selectedId = ""
  -- keep filter text across tabs; re-key input so placeholder updates cleanly
  filterKey += 1
  render()
end

function onTabNodes() switchTab("nodes") end
function onTabPods() switchTab("pods") end
function onTabDeploys() switchTab("deploys") end
function onTabNamespaces() switchTab("namespaces") end

function onFilterChange(value)
  filterText = if type(value) == "string" then value else ""
  -- drop selection if it no longer matches
  if selectedId ~= "" then
    local still = selectedNode() or selectedPod() or selectedDeploy() or selectedNs()
    if still then
      if tab == "nodes" and not matchesFilter(still.name, still.status, still.version, still.ip) then
        selectedId = ""
      elseif tab == "pods" and not matchesFilter(still.namespace, still.name, still.status, still.node) then
        selectedId = ""
      elseif tab == "deploys" and not matchesFilter(still.namespace, still.name) then
        selectedId = ""
      elseif tab == "namespaces" and not matchesFilter(still.name, still.phase) then
        selectedId = ""
      end
    end
  end
  -- re-render list without re-keying the input (uncontrolled field keeps typed text)
  render()
end

function onClearFilter()
  filterText = ""
  filterKey += 1
  render()
end

function onToggleFilter()
  problemsOnly = not problemsOnly
  render()
end

function onK9s()
  local ns = ""
  local pod = selectedPod()
  local dep = selectedDeploy()
  if pod then
    ns = pod.namespace
  elseif dep then
    ns = dep.namespace
  end
  sendCommand("k9s", { namespace = ns })
end

function onDescribeNode()
  local n = selectedNode()
  if n then
    sendCommand("describe", { kind = "node", name = n.name })
  end
end

function onDescribePod()
  local p = selectedPod()
  if p then
    sendCommand("describe", { kind = "pod", name = p.name, namespace = p.namespace })
  end
end

function onDescribeDeploy()
  local d = selectedDeploy()
  if d then
    sendCommand("describe", { kind = "deploy", name = d.name, namespace = d.namespace })
  end
end

function onDescribeNs()
  local n = selectedNs()
  if n then
    sendCommand("describe", { kind = "namespace", name = n.name })
  end
end

function onLogs()
  local p = selectedPod()
  if p then
    sendCommand("logs", { name = p.name, namespace = p.namespace })
  end
end

function onDeletePod()
  local p = selectedPod()
  if p then
    sendCommand("delete_pod", { name = p.name, namespace = p.namespace })
  end
end

function onRestart()
  local d = selectedDeploy()
  if d then
    sendCommand("restart_deploy", { name = d.name, namespace = d.namespace })
  end
end
