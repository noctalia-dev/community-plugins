--!nonstrict

local SNAPSHOT_KEY = "hypr-display-config.snapshot"

function parseMonitors(jsonText)
  local decoded = noctalia.json.decode(jsonText)
  if type(decoded) ~= "table" then return {} end
  local monitors = {}
  for _, entry in ipairs(decoded) do
    monitors[#monitors + 1] = {
      name = tostring(entry.name or ""),
      width = tonumber(entry.width) or 0,
      height = tonumber(entry.height) or 0,
      x = tonumber(entry.x) or 0,
      y = tonumber(entry.y) or 0,
      scale = tonumber(entry.scale) or 1,
      transform = tonumber(entry.transform) or 0,
      refreshRate = tonumber(entry.refreshRate) or 0,
      availableModes = entry.availableModes or {},
      disabled = entry.disabled == true,
    }
  end
  return monitors
end

function parseWorkspaceRules(jsonText)
  local decoded = noctalia.json.decode(jsonText)
  if type(decoded) ~= "table" then return {} end
  local bindings = {}
  for _, entry in ipairs(decoded) do
    local id = tonumber(entry.workspaceString)
    local monitor = entry.monitor
    if id ~= nil and type(monitor) == "string" and monitor ~= "" then
      bindings[#bindings + 1] = { workspace = id, monitor = monitor }
    end
  end
  return bindings
end

local function currentModeString(monitor)
  local candidate = string.format("%dx%d@%.2fHz", monitor.width, monitor.height, monitor.refreshRate)
  for _, available in ipairs(monitor.availableModes or {}) do
    if available == candidate then return candidate end
  end
  return "preferred"
end

function buildSnapshot(monitors, bindings, workspaceCount)
  local boundByMonitor = {}
  local boundWorkspaceIds = {}
  for _, binding in ipairs(bindings) do
    local list = boundByMonitor[binding.monitor]
    if list == nil then
      list = {}
      boundByMonitor[binding.monitor] = list
    end
    list[#list + 1] = binding.workspace
    boundWorkspaceIds[binding.workspace] = true
  end

  local orderedMonitors = {}
  for _, monitor in ipairs(monitors) do
    orderedMonitors[#orderedMonitors + 1] = monitor
  end
  table.sort(orderedMonitors, function(a, b) return a.x < b.x end)

  local snapshotMonitors = {}
  for _, monitor in ipairs(orderedMonitors) do
    local workspaces = boundByMonitor[monitor.name] or {}
    table.sort(workspaces)
    snapshotMonitors[#snapshotMonitors + 1] = {
      name = monitor.name,
      width = monitor.width,
      height = monitor.height,
      x = monitor.x,
      y = monitor.y,
      scale = monitor.scale,
      transform = monitor.transform,
      refreshRate = monitor.refreshRate,
      availableModes = monitor.availableModes,
      mode = currentModeString(monitor),
      disabled = monitor.disabled,
      workspaces = workspaces,
    }
  end

  local unbound = {}
  for id = 1, workspaceCount do
    if not boundWorkspaceIds[id] then
      unbound[#unbound + 1] = id
    end
  end

  return {
    status = "ready",
    monitors = snapshotMonitors,
    unboundWorkspaces = unbound,
  }
end

local function workspaceCount()
  local value = tonumber(noctalia.getConfig("workspace_count"))
  if value == nil or value < 1 then return 10 end
  return math.floor(value)
end

local missingHyprctlNotified = false

local function poll()
  if not noctalia.commandExists("hyprctl") then
    if not missingHyprctlNotified then
      missingHyprctlNotified = true
      noctalia.notifyError(noctalia.tr("title"), "hyprctl not found on PATH")
    end
    return
  end
  noctalia.runAsync("hyprctl monitors all -j", function(monitorsResult)
    if monitorsResult.exitCode ~= 0 then return end
    local monitors = parseMonitors(monitorsResult.stdout)
    noctalia.runAsync("hyprctl workspacerules -j", function(rulesResult)
      if rulesResult.exitCode ~= 0 then return end
      local bindings = parseWorkspaceRules(rulesResult.stdout)
      local snapshot = buildSnapshot(monitors, bindings, workspaceCount())
      noctalia.state.set(SNAPSHOT_KEY, snapshot)
    end)
  end)
end

noctalia.setUpdateInterval(2000)

function update()
  poll()
end

poll()
