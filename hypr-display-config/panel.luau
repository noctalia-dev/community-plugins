--!nonstrict

local SNAPSHOT_KEY = "hypr-display-config.snapshot"
local REQUEST_KEY = "hypr-display-config.apply_request"
local RESULT_KEY = "hypr-display-config.apply_result"

local snapshot = { status = "loading", monitors = {}, unboundWorkspaces = {} }
local errorMessage = ""
local requestCounter = 0
local pendingRequestId = nil
local scaleBuffer = {}
local activeScaleMonitor = nil
local applyBusy = false
local render

local function cloneMonitorsForRequest()
  local monitors = {}
  for _, monitor in ipairs(snapshot.monitors) do
    local mode = monitor.mode
    if mode == nil then
      mode = "preferred"
    end
    monitors[#monitors + 1] = {
      name = monitor.name,
      width = monitor.width,
      mode = mode,
      scale = monitor.scale,
      transform = monitor.transform,
      disabled = monitor.disabled,
      workspaces = monitor.workspaces,
    }
  end
  return monitors
end

local function dispatchApply()
  applyBusy = true
  requestCounter = requestCounter + 1
  local requestId = tostring(os.time()) .. "-" .. tostring(requestCounter)
  pendingRequestId = requestId
  noctalia.state.set(REQUEST_KEY, {
    request_id = requestId,
    monitors = cloneMonitorsForRequest(),
  })
end

local function findMonitorIndex(name)
  for index, monitor in ipairs(snapshot.monitors) do
    if monitor.name == name then return index end
  end
  return nil
end

function onReorder(draggedName, targetName)
  local fromIndex = findMonitorIndex(draggedName)
  local toIndex = findMonitorIndex(targetName)
  if fromIndex == nil or toIndex == nil or fromIndex == toIndex then return end
  local moved = table.remove(snapshot.monitors, fromIndex)
  table.insert(snapshot.monitors, toIndex, moved)
  dispatchApply()
  render()
end

function onWorkspaceToggled(workspaceIdText, monitorName, checked)
  local workspaceId = tonumber(workspaceIdText)
  if workspaceId == nil then return end
  local targetIndex = findMonitorIndex(monitorName)
  if targetIndex == nil then return end
  -- A workspace belongs to at most one monitor, so checking it here always
  -- clears it from every other monitor first, same as the old drag-drop
  -- assignment did.
  for _, monitor in ipairs(snapshot.monitors) do
    local kept = {}
    for _, id in ipairs(monitor.workspaces) do
      if id ~= workspaceId then kept[#kept + 1] = id end
    end
    monitor.workspaces = kept
  end
  if checked then
    local target = snapshot.monitors[targetIndex]
    target.workspaces[#target.workspaces + 1] = workspaceId
    table.sort(target.workspaces)
  end
  dispatchApply()
  render()
end

function onModeChanged(monitorName, mode)
  local index = findMonitorIndex(monitorName)
  if index == nil then return end
  snapshot.monitors[index].mode = mode
  dispatchApply()
  render()
end

function onScaleChanged(monitorName, scaleText)
  scaleBuffer[monitorName] = nil
  local index = findMonitorIndex(monitorName)
  local scale = tonumber(scaleText)
  if index == nil or scale == nil or scale <= 0 then
    -- Invalid input: the buffer was already cleared above, so re-render now
    -- so the input visibly reverts to the last-known-good value instead of
    -- silently leaving the invalid text on screen with no feedback.
    render()
    return
  end
  snapshot.monitors[index].scale = scale
  dispatchApply()
  render()
end

-- onSubmit handlers in this codebase's real-plugin ecosystem
-- (blackbartblues/keymap, noctalia/wallhaven) are always confirmed as a
-- string naming a global function -- never a closure -- so the scale input
-- below follows that convention rather than a closure capturing
-- `monitor.name`. Since ui.input's onSubmit callback only receives the
-- submitted value (no monitor name), the onChange handler below tracks which
-- monitor is currently being edited in `activeScaleMonitor`, and this global
-- handler looks that monitor up the same way onModeChanged/onTransformChanged
-- etc. already look monitors up by name.
function onScaleSubmit(value)
  if activeScaleMonitor == nil then return end
  -- Guard against a cross-monitor leak: if the user last typed in monitor
  -- A's scale field without submitting, then tabs/clicks into monitor B's
  -- field and hits Enter without typing anything there, `activeScaleMonitor`
  -- is still "A" (onChange never fired for B) while `value` is B's displayed
  -- text. Only proceed when the submitted value actually matches what
  -- onChange most recently tracked as typed for the monitor we think is
  -- active -- otherwise this is a foreign/untouched submit, so no-op.
  if scaleBuffer[activeScaleMonitor] ~= value then return end
  onScaleChanged(activeScaleMonitor, value)
end

function onTransformChanged(monitorName, transformText)
  local index = findMonitorIndex(monitorName)
  local transform = tonumber(transformText)
  if index == nil or transform == nil then return end
  snapshot.monitors[index].transform = transform
  dispatchApply()
  render()
end

function onEnabledToggled(monitorName)
  local index = findMonitorIndex(monitorName)
  if index == nil then return end
  local enabledCount = 0
  for _, monitor in ipairs(snapshot.monitors) do
    if monitor.disabled ~= true then enabledCount = enabledCount + 1 end
  end
  local monitor = snapshot.monitors[index]
  local wouldDisable = monitor.disabled ~= true
  if wouldDisable and enabledCount <= 1 then return end
  monitor.disabled = wouldDisable
  dispatchApply()
  render()
end

function onRefreshClicked()
  render()
end

local function allWorkspaceIds()
  local ids = {}
  local seen = {}
  for _, monitor in ipairs(snapshot.monitors) do
    for _, id in ipairs(monitor.workspaces) do
      if not seen[id] then
        seen[id] = true
        ids[#ids + 1] = id
      end
    end
  end
  for _, id in ipairs(snapshot.unboundWorkspaces) do
    if not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  return ids
end

local function indexOf(list, value)
  for i, item in ipairs(list) do
    if item == value then return i - 1 end
  end
  return 0
end

local function monitorCard(monitor, workspaceIds)
  local modeOptions = {}
  for _, mode in ipairs(monitor.availableModes or {}) do
    modeOptions[#modeOptions + 1] = mode
  end
  if #modeOptions == 0 then modeOptions = { "preferred" } end

  local boundHere = {}
  for _, id in ipairs(monitor.workspaces) do
    boundHere[id] = true
  end

  -- ui.row has no wrap/flow layout, so a checkbox per workspace (up to
  -- workspace_count, default 10) is chunked into fixed-size rows by hand
  -- rather than relying on the container to wrap them.
  local CHECKBOXES_PER_ROW = 5
  local checkboxRows = {}
  local currentRowItems = nil
  for i, workspaceId in ipairs(workspaceIds) do
    if (i - 1) % CHECKBOXES_PER_ROW == 0 then
      currentRowItems = {}
      checkboxRows[#checkboxRows + 1] = currentRowItems
    end
    currentRowItems[#currentRowItems + 1] = ui.row({
      key = "workspace-toggle-" .. monitor.name .. "-" .. tostring(workspaceId),
      gap = 4,
      align = "center",
    }, {
      ui.toggle({
        key = "toggle-" .. monitor.name .. "-" .. tostring(workspaceId),
        checked = boundHere[workspaceId] == true,
        enabled = monitor.disabled ~= true,
        onChange = function(checked) onWorkspaceToggled(tostring(workspaceId), monitor.name, checked) end,
      }),
      ui.label({ text = tostring(workspaceId), color = "on_surface_variant", fontSize = 11 }),
    })
  end
  local checkboxRowNodes = {}
  for rowIndex, rowItems in ipairs(checkboxRows) do
    checkboxRowNodes[#checkboxRowNodes + 1] = ui.row({
      key = "workspace-row-" .. monitor.name .. "-" .. tostring(rowIndex),
      gap = 10,
    }, rowItems)
  end

  return ui.column({
    key = "card-" .. monitor.name,
    gap = 8,
    padding = 12,
    radius = 10,
    fill = "surface_variant",
    width = 320,
  }, {
    ui.dragSource({
      key = "reorder-" .. monitor.name,
      dragType = "monitor-card",
      payload = monitor.name,
      width = 296,
      height = 28,
      radius = 6,
      fill = "surface",
      align = "center",
      justify = "center",
    }, {
      ui.row({ gap = 6, align = "center", justify = "center" }, {
        ui.glyph({ name = "grip-horizontal", size = 14, color = "on_surface_variant" }),
        ui.label({ text = monitor.name, color = "on_surface", fontWeight = "bold" }),
      }),
    }),
    ui.dropZone({
      key = "reorder-drop-" .. monitor.name,
      accepts = { "monitor-card" },
      value = monitor.name,
      onDrop = "onReorder",
      height = 4,
      radius = 4,
      expandOnDrag = true,
      hitSlop = 64,
    }, {}),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Mode", color = "on_surface_variant", fontSize = 11 }),
      ui.select({
        key = "mode-" .. monitor.name,
        options = modeOptions,
        selectedIndex = indexOf(modeOptions, monitor.mode or "preferred"),
        onChange = function(_index, text) onModeChanged(monitor.name, text) end,
      }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Scale", color = "on_surface_variant", fontSize = 11 }),
      ui.input({
        key = "scale-" .. monitor.name,
        value = scaleBuffer[monitor.name] or tostring(monitor.scale),
        onChange = function(value)
          scaleBuffer[monitor.name] = value
          activeScaleMonitor = monitor.name
        end,
        onSubmit = "onScaleSubmit",
      }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Rotation", color = "on_surface_variant", fontSize = 11 }),
      ui.select({
        key = "transform-" .. monitor.name,
        options = { "0", "1", "2", "3" },
        selectedIndex = indexOf({ "0", "1", "2", "3" }, tostring(monitor.transform)),
        onChange = function(_index, text) onTransformChanged(monitor.name, text) end,
      }),
    }),
    ui.button({
      key = "enabled-" .. monitor.name,
      text = monitor.disabled and "Disabled" or "Enabled",
      variant = monitor.disabled and "ghost" or "primary",
      onClick = function() onEnabledToggled(monitor.name) end,
    }),
    ui.separator({}),
    ui.label({ text = "Workspaces", color = "on_surface_variant", fontSize = 11 }),
    ui.column({ gap = 6 }, checkboxRowNodes),
  })
end

render = function()
  if snapshot.status ~= "ready" then
    panel.render(ui.column({ padding = 16 }, {
      ui.label({ text = "Loading monitors...", color = "on_surface" }),
    }))
    return
  end

  local workspaceIds = allWorkspaceIds()
  local cards = {}
  for _, monitor in ipairs(snapshot.monitors) do
    cards[#cards + 1] = monitorCard(monitor, workspaceIds)
  end

  local errorBanner = {}
  if errorMessage ~= "" then
    errorBanner[1] = ui.row({
      padding = 8, radius = 6, fill = "error",
    }, {
      ui.label({ text = errorMessage, color = "on_error" }),
    })
  end

  panel.render(ui.column({ gap = 12, padding = 16 }, (function()
    local children = {}
    for _, node in ipairs(errorBanner) do children[#children + 1] = node end
    children[#children + 1] = ui.row({ gap = 12, align = "start" }, cards)
    children[#children + 1] = ui.separator({})
    children[#children + 1] = ui.button({ text = noctalia.tr("panel.refresh"), onClick = "onRefreshClicked" })
    return children
  end)()))
end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
  if type(value) == "table" and not applyBusy then
    snapshot = value
    render()
  end
end)

noctalia.state.watch(RESULT_KEY, function(value)
  if type(value) ~= "table" then return end
  -- Only react to the result for the request we actually most recently
  -- dispatched. A stale/delayed result for a superseded request must not
  -- clobber the busy flag or error banner state for the request currently in
  -- flight. If a stale result arrives, we simply ignore it entirely and keep
  -- waiting for the real one -- clearing applyBusy here for a request we
  -- didn't ask about would let a new SNAPSHOT_KEY update clobber in-progress
  -- local edits (the exact bug the busy-guard exists to prevent), and it
  -- would be equally wrong to show a stale error banner for an old request.
  if pendingRequestId == nil or tostring(value.request_id) ~= pendingRequestId then
    return
  end
  if value.status == "error" then
    errorMessage = noctalia.tr("panel.apply_error", { message = tostring(value.message or "apply failed") })
    noctalia.notifyError(noctalia.tr("title"), errorMessage)
  else
    errorMessage = ""
  end
  pendingRequestId = nil
  applyBusy = false
  render()
end)

render()
