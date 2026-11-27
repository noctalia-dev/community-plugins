--!nonstrict
-- One compositor cache for every ribbon instance. Event payloads update the
-- cache directly; snapshots are only for startup, recovery and output changes.
local RESYNC_MS = 60000
local BATCH_MS = 33
local IDLE_MS = 1000
local windows, workspaces, outputs = nil, nil, nil
local revision = { windows = 0, workspaces = 0, outputs = 0 }
local published = {}
local pending = false
local inFlight = false
local refreshOutputs = false
local lastSnapshot = -RESYNC_MS
local lastOutputFetch = -RESYNC_MS
local function env(name)
  return noctalia.getenv and noctalia.getenv(name) or ""
end
local desktop = string.lower(env("XDG_CURRENT_DESKTOP") .. ":" .. env("XDG_SESSION_DESKTOP"))
local backend = "niri"
if string.find(desktop, "umbriel", 1, true) then
  backend = "umbriel"
elseif not string.find(desktop, "niri", 1, true) then
  if env("UMBRIEL_SOCKET") ~= "" or (env("NIRI_SOCKET") == "" and not noctalia.commandExists("niri")) then
    backend = "umbriel"
  end
end
local enabled = noctalia.commandExists(backend)
local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function layout(value)
  value = type(value) == "table" and value or {}
  local pos = value.pos_in_scrolling_layout
  local size = value.tile_size
  local viewPos = value.tile_pos_in_workspace_view
  local x = type(viewPos) == "table" and viewPos[1] or nil
  -- Only horizontal movement affects the ribbon. Missing/null is expected
  -- for off-screen tiles and older niri versions; never retain a stale x.
  if type(x) ~= "number" or x ~= x or math.abs(x) == math.huge then x = nil end
  return {
    pos_in_scrolling_layout = type(pos) == "table" and { pos[1] } or nil,
    tile_size = type(size) == "table" and { size[1] } or nil,
    tile_pos_in_workspace_view = x ~= nil and { x } or nil,
  }
end

local function window(value)
  return { id = value.id, workspace_id = value.workspace_id,
    is_floating = value.is_floating == true, is_focused = value.is_focused == true,
    layout = layout(value.layout) }
end

local function normalize(key, data)
  local result = {}
  if backend == "umbriel" then
    for _, value in ipairs(data) do
      if key == "windows" then
        -- Off-screen and hidden-tab windows still contribute to column extents.
        if not value.floating and not value.pinned and not value.minimized
          and (value.scratchpad == nil or value.scratchpad == "")
          and finite(value.column) and value.column >= 0
          and finite(value.x) and finite(value.w) and value.w > 0 then
          result[value.id] = { id = value.id, workspace_id = value.workspace,
            layout = { global_x = value.x, tile_size = { value.w } } }
        end
      elseif key == "workspaces" then
        result[value.id] = { id = value.id, output = value.output,
          is_active = value.active == true, is_focused = value.focused == true,
          layout_mode = value.layout,
          active_window_id = value.focused_window ~= "" and value.focused_window or nil }
      elseif value.enabled and value.logical_size and value.position
        and finite(value.logical_size.width) and value.logical_size.width > 0
        and finite(value.position.x) then
        result[value.name] = { logical = { width = value.logical_size.width, x = value.position.x } }
      end
    end
  elseif key == "windows" then
    for _, value in ipairs(data) do result[value.id] = window(value) end
  elseif key == "workspaces" then
    for _, value in ipairs(data) do
      result[value.id] = { id = value.id, output = value.output,
        is_active = value.is_active == true, is_focused = value.is_focused == true,
        active_window_id = value.active_window_id }
    end
  else
    for name, value in pairs(data) do
      if value.logical then result[name] = { logical = { width = value.logical.width } } end
    end
  end
  return result
end

local function changed(key)
  revision[key] = revision[key] + 1
  if not pending then
    pending = true
    noctalia.setUpdateInterval(BATCH_MS)
  end
end

local function replace(key, data)
  local next = normalize(key, data)
  local old = key == "windows" and windows or key == "workspaces" and workspaces or outputs
  if equal(old, next) then return end
  if key == "windows" then windows = next
  elseif key == "workspaces" then workspaces = next
  else outputs = next end
  changed(key)
end

local function sortedValues(map)
  local list = {}
  for _, value in pairs(map) do list[#list + 1] = value end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

local function publish()
  if not windows or not workspaces or not outputs then return end
  local views = {}
  local focusedOutput = nil
  for name, output in pairs(outputs) do
    views[name] = { backend = backend, windows = {}, workspaces = {}, outputs = { [name] = output } }
  end
  for _, ws in ipairs(sortedValues(workspaces)) do
    local view = views[ws.output]
    if view then
      -- Global focus is irrelevant to a monitor's ribbon. Only the fallback
      -- key changes when focus moves between monitors.
      view.workspaces[#view.workspaces + 1] = { id = ws.id, output = ws.output,
        is_active = ws.is_active, is_focused = ws.is_active, layout_mode = ws.layout_mode,
        active_window_id = ws.is_active and ws.active_window_id or nil }
      if ws.is_focused then focusedOutput = ws.output end
    end
  end
  for _, win in ipairs(sortedValues(windows)) do
    local ws = workspaces[win.workspace_id]
    local view = ws and views[ws.output]
    if view and ws.is_active and not win.is_floating then
      view.windows[#view.windows + 1] = { id = win.id, workspace_id = win.workspace_id,
        layout = win.layout }
    end
  end
  local nextPublished = { focused = views[focusedOutput] or {} }
  for name, view in pairs(views) do nextPublished["output:" .. name] = view end
  for key, value in pairs(nextPublished) do
    if not equal(published[key], value) then noctalia.state.set(key, value) end
  end
  for key in pairs(published) do
    if nextPublished[key] == nil then noctalia.state.set(key, {}) end
  end
  published = nextPublished
end

local function fetch(keys)
  if inFlight then return end
  inFlight = true
  lastOutputFetch = noctalia.nowMs()
  if #keys > 1 then lastSnapshot = lastOutputFetch end
  local remaining = #keys
  for _, key in ipairs(keys) do
    local atRevision = revision[key]
    local function onResult(result)
      if result.exitCode == 0 and result.stdout ~= "" then
        local ok, data = pcall(noctalia.json.decode, result.stdout)
        -- An event received after this query began owns the newer state.
        if ok and type(data) == "table" and revision[key] == atRevision then replace(key, data) end
      end
      remaining = remaining - 1
      if remaining == 0 then inFlight = false end
    end
    local command = backend == "umbriel" and ("umbriel " .. key .. " --json") or ("niri msg -j " .. key)
    if noctalia.runAsync(command, onResult, 3000) == false then
      onResult({ exitCode = -1, stdout = "" })
    end
  end
end

local function focusWindow(id)
  if not windows then return end
  local any = false
  for _, win in pairs(windows) do
    local focused = win.id == id
    if win.is_focused ~= focused then win.is_focused = focused; any = true end
  end
  if any then changed("windows") end
end

local function onEventLine(line)
  local ok, event = pcall(noctalia.json.decode, line)
  if not ok or type(event) ~= "table" then return end
  if backend == "umbriel" then
    if revision[event.event] ~= nil and type(event.data) == "table" then
      replace(event.event, event.data)
    end
    return
  end
  if event.WindowsChanged then
    replace("windows", event.WindowsChanged.windows or {})
  elseif event.WorkspacesChanged then
    replace("workspaces", event.WorkspacesChanged.workspaces or {})
    -- Covers output hotplug/migration. Rate-limited separately from publishing.
    refreshOutputs = true
  elseif event.WindowOpenedOrChanged and windows then
    local next = window(event.WindowOpenedOrChanged.window)
    if next.is_focused then focusWindow(next.id) end
    if not equal(windows[next.id], next) then windows[next.id] = next; changed("windows") end
  elseif event.WindowClosed and windows then
    local id = event.WindowClosed.id
    if windows[id] then windows[id] = nil; changed("windows") end
  elseif event.WindowLayoutsChanged and windows then
    local any = false
    for _, pair in ipairs(event.WindowLayoutsChanged.changes or {}) do
      local win = windows[pair[1]]
      local next = layout(pair[2])
      if win and not equal(win.layout, next) then win.layout = next; any = true end
    end
    if any then changed("windows") end
  elseif event.WindowFocusChanged then
    focusWindow(event.WindowFocusChanged.id)
  elseif event.WorkspaceActiveWindowChanged and workspaces then
    local value = event.WorkspaceActiveWindowChanged
    local ws = workspaces[value.workspace_id]
    if ws and ws.active_window_id ~= value.active_window_id then
      ws.active_window_id = value.active_window_id
      changed("workspaces")
    end
  elseif event.WorkspaceActivated and workspaces then
    local value = event.WorkspaceActivated
    local active = workspaces[value.id]
    if active then
      local any = false
      for _, ws in pairs(workspaces) do
        if ws.output == active.output and ws.is_active ~= (ws.id == value.id) then
          ws.is_active = ws.id == value.id; any = true
        end
        if value.focused and ws.is_focused ~= (ws.id == value.id) then
          ws.is_focused = ws.id == value.id; any = true
        end
      end
      if any then changed("workspaces") end
    end
  elseif event.ConfigLoaded then
    refreshOutputs = true
  end
end

function update()
  if not enabled then return end
  local now = noctalia.nowMs()
  if not inFlight then
    if now - lastSnapshot >= RESYNC_MS then
      refreshOutputs = false
      fetch({ "windows", "workspaces", "outputs" })
    elseif refreshOutputs and now - lastOutputFetch >= IDLE_MS then
      refreshOutputs = false
      fetch({ "outputs" })
    end
  end
  if pending then
    pending = false
    publish()
    noctalia.setUpdateInterval(IDLE_MS)
  end
end

noctalia.setUpdateInterval(IDLE_MS)
if enabled then
  fetch({ "windows", "workspaces", "outputs" })
  -- The host owns this process group. Reconnect after EOF without accumulating
  -- subscriptions; the new stream supplies full windows/workspaces snapshots.
  local subscribe = backend == "umbriel" and "umbriel subscribe windows,workspaces,outputs" or "niri msg -j event-stream"
  if not noctalia.runStream("while :; do " .. subscribe .. "; sleep 2; done", onEventLine) then
    noctalia.notifyError("Niri Ribbon", "Unable to subscribe to " .. backend .. " events")
  end
else
  noctalia.notifyError("Niri Ribbon", backend .. " command not found in PATH")
end
