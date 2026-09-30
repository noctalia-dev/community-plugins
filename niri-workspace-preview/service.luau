--!nonstrict
-- Maintains a normalized in-memory view of Niri workspaces and windows.
-- Niri's event stream sends complete initial state followed by incremental
-- changes, so normal operation needs one long-lived process and no polling.

local STATE_KEY = "workspace_preview_snapshot"
local RECONNECTING_STREAM = [[
delay=1
while :; do
  if niri msg --json event-stream; then delay=1; fi
  sleep "$delay"
  if [ "$delay" -lt 16 ]; then delay=$((delay * 2)); else delay=30; fi
done
]]

local previousSnapshot = noctalia.state.get(STATE_KEY)
local workspaces = type(previousSnapshot) == "table" and previousSnapshot.workspaces or {}
local windows = type(previousSnapshot) == "table" and previousSnapshot.windows or {}
local revision = 0
local streamStarted = false

local function copyArray(values)
  local result = {}
  for _, value in ipairs(values or {}) do
    result[#result + 1] = value
  end
  return result
end

local function normalizeLayout(layout, previous)
  if type(layout) ~= "table" then return nil end
  previous = type(previous) == "table" and previous or {}
  return {
    pos_in_scrolling_layout = layout.pos_in_scrolling_layout,
    tile_pos_in_workspace_view = layout.tile_pos_in_workspace_view or previous.tile_pos_in_workspace_view,
    tile_size = layout.tile_size or previous.tile_size,
  }
end

local function focusedWorkspaceId()
  for _, workspace in ipairs(workspaces) do
    if workspace.is_focused == true then return workspace.id end
  end
  return nil
end

local function normalizeWindow(window, previous)
  if type(window) ~= "table" or window.id == nil then return nil end
  previous = type(previous) == "table" and previous or {}
  local workspaceId = window.workspace_id
  if workspaceId == nil and window.is_floating == true then
    workspaceId = previous.workspace_id
    if workspaceId == nil and window.is_focused == true then workspaceId = focusedWorkspaceId() end
  end
  return {
    id = window.id,
    app_id = window.app_id,
    workspace_id = workspaceId,
    is_focused = window.is_focused == true,
    is_floating = window.is_floating == true,
    is_urgent = window.is_urgent == true,
    layout = normalizeLayout(window.layout, previous.layout),
  }
end

local function normalizeWindows(values)
  local result = {}
  local previousById = {}
  for _, value in ipairs(windows or {}) do previousById[value.id] = value end
  for _, value in ipairs(values or {}) do
    local window = normalizeWindow(value, previousById[value.id])
    if window ~= nil then result[#result + 1] = window end
  end
  return result
end

local function normalizeWorkspace(workspace)
  return {
    id = workspace.id,
    idx = workspace.idx,
    name = workspace.name,
    output = workspace.output,
    is_active = workspace.is_active == true,
    is_focused = workspace.is_focused == true,
    is_urgent = workspace.is_urgent == true,
    active_window_id = workspace.active_window_id,
  }
end

local function normalizeWorkspaces(values)
  local result = {}
  for _, value in ipairs(values or {}) do
    if type(value) == "table" and value.id ~= nil then
      result[#result + 1] = normalizeWorkspace(value)
    end
  end
  return result
end

local function currentOutputs()
  local result = {}
  for _, output in ipairs(noctalia.outputs() or {}) do
    result[#result + 1] = {
      name = output.name,
      width = output.width,
      height = output.height,
      x = output.x,
      y = output.y,
      focused = output.focused == true,
    }
  end
  table.sort(result, function(a, b)
    local ax, bx = tonumber(a.x) or 0, tonumber(b.x) or 0
    local ay, by = tonumber(a.y) or 0, tonumber(b.y) or 0
    if ax ~= bx then return ax < bx end
    if ay ~= by then return ay < by end
    return tostring(a.name or "") < tostring(b.name or "")
  end)
  return result
end

local function publish(status, message)
  revision = revision + 1
  noctalia.state.set(STATE_KEY, {
    revision = revision,
    status = status or "ok",
    message = message or "",
    outputs = currentOutputs(),
    workspaces = copyArray(workspaces),
    windows = copyArray(windows),
  })
end

local function findById(values, id)
  for index, value in ipairs(values) do
    if value.id == id then return index, value end
  end
  return nil, nil
end

local function applyWorkspaceActivated(id, focused)
  local _, activated = findById(workspaces, id)
  if activated == nil then return end
  for _, workspace in ipairs(workspaces) do
    if workspace.output == activated.output then
      workspace.is_active = workspace.id == id
    end
    if focused then workspace.is_focused = workspace.id == id end
  end
end

local function applyWindow(window)
  if type(window) ~= "table" or window.id == nil then return end
  local index, previous = findById(windows, window.id)
  window = normalizeWindow(window, previous)
  if window == nil then return end
  if window.is_focused == true then
    for _, candidate in ipairs(windows) do candidate.is_focused = false end
  end
  if index ~= nil then windows[index] = window else windows[#windows + 1] = window end
end

local function removeWindow(id)
  local index = findById(windows, id)
  if index ~= nil then table.remove(windows, index) end
end

local function applyEvent(event)
  if event.WorkspacesChanged ~= nil then
    workspaces = normalizeWorkspaces(event.WorkspacesChanged.workspaces)
  elseif event.WorkspaceActivated ~= nil then
    local change = event.WorkspaceActivated
    applyWorkspaceActivated(change.id, change.focused == true)
  elseif event.WorkspaceActiveWindowChanged ~= nil then
    local change = event.WorkspaceActiveWindowChanged
    local _, workspace = findById(workspaces, change.workspace_id)
    if workspace ~= nil then workspace.active_window_id = change.active_window_id end
  elseif event.WorkspaceUrgencyChanged ~= nil then
    local change = event.WorkspaceUrgencyChanged
    local _, workspace = findById(workspaces, change.id)
    if workspace ~= nil then workspace.is_urgent = change.urgent == true end
  elseif event.WindowsChanged ~= nil then
    windows = normalizeWindows(event.WindowsChanged.windows)
  elseif event.WindowOpenedOrChanged ~= nil then
    applyWindow(event.WindowOpenedOrChanged.window)
  elseif event.WindowClosed ~= nil then
    removeWindow(event.WindowClosed.id)
  elseif event.WindowFocusChanged ~= nil then
    local focusedId = event.WindowFocusChanged.id
    for _, window in ipairs(windows) do window.is_focused = window.id == focusedId end
  elseif event.WindowUrgencyChanged ~= nil then
    local change = event.WindowUrgencyChanged
    local _, window = findById(windows, change.id)
    if window ~= nil then window.is_urgent = change.urgent == true end
  elseif event.WindowLayoutsChanged ~= nil then
    for _, change in ipairs(event.WindowLayoutsChanged.changes or {}) do
      local id, layout = change[1], change[2]
      local _, window = findById(windows, id)
      if window ~= nil and type(layout) == "table" then window.layout = normalizeLayout(layout, window.layout) end
    end
  else
    return false
  end
  return true
end

local function onStreamLine(line)
  local event = noctalia.json.decode(line)
  if type(event) == "table" and applyEvent(event) then publish("ok", "") end
end

local function startStream()
  if streamStarted then return end
  if not noctalia.commandExists("niri") then
    publish("unavailable", "niri was not found on PATH")
    return
  end
  streamStarted = noctalia.runStream(RECONNECTING_STREAM, onStreamLine)
  if not streamStarted then publish("unavailable", "could not start the niri event stream") end
end

publish("connecting", "waiting for niri")
startStream()

function onOutputsChanged()
  publish("ok", "")
end

function onIpc(event)
  if event == "refresh" then publish("ok", "") end
end
