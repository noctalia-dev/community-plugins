-- Publishes populated or active Hyprland special workspaces to the plugin state
-- channel.
-- Hyprland's event socket triggers snapshots after relevant changes.

local STATE_KEY = "special_workspaces"
local SEPARATOR = "__NOCTALIA_SPECIAL_WORKSPACES_MONITORS__"
local STREAM_REFRESH_MARKER = "__NOCTALIA_SPECIAL_WORKSPACES_STREAM_REFRESH__"
local SNAPSHOT_ATTEMPTS = 3

local loggedSnapshotError = false
local refreshInFlight = false
local refreshPending = false

local function logSnapshotError(message)
  if not loggedSnapshotError then
    noctalia.log("Special workspaces: " .. message .. "; retaining last state")
    loggedSnapshotError = true
  end
end

local function shellQuote(value)
  return "'" .. string.gsub(value, "'", "'\"'\"'") .. "'"
end

local function specialName(value)
  if type(value) ~= "string" then
    return nil
  end

  local name = string.match(value, "^special:(.+)$")
  if name and name ~= "" then
    return name
  end
  return nil
end

local function snapshotFromJson(clientsJson, monitorsJson)
  local clients, clientErr = noctalia.json.decode(clientsJson)
  local monitors, monitorErr = noctalia.json.decode(monitorsJson)
  if type(clients) ~= "table" or type(monitors) ~= "table" then
    return nil, "invalid Hyprland JSON" .. (clientErr and (": " .. clientErr) or (monitorErr and (": " .. monitorErr) or ""))
  end

  local workspaces = {}
  for _, client in ipairs(clients) do
    local workspace = client.workspace
    local name = workspace and specialName(workspace.name)
    if name then
      local item = workspaces[name]
      if not item then
        item = { name = name, windowCount = 0, active = false }
        workspaces[name] = item
      end
      item.windowCount = item.windowCount + 1
    end
  end

  for _, monitor in ipairs(monitors) do
    local special = monitor.specialWorkspace
    local name = special and specialName(special.name)
    if name then
      local item = workspaces[name]
      if not item then
        item = { name = name, windowCount = 0, active = false }
        workspaces[name] = item
      end
      item.active = true
    end
  end

  local result = {}
  for _, item in pairs(workspaces) do
    table.insert(result, item)
  end
  table.sort(result, function(a, b) return a.name < b.name end)
  return result
end

local function publishSnapshot(clientsJson, monitorsJson)
  local state, err = snapshotFromJson(clientsJson, monitorsJson)
  if not state then
    -- Keep the last valid state during temporary compositor command failures.
    logSnapshotError("snapshot failed (" .. err .. ")")
    return false
  end
  loggedSnapshotError = false
  noctalia.state.set(STATE_KEY, state)
  return true
end

local function refresh()
  if refreshInFlight then
    refreshPending = true
    return
  end
  refreshInFlight = true
  local command = "attempt=1; while [ \"$attempt\" -le " .. SNAPSHOT_ATTEMPTS
    .. " ]; do clients=$(hyprctl -j clients) && monitors=$(hyprctl -j monitors)"
    .. " && { printf '%s\\n" .. SEPARATOR .. "\\n%s\\n' \"$clients\" \"$monitors\"; exit 0; };"
    .. " attempt=$((attempt + 1)); [ \"$attempt\" -le " .. SNAPSHOT_ATTEMPTS
    .. " ] && sleep 1; done; exit 1"
  local started = noctalia.runAsync(command, function(result)
    if result.exitCode ~= 0 then
      logSnapshotError("hyprctl failed")
    else
      local markerStart, markerEnd = string.find(result.stdout, "\n" .. SEPARATOR .. "\n", 1, true)
      if not markerStart then
        logSnapshotError("incomplete hyprctl snapshot")
      else
        publishSnapshot(string.sub(result.stdout, 1, markerStart - 1), string.sub(result.stdout, markerEnd + 1))
      end
    end

    refreshInFlight = false
    if refreshPending then
      refreshPending = false
      refresh()
    end
  end)
  if not started then
    refreshInFlight = false
    logSnapshotError("could not start hyprctl snapshot")
  end
end

local refreshEvents = {
  activespecial = true,
  activespecialv2 = true,
  openwindow = true,
  closewindow = true,
  movewindow = true,
  movewindowv2 = true,
  workspace = true,
  workspacev2 = true,
  focusedmon = true,
  focusedmonv2 = true,
  createworkspace = true,
  createworkspacev2 = true,
  destroyworkspace = true,
  destroyworkspacev2 = true,
  moveworkspace = true,
  moveworkspacev2 = true,
  renameworkspace = true,
  monitoradded = true,
  monitoraddedv2 = true,
  monitorremoved = true,
  monitorremovedv2 = true,
}

local function startEventStream()
  if not noctalia.commandExists("socat") then
    noctalia.log("Special workspaces: socat is unavailable; event updates disabled")
    return
  end

  local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR")
  local signature = noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE")
  if not runtimeDir or not signature then
    noctalia.log("Special workspaces: Hyprland environment is unavailable; event updates disabled")
    return
  end

  local socket = runtimeDir .. "/hypr/" .. signature .. "/.socket2.sock"
  -- Keep a single helper alive across temporary socket failures. Noctalia stops
  -- the complete stream command automatically when this service exits.
  local command = "while true; do while [ ! -S " .. shellQuote(socket)
    .. " ]; do sleep 5; done; printf '" .. STREAM_REFRESH_MARKER
    .. "\\n'; socat -u UNIX-CONNECT:" .. shellQuote(socket)
    .. " - 2>&1; sleep 5; done"
  local started = noctalia.runStream(command, function(line)
    if line == STREAM_REFRESH_MARKER then
      refresh()
      return
    end

    local event = string.match(line, "^([%a%d_]+)>>")
    if event then
      if refreshEvents[event] then
        refresh()
      end
    end
  end)

  if not started then
    noctalia.log("Special workspaces: could not start socat event stream")
  end
end

refresh()
startEventStream()

function onOutputsChanged()
  refresh()
end
