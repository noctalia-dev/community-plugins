--!nonstrict
-- Headless service: reads the authoritative output state from Niri's JSON IPC
-- and publishes a normalized snapshot for the bar widget and panel.

local STATE_KEY = "display_snapshot"
local DEFAULT_FALLBACK_INTERVAL_S = 30
local MIN_FALLBACK_INTERVAL_S = 5
local FOCUS_CHECK_INTERVAL_MS = 100
local COMMAND_TIMEOUT_MS = 5000

local fetching = false
local refreshQueued = false
local generation = 0
local lastRefreshNonce = noctalia.state.get("refresh_requested") or 0
local lastFullRefreshAt = 0
local lastResolutionByPort = {}
local resolutionStateReady = false
local presetApplying = {}
-- Enforce a matching preset once when the service starts or hot-reloads. This
-- also repairs a mode change that completed while the service was unavailable.
local forcePresetCheck = true
local startRefresh

local tr = noctalia.tr

local function initialSnapshot(status, message)
  return {
    revision = 0,
    status = status,
    error_message = message,
    focused_output = nil,
    displays = {},
    updated_at = "",
  }
end

local function shallowCopy(value)
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = item
  end
  return copy
end

local function readFallbackIntervalSeconds()
  local seconds = tonumber(noctalia.getConfig("refresh_interval")) or DEFAULT_FALLBACK_INTERVAL_S
  return math.max(MIN_FALLBACK_INTERVAL_S, seconds)
end

local function quoteShellArgument(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function formatScale(value)
  local text = string.format("%.4f", value)
  text = text:gsub("0+$", ""):gsub("%.$", "")
  return text
end

local function presetFor(port, width, height)
  local rawPresets = noctalia.getConfig("scale_presets")
  local globalScale = nil
  local portScale = nil
  if type(rawPresets) ~= "table" then
    return nil
  end

  for _, raw in ipairs(rawPresets) do
    if type(raw) == "string" then
      local value = noctalia.string.trim(raw)
      local presetPort, presetWidth, presetHeight, presetScale =
        value:match("^([^:]+):(%d+)[xX](%d+)%s*=%s*(%d+%.?%d*)$")
      if presetPort ~= nil then
        if noctalia.string.trim(presetPort) == port
          and tonumber(presetWidth) == width
          and tonumber(presetHeight) == height
          and tonumber(presetScale) > 0 then
          portScale = tonumber(presetScale)
        end
      else
        presetWidth, presetHeight, presetScale =
          value:match("^(%d+)[xX](%d+)%s*=%s*(%d+%.?%d*)$")
        if tonumber(presetWidth) == width
          and tonumber(presetHeight) == height
          and tonumber(presetScale) > 0 then
          globalScale = tonumber(presetScale)
        end
      end
    end
  end
  return portScale or globalScale
end

local function displayLabel(output, connector)
  local make = noctalia.string.trim(output.make or "")
  local model = noctalia.string.trim(output.model or "")
  if make ~= "" and model ~= "" then
    return make .. " " .. model
  elseif model ~= "" then
    return model
  elseif make ~= "" then
    return make
  end
  return connector
end

local function normalizeModes(rawModes)
  local modes = {}
  for _, raw in ipairs(rawModes or {}) do
    local width = tonumber(raw.width)
    local height = tonumber(raw.height)
    local refresh = tonumber(raw.refresh_rate)
    if width ~= nil and height ~= nil and refresh ~= nil then
      table.insert(modes, {
        width = width,
        height = height,
        refresh_rate = refresh,
        preferred = raw.is_preferred == true,
      })
    end
  end
  return modes
end

local function normalizeOutputs(rawOutputs, focusedName, revision)
  local displays = {}
  for connector, raw in pairs(rawOutputs) do
    if type(raw) == "table" then
      local modes = normalizeModes(raw.modes)
      local currentIndex = tonumber(raw.current_mode)
      local currentMode = nil
      if currentIndex ~= nil then
        currentMode = modes[currentIndex + 1]
      end
      local logical = type(raw.logical) == "table" and raw.logical or nil
      table.insert(displays, {
        name = displayLabel(raw, connector),
        port = connector,
        make = raw.make or "",
        model = raw.model or "",
        serial = raw.serial or "",
        focused = connector == focusedName,
        enabled = logical ~= nil and currentMode ~= nil,
        x = logical and (tonumber(logical.x) or 0) or 0,
        y = logical and (tonumber(logical.y) or 0) or 0,
        scale = logical and (tonumber(logical.scale) or 1) or 1,
        width = currentMode and currentMode.width or 0,
        height = currentMode and currentMode.height or 0,
        refresh_rate = currentMode and currentMode.refresh_rate or 0,
        modes = modes,
      })
    end
  end

  table.sort(displays, function(a, b)
    if a.enabled ~= b.enabled then
      return a.enabled
    elseif a.x ~= b.x then
      return a.x < b.x
    elseif a.y ~= b.y then
      return a.y < b.y
    end
    return a.port < b.port
  end)

  return {
    revision = revision,
    status = "ok",
    error_message = "",
    focused_output = focusedName,
    displays = displays,
    updated_at = noctalia.formatTime("%H:%M:%S"),
  }
end

local function commandError(result, fallback)
  if result.timedOut then
    return tr("error.timeout")
  end
  local message = noctalia.string.trim(result.stderr or ""):match("^[^\r\n]*") or ""
  if message ~= "" then
    return message
  end
  return fallback
end

local function applyPresetsForResolutionChanges(snapshot)
  -- A Niri mode switch can temporarily remove an output from `outputs`
  -- altogether. Keep the last mode for known connectors so the reconnect is
  -- still recognized as a resolution change instead of a brand-new display.
  local nextResolutions = {}
  for port, resolution in pairs(lastResolutionByPort) do
    nextResolutions[port] = resolution
  end
  for _, display in ipairs(snapshot.displays) do
    if display.enabled and display.width > 0 and display.height > 0 then
      local resolution = tostring(display.width) .. "x" .. tostring(display.height)
      nextResolutions[display.port] = resolution
      local previous = lastResolutionByPort[display.port]
      if forcePresetCheck or (resolutionStateReady and previous ~= nil and previous ~= resolution) then
        local targetScale = presetFor(display.port, display.width, display.height)
        if targetScale ~= nil and math.abs(display.scale - targetScale) > 0.001
          and presetApplying[display.port] ~= targetScale then
          local port = display.port
          presetApplying[port] = targetScale
          local command = "niri msg output " .. quoteShellArgument(port)
            .. " scale " .. quoteShellArgument(formatScale(targetScale))
          noctalia.log("niri-displays: resolution changed on " .. port .. " to " .. resolution
            .. "; applying scale preset " .. formatScale(targetScale))
          local started = noctalia.runAsync(command, function(result)
            presetApplying[port] = nil
            if result.exitCode ~= 0 then
              noctalia.log("niri-displays: automatic scale failed for " .. port .. ": "
                .. commandError(result, tr("error.command")))
            else
              startRefresh()
            end
          end, COMMAND_TIMEOUT_MS)
          if not started then
            presetApplying[port] = nil
            noctalia.log("niri-displays: could not start automatic scale command for " .. port)
          end
        end
      end
    end
  end
  lastResolutionByPort = nextResolutions
  resolutionStateReady = true
  forcePresetCheck = false
end

local function syncFocusedOutput()
  local focusedName = noctalia.focusedOutputName()
  if type(focusedName) ~= "string" or focusedName == "" then
    return
  end
  local current = noctalia.state.get(STATE_KEY)
  if type(current) ~= "table" or type(current.displays) ~= "table"
    or current.focused_output == focusedName then
    return
  end

  local nextSnapshot = shallowCopy(current)
  nextSnapshot.focused_output = focusedName
  nextSnapshot.displays = {}
  for _, display in ipairs(current.displays) do
    local nextDisplay = shallowCopy(display)
    nextDisplay.focused = display.port == focusedName
    table.insert(nextSnapshot.displays, nextDisplay)
  end
  noctalia.state.set(STATE_KEY, nextSnapshot)
end

startRefresh = function()
  if fetching then
    refreshQueued = true
    return
  end
  if not noctalia.commandExists("niri") then
    noctalia.state.set(STATE_KEY, initialSnapshot("error", tr("error.niri_missing")))
    return
  end

  fetching = true
  lastFullRefreshAt = tonumber(noctalia.formatTime("%s")) or 0
  generation += 1
  local thisGeneration = generation
  local pending = 2
  local rawOutputs = nil
  local focusedName = nil
  local outputsError = ""

  local previous = shallowCopy(noctalia.state.get(STATE_KEY))
  previous.status = #previous.displays > 0 and "refreshing" or "loading"
  previous.error_message = ""
  noctalia.state.set(STATE_KEY, previous)

  local function completeOne()
    if thisGeneration ~= generation then
      return
    end
    pending -= 1
    if pending > 0 then
      return
    end

    fetching = false
    if rawOutputs == nil then
      local stale = shallowCopy(noctalia.state.get(STATE_KEY))
      stale.status = "error"
      stale.error_message = outputsError ~= "" and outputsError or tr("error.outputs")
      noctalia.state.set(STATE_KEY, stale)
    else
      local nextSnapshot = normalizeOutputs(rawOutputs, focusedName, thisGeneration)
      applyPresetsForResolutionChanges(nextSnapshot)
      noctalia.state.set(STATE_KEY, nextSnapshot)
    end

    if refreshQueued then
      refreshQueued = false
      startRefresh()
    end
  end

  local outputsStarted = noctalia.runAsync("niri msg --json outputs", function(result)
    if thisGeneration ~= generation then
      return
    end
    if result.exitCode == 0 and not result.stdoutTruncated then
      local decoded = noctalia.json.decode(result.stdout or "")
      if type(decoded) == "table" then
        rawOutputs = decoded
      else
        outputsError = tr("error.parse_outputs")
      end
    else
      outputsError = commandError(result, tr("error.outputs"))
    end
    completeOne()
  end, COMMAND_TIMEOUT_MS)
  if not outputsStarted then
    outputsError = tr("error.outputs")
    completeOne()
  end

  local focusStarted = noctalia.runAsync("niri msg --json focused-output", function(result)
    if thisGeneration ~= generation then
      return
    end
    if result.exitCode == 0 and not result.stdoutTruncated then
      local decoded = noctalia.json.decode(result.stdout or "")
      if type(decoded) == "table" and type(decoded.name) == "string" then
        focusedName = decoded.name
      end
    end
    completeOne()
  end, COMMAND_TIMEOUT_MS)
  if not focusStarted then
    completeOne()
  end
end

noctalia.setUpdateInterval(FOCUS_CHECK_INTERVAL_MS)

noctalia.state.watch("refresh_requested", function(value)
  local nonce = tonumber(value) or 0
  if nonce ~= lastRefreshNonce then
    lastRefreshNonce = nonce
    startRefresh()
  end
end)

noctalia.state.set(STATE_KEY, initialSnapshot("loading", ""))
startRefresh()

function update()
  syncFocusedOutput()
  if (tonumber(noctalia.formatTime("%s")) or 0) - lastFullRefreshAt >= readFallbackIntervalSeconds() then
    startRefresh()
  end
end

function onConfigChanged()
  forcePresetCheck = true
  startRefresh()
end

-- Native Noctalia service hook. Niri output mode, scale, and hotplug changes
-- propagate through wl_output and arrive here without waiting for the fallback
-- polling interval.
function onOutputsChanged()
  noctalia.log("niri-displays: output change hook")
  startRefresh()
end

function onIpc(event, _payload)
  if event == "refresh" then
    startRefresh()
  elseif event == "dump" then
    local snapshot = noctalia.state.get(STATE_KEY)
    noctalia.log("niri-displays: " .. (noctalia.json.encode(snapshot) or "?"))
  end
end
