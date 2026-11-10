--!nonstrict
-- Wallpaper Brightness background service

local MIN_BRIGHTNESS = 10
local MAX_BRIGHTNESS = 150
local STEP_BRIGHTNESS = 5

local pluginDir = noctalia.pluginDir()
local dataDir = noctalia.pluginDataDir()
local helperScript = pluginDir .. "/adjust_wallpaper.py"
local stateFile = dataDir .. "/originals.json"

local originals = {}
local appliedBrightness = {}
local appliedSource = {}
local inFlight = {}
local pendingSync = {}
local generation = 0

local function clampBrightness(val)
  local n = tonumber(val) or 100
  n = math.floor((n + (STEP_BRIGHTNESS / 2)) / STEP_BRIGHTNESS) * STEP_BRIGHTNESS
  if n < MIN_BRIGHTNESS then
    return MIN_BRIGHTNESS
  end
  if n > MAX_BRIGHTNESS then
    return MAX_BRIGHTNESS
  end
  return n
end

local currentBrightness = clampBrightness(noctalia.getConfig("brightness") or 100)

local function sanitizeConnector(name)
  return (tostring(name or "default"):gsub("[^%w_%-]", "_"))
end

local function isGeneratedPath(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  if dataDir ~= "" and path:sub(1, #dataDir) == dataDir then
    return true
  end
  local base = path:match("([^/]+)$") or ""
  return base:match("^wallpaper_") ~= nil or base:match("^wp_dim_") ~= nil
end

local function loadState()
  if not noctalia.fileExists(stateFile) then
    return
  end
  local raw = noctalia.readFile(stateFile)
  if type(raw) ~= "string" or raw == "" then
    return
  end
  local ok, decoded = pcall(noctalia.json.decode, raw)
  if ok and type(decoded) == "table" then
    if type(decoded.originals) == "table" then
      for k, v in pairs(decoded.originals) do
        if type(k) == "string" and type(v) == "string" and v ~= "" and not isGeneratedPath(v) then
          originals[k] = v
        end
      end
    end
    if decoded.brightness ~= nil then
      local savedB = tonumber(decoded.brightness)
      if savedB then
        currentBrightness = clampBrightness(savedB)
      end
    end
    if type(decoded.applied) == "table" then
      for k, v in pairs(decoded.applied) do
        if type(k) == "string" and type(v) == "table" then
          if v.brightness ~= nil then
            appliedBrightness[k] = tonumber(v.brightness)
          end
          if type(v.source) == "string" and v.source ~= "" then
            appliedSource[k] = v.source
          end
        end
      end
    end
  end
end

local function saveState()
  noctalia.mkdirAll(dataDir)
  local appliedData = {}
  for k, b in pairs(appliedBrightness) do
    if type(k) == "string" and b ~= nil then
      appliedData[k] = {
        brightness = b,
        source = appliedSource[k] or "",
      }
    end
  end

  local ok, encoded = pcall(noctalia.json.encode, {
    originals = originals,
    brightness = currentBrightness,
    applied = appliedData,
  })
  if ok and type(encoded) == "string" then
    noctalia.writeFile(stateFile, encoded)
  end
end

local function publishState(busy)
  noctalia.state.set("brightness", tostring(currentBrightness))
  noctalia.state.set("busy", busy and "true" or "false")
end

local syncOutput

syncOutput = function(connector, force)
  if type(connector) ~= "string" or connector == "" then
    return
  end

  local livePath = noctalia.wallpaperPath(connector)
  if type(livePath) == "string" and livePath ~= "" and not isGeneratedPath(livePath) then
    if originals[connector] ~= livePath then
      originals[connector] = livePath
      saveState()
    end
  end

  local origPath = originals[connector]
  if type(origPath) ~= "string" or origPath == "" or not noctalia.fileExists(origPath) then
    return
  end

  local targetB = currentBrightness

  -- At 100%, restore the original unmodified wallpaper directly
  if targetB == 100 then
    pendingSync[connector] = false
    if livePath == origPath and appliedBrightness[connector] == 100 then
      return
    end
    appliedBrightness[connector] = 100
    appliedSource[connector] = origPath
    saveState()
    noctalia.setWallpaper(connector, origPath)
    return
  end

  -- If the wallpaper currently displayed on this monitor is already the generated file
  -- for this exact brightness level and original image, DO NOTHING.
  -- This prevents any redundant processing or transition trigger during boot/login.
  if isGeneratedPath(livePath or "") and noctalia.fileExists(livePath or "") then
    if appliedBrightness[connector] == targetB and appliedSource[connector] == origPath then
      return
    end
  end

  -- If already in flight for this connector, queue one subsequent sync when finished
  if inFlight[connector] then
    pendingSync[connector] = true
    return
  end

  noctalia.mkdirAll(dataDir)
  generation = generation + 1
  local safeConn = sanitizeConnector(connector)
  local prefix = "wallpaper_" .. safeConn .. "_"
  local dstPath = dataDir .. "/" .. prefix .. tostring(os.time()) .. "_" .. tostring(generation) .. "_" .. tostring(targetB) .. ".jpg"

  inFlight[connector] = true
  publishState(true)

  local ok = noctalia.runAsync(
    { "python3", "-B", helperScript, origPath, dstPath, tostring(targetB), prefix },
    function(result)
      inFlight[connector] = false
      local anyBusy = false
      for _, busy in pairs(inFlight) do
        if busy then
          anyBusy = true
          break
        end
      end
      publishState(anyBusy)

      if type(result) == "table" and result.exitCode == 0 and noctalia.fileExists(dstPath) then
        appliedBrightness[connector] = targetB
        appliedSource[connector] = origPath
        saveState()

        -- Only apply if brightness hasn't changed while processing
        if currentBrightness == 100 then
          noctalia.setWallpaper(connector, origPath)
          appliedBrightness[connector] = 100
          saveState()
        elseif currentBrightness == targetB then
          noctalia.setWallpaper(connector, dstPath)
        end
      else
        local err = type(result) == "table" and noctalia.string.trim(result.stderr or "") or "process error"
        noctalia.log("wallpaper-brightness error on " .. connector .. ": " .. err)
      end

      if pendingSync[connector] or currentBrightness ~= targetB then
        pendingSync[connector] = false
        syncOutput(connector, true)
      end
    end,
    10000
  )

  if not ok then
    inFlight[connector] = false
    publishState(false)
  end
end

local function syncAllOutputs(force)
  local outs = noctalia.outputs() or {}
  for _, out in ipairs(outs) do
    if out and type(out.name) == "string" and out.name ~= "" then
      syncOutput(out.name, force)
    end
  end
end

local function setBrightnessLevel(newLevel)
  local clamped = clampBrightness(newLevel)
  if clamped == currentBrightness and appliedBrightness then
    local allMatch = true
    local outs = noctalia.outputs() or {}
    for _, out in ipairs(outs) do
      if out and out.name and appliedBrightness[out.name] ~= clamped then
        allMatch = false
        break
      end
    end
    if allMatch then
      publishState(false)
      return
    end
  end
  currentBrightness = clamped
  saveState()
  publishState(false)
  syncAllOutputs(true)
end

local function handleCommand(rawCmd)
  if type(rawCmd) ~= "string" or rawCmd == "" then
    return
  end
  local action, arg = rawCmd:match("^([A-Z_]+):?(.*)$")
  if not action then
    return
  end
  noctalia.state.set("cmd", "")

  if action == "SET" then
    setBrightnessLevel(tonumber(arg) or 100)
  elseif action == "STEP" then
    local delta = tonumber(arg) or STEP_BRIGHTNESS
    setBrightnessLevel(currentBrightness + delta)
  elseif action == "RESET" then
    setBrightnessLevel(100)
  end
end

function onConfigChanged()
  local cfgBrightness = clampBrightness(noctalia.getConfig("brightness") or 100)
  if cfgBrightness ~= currentBrightness then
    setBrightnessLevel(cfgBrightness)
  end
end

function onOutputsChanged()
  syncAllOutputs(false)
end

function onIpc(event, payload)
  local ev = noctalia.string.trim(event or ""):lower()
  local arg = noctalia.string.trim(payload or "")
  if ev == "set" then
    setBrightnessLevel(tonumber(arg) or 100)
  elseif ev == "up" or ev == "increase" then
    local step = tonumber(arg) or STEP_BRIGHTNESS
    setBrightnessLevel(currentBrightness + step)
  elseif ev == "down" or ev == "decrease" then
    local step = tonumber(arg) or STEP_BRIGHTNESS
    setBrightnessLevel(currentBrightness - step)
  elseif ev == "reset" then
    setBrightnessLevel(100)
  end
end

function onExit(_signal, reason)
  if reason == "disable" or reason == "uninstall" then
    for connector, origPath in pairs(originals) do
      if type(origPath) == "string" and origPath ~= "" and noctalia.fileExists(origPath) then
        noctalia.setWallpaper(connector, origPath)
      end
    end
  end
end

function update()
  local pendingCmd = noctalia.state.get("cmd")
  if pendingCmd and pendingCmd ~= "" then
    handleCommand(pendingCmd)
  end
  syncAllOutputs(false)
end

-- Initialize
noctalia.mkdirAll(dataDir)
loadState()
currentBrightness = clampBrightness(noctalia.getConfig("brightness") or currentBrightness or 100)
publishState(false)
noctalia.setUpdateInterval(1500)
noctalia.state.watch("cmd", function(val)
  if val and val ~= "" then
    handleCommand(val)
  end
end)
-- Safe non-forcing initial sync: if the wallpaper already matches, zero work and zero transition trigger!
syncAllOutputs(false)
