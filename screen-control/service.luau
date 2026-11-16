--!nonstrict
-- Screen Control service: reads each monitor's brightness, keeps the dim levels and
-- applies them, and reads and sets night light.
--
-- Brightness and night light belong to Noctalia: they are set with `noctalia msg`, and night
-- light is read back from Noctalia's settings. Noctalia has no way to read brightness, so
-- the built-in display's is read from sysfs, and an external monitor's with ddcutil.
--
-- Dimming lowers hyprsunset's gamma when hyprsunset is installed: real dimming, which
-- screenshots do not show, but one level for all monitors. Elsewhere it draws the black
-- "dim" layer over each monitor.
--
-- Publishes "screen-control.model" and takes commands on "screen-control.command".

local Level = require("./lib/level.luau")

local DIM_LAYER = "dim"
local DDC_REFRESH_MS = 30000
-- After a change, the read-back value may lag; reading waits this long.
local SETTLE_MS = 1500

local dataFile = (noctalia.pluginDataDir() or "") .. "/dims.json"

local monitors = {} -- { name, label, internal, brightness, bus }, in noctalia.outputs() order
local dims = {} -- dim level by key: "output:<name>" or "all", or "workspace:<name>" per workspace
local workspaces = {} -- active workspace name by output name
local focused = nil -- focused output name, from hyprctl
local gamma = nil -- the gamma last sent to hyprsunset, in percent
local gammaStartedMs = -10000
-- Noctalia's caffeine. Noctalia does not report it to plugins, but while it is on, Noctalia
-- holds a logind idle inhibitor named "Caffeine", which systemd-inhibit lists.
local caffeine = false
local backlight = nil -- { output, path, max }
local lastSetMs = {}
local lastDdcMs = -DDC_REFRESH_MS
local pending = {} -- latest value to send, by command key
local sending = {}

local function perWorkspace()
  return noctalia.getConfig("per_workspace") and noctalia.commandExists("hyprctl")
end

-- Gamma when chosen and hyprsunset is there; the black layer otherwise.
local function useGamma()
  return noctalia.getConfig("dim_method") ~= "overlay"
    and noctalia.commandExists("hyprsunset") and noctalia.commandExists("hyprctl")
end

-- With gamma, one level covers all monitors; per workspace, it is the focused one's.
local function dimKey(name)
  if useGamma() then
    name = focused or noctalia.focusedOutputName() or name
  end
  local workspace = workspaces[name]
  if perWorkspace() and workspace then
    return "workspace:" .. workspace
  end
  return useGamma() and "all" or "output:" .. name
end

local function findMonitor(name)
  for _, monitor in ipairs(monitors) do
    if monitor.name == name then
      return monitor
    end
  end
  return nil
end

-- Runs one command per key at a time and drops values that a newer one replaced, so a
-- dragged slider does not queue up dozens of commands.
local function send(key, argv, onDone)
  pending[key] = { argv = argv, onDone = onDone }
  if sending[key] then
    return
  end
  local job = pending[key]
  pending[key] = nil
  sending[key] = true
  noctalia.runAsync(job.argv, function(result)
    sending[key] = false
    if job.onDone then
      job.onDone(result)
    end
    local nextJob = pending[key]
    if nextJob then
      send(key, nextJob.argv, nextJob.onDone)
    end
  end, 10000)
end

-- Starts hyprsunset when it is not running, with no color change and the wanted gamma.
local function setGamma(percent)
  if percent == gamma then
    return
  end
  gamma = percent
  send("gamma", { "hyprctl", "hyprsunset", "gamma", tostring(percent) }, function(result)
    if result.exitCode == 0 or percent >= 100 then
      return
    end
    if noctalia.nowMs() - gammaStartedMs > 3000 then
      gammaStartedMs = noctalia.nowMs()
      noctalia.runAsync({ "hyprsunset", "--identity", "--gamma", tostring(percent) })
    else
      -- It is still starting; update() tries again.
      gamma = nil
    end
  end)
end

local function nightMode()
  if not noctalia.getSetting("nightlight.enabled") then
    return "off"
  end
  return noctalia.getSetting("nightlight.force") and "on" or "scheduled"
end

local function publish()
  local model = { monitors = {}, perWorkspace = perWorkspace() and true or false }
  local anyDim = false
  for _, monitor in ipairs(monitors) do
    local dim = dims[dimKey(monitor.name)] or 0
    anyDim = anyDim or dim > 0
    table.insert(model.monitors, {
      name = monitor.name,
      label = monitor.label,
      internal = monitor.internal,
      brightness = monitor.brightness,
      dim = dim,
      workspace = workspaces[monitor.name],
    })
  end
  local location = noctalia.getSetting("location") or {}
  model.night = {
    mode = nightMode(),
    temperature = noctalia.getSetting("nightlight.temperature_night") or 4000,
    custom = location.custom_schedule == true,
    start = location.sunset or "",
    finish = location.sunrise or "",
    place = type(location.address) == "string" and location.address or "",
  }
  model.sharedDim = useGamma()
  model.caffeine = caffeine
  noctalia.state.set("screen-control.model", model)
  if useGamma() then
    noctalia.layer.hide(DIM_LAYER)
    setGamma(math.floor((1 - (dims[dimKey("")] or 0)) * 100 + 0.5))
    return
  end
  -- Switched to the layer: gamma goes back to full first.
  if gamma and gamma < 100 then
    setGamma(100)
  end
  if anyDim then
    noctalia.layer.show(DIM_LAYER)
  else
    noctalia.layer.hide(DIM_LAYER)
  end
end

local function save()
  local text = noctalia.json.encode({ dims = dims })
  if text then
    noctalia.writeFile(dataFile, text)
  end
end

local function setBrightness(monitor, value)
  monitor.brightness = value
  lastSetMs[monitor.name] = noctalia.nowMs()
  send("brightness:" .. monitor.name,
    { "noctalia", "msg", "brightness-set", monitor.name, string.format("%.3f", value) })
end

local function setLevel(name, level)
  local monitor = findMonitor(name)
  if monitor == nil then
    return
  end
  local brightness, dim = Level.toScreen(level, monitor.brightness ~= nil)
  if brightness and math.abs(brightness - monitor.brightness) > 0.001 then
    setBrightness(monitor, brightness)
  end
  local key = dimKey(name)
  dims[key] = dim > 0.005 and dim or nil
  save()
end

local function step(name, delta)
  local monitor = findMonitor(name)
  if monitor then
    local dim = dims[dimKey(name)] or 0
    local level = Level.fromScreen(monitor.brightness, dim)
    -- A monitor dimmed with its slider steps up out of it, but no deeper into it.
    local floor = math.min(Level.stepFloor(monitor.brightness ~= nil), level)
    setLevel(name, math.max(level + delta, floor))
  end
end

-- The brightness slider: from the lowest to full brightness. Above the lowest, no dim.
local function setShare(name, share)
  local monitor = findMonitor(name)
  if monitor == nil or monitor.brightness == nil then
    return
  end
  local brightness = Level.fromShare(share)
  if math.abs(brightness - monitor.brightness) > 0.001 then
    setBrightness(monitor, brightness)
  end
  if share > 0.001 and dims[dimKey(name)] then
    dims[dimKey(name)] = nil
    save()
  end
end

-- The extra dim slider: 1 is no dim, 0 the darkest. It keeps the lowest brightness.
local function setDim(name, value)
  local monitor = findMonitor(name)
  if monitor == nil then
    return
  end
  local dim = Level.maxDim() * (1 - math.clamp(value, 0, 1))
  if monitor.brightness ~= nil and dim > 0.005 and math.abs(monitor.brightness - Level.minBrightness()) > 0.001 then
    setBrightness(monitor, Level.minBrightness())
  end
  dims[dimKey(name)] = dim > 0.005 and dim or nil
  save()
end

-- Settings are written one at a time, in order: each write reloads Noctalia's config.
-- A newer value for a path that still waits replaces the older one.
local configQueue = {}
local configBusy = false

local function nextConfig()
  local item = table.remove(configQueue, 1)
  if item == nil then
    configBusy = false
    return
  end
  configBusy = true
  noctalia.runAsync({ "noctalia", "msg", "config-set", item.path, item.value }, nextConfig, 10000)
end

local function configSet(path, value)
  for _, item in ipairs(configQueue) do
    if item.path == path then
      item.value = tostring(value)
      return
    end
  end
  table.insert(configQueue, { path = path, value = tostring(value) })
  if not configBusy then
    nextConfig()
  end
end

local function setNightMode(mode)
  configSet("nightlight.enabled", mode ~= "off")
  configSet("nightlight.force", mode == "on")
end

local function setCaffeine(on)
  caffeine = on
  noctalia.runAsync({ "noctalia", "msg", on and "caffeine-enable" or "caffeine-disable" })
end

local function readCaffeine()
  if not noctalia.commandExists("systemd-inhibit") then
    return
  end
  noctalia.runAsync({ "systemd-inhibit", "--list", "--no-pager", "--no-legend" }, function(result)
    local on = false
    for line in (result.stdout or ""):gmatch("[^\n]+") do
      if line:match("^noctalia%s") and line:match("%sidle%s") and line:match("Caffeine") then
        on = true
      end
    end
    if on ~= caffeine then
      caffeine = on
      publish()
    end
  end)
end

local function isTime(text)
  local hours, minutes = (text or ""):match("^(%d%d?):(%d%d)$")
  return hours ~= nil and tonumber(hours) < 24 and tonumber(minutes) < 60
end

-- The schedule lives in Noctalia's [location]: sunset to sunrise there, or custom times.
-- Custom times start from 20:30 to 07:30 when none are set.
local function setSchedule(command)
  local location = noctalia.getSetting("location") or {}
  if type(command.custom) == "boolean" then
    -- Noctalia turns custom times off again while they are empty, so they are set first.
    if command.custom and not isTime(location.sunset) then
      configSet("location.sunset", '"20:30"')
    end
    if command.custom and not isTime(location.sunrise) then
      configSet("location.sunrise", '"07:30"')
    end
    configSet("location.custom_schedule", command.custom)
  elseif (command.key == "sunset" or command.key == "sunrise") and isTime(command.value) then
    configSet("location." .. command.key, `"{command.value}"`)
  end
end

local function readBacklight()
  if backlight == nil then
    return
  end
  local monitor = findMonitor(backlight.output)
  if monitor == nil or noctalia.nowMs() - (lastSetMs[monitor.name] or 0) < SETTLE_MS then
    return
  end
  noctalia.readFileAsync(backlight.path .. "/brightness", function(text)
    local raw = tonumber(text and noctalia.string.trim(text) or "")
    if raw and noctalia.nowMs() - (lastSetMs[monitor.name] or 0) >= SETTLE_MS then
      local value = math.clamp(raw / backlight.max, 0, 1)
      if monitor.brightness == nil or math.abs(monitor.brightness - value) > 0.001 then
        monitor.brightness = value
        publish()
      end
    end
  end)
end

-- Noctalia picks the backlight of the built-in display the same way: the one named in
-- its settings, otherwise the first one.
local function findBacklight()
  local internal = nil
  for _, monitor in ipairs(monitors) do
    if monitor.internal then
      internal = monitor
      break
    end
  end
  if internal == nil then
    return
  end
  local function use(device)
    local path = device:find("/") and device or "/sys/class/backlight/" .. device
    noctalia.readFileAsync(path .. "/max_brightness", function(text)
      local max = tonumber(text and noctalia.string.trim(text) or "")
      if max and max > 0 then
        backlight = { output = internal.name, path = path, max = max }
        readBacklight()
      end
    end)
  end
  -- The whole table, since asking for a missing key logs a warning.
  local settings = noctalia.getSetting("brightness") or {}
  local perMonitor = type(settings.monitor) == "table" and settings.monitor[internal.name] or nil
  local configured = type(perMonitor) == "table" and perMonitor.backlight_device or nil
  if type(configured) == "string" and configured ~= "" then
    use(configured)
    return
  end
  noctalia.runAsync({ "noctalia", "msg", "brightness-list-backlight-devices" }, function(result)
    local first = result.exitCode == 0 and (result.stdout or ""):match("^%s*(%S+)")
    if first and first ~= "error:" then
      use(first)
    end
  end)
end

-- ddcutil reads an external monitor's brightness. Noctalia sets it with ddcutil too, so it
-- is only read when Noctalia's ddcutil support is on.
local function readDdc()
  if not noctalia.getSetting("brightness.enable_ddcutil") or not noctalia.commandExists("ddcutil") then
    return
  end
  lastDdcMs = noctalia.nowMs()
  local function readBus(monitor)
    noctalia.runAsync({ "ddcutil", "--noconfig", "--bus", tostring(monitor.bus), "getvcp", "10", "--brief" },
      function(result)
        local current, max = (result.stdout or ""):match("VCP 10 C (%d+) (%d+)")
        current, max = tonumber(current), tonumber(max)
        if current and max and max > 0 and noctalia.nowMs() - (lastSetMs[monitor.name] or 0) >= SETTLE_MS then
          monitor.brightness = math.clamp(current / max, 0, 1)
          publish()
        end
      end, 20000)
  end
  noctalia.runAsync({ "ddcutil", "--noconfig", "detect", "--brief" }, function(result)
    -- Each display is a block: "Display 1", then "I2C bus: /dev/i2c-6" and
    -- "DRM connector: card1-DP-1". Blocks that are not "Display N" cannot be controlled.
    for block in ((result.stdout or "") .. "\n\n"):gmatch("(.-)\n%s*\n") do
      local bus = block:match("^%s*Display %d+.-I2C bus:%s*/dev/i2c%-(%d+)")
      local connector = block:match("DRM connector:%s*card%d+%-(%S+)")
      local monitor = connector and findMonitor(connector)
      if bus and monitor and not monitor.internal then
        monitor.bus = tonumber(bus)
        readBus(monitor)
      end
    end
  end, 20000)
end

local function isInternal(name)
  return name:match("^eDP") or name:match("^LVDS") or name:match("^DSI")
end

-- A monitor the owner left out in the settings, by its connector or part of its name.
local function skipped(output)
  for _, entry in ipairs(noctalia.getConfig("skip_monitors") or {}) do
    local wanted = noctalia.string.trim(entry):lower()
    if wanted ~= "" and (output.name:lower() == wanted
      or (output.description or ""):lower():find(wanted, 1, true)) then
      return true
    end
  end
  return false
end

local function loadOutputs()
  local old = {}
  for _, monitor in ipairs(monitors) do
    old[monitor.name] = monitor
  end
  monitors = {}
  for _, output in ipairs(noctalia.outputs()) do
    if skipped(output) then
      continue
    end
    local internal = isInternal(output.name) and true or false
    local label = internal and noctalia.tr("monitor.builtin")
      or (output.description ~= "" and output.description or output.name)
    local previous = old[output.name]
    table.insert(monitors, {
      name = output.name,
      label = label,
      internal = internal,
      brightness = previous and previous.brightness,
      bus = previous and previous.bus,
    })
  end
  backlight = nil
  findBacklight()
  readDdc()
  publish()
end

local function readWorkspaces()
  if not perWorkspace() then
    if next(workspaces) then
      workspaces = {}
      publish()
    end
    return
  end
  noctalia.runAsync({ "hyprctl", "-j", "monitors" }, function(result)
    local list = result.exitCode == 0 and noctalia.json.decode(result.stdout or "")
    if type(list) ~= "table" then
      return
    end
    local changed = false
    for _, item in ipairs(list) do
      local workspace = type(item.activeWorkspace) == "table" and item.activeWorkspace.name or nil
      if type(item.name) == "string" and workspaces[item.name] ~= workspace then
        workspaces[item.name] = workspace
        changed = true
      end
      if item.focused == true and focused ~= item.name then
        focused = item.name
        changed = true
      end
    end
    if changed then
      publish()
    end
  end)
end

local function handle(command)
  if type(command) ~= "table" then
    return
  end
  local action = command.action
  if action == "step" and type(command.delta) == "number" then
    step(command.output, command.delta)
  elseif action == "brightness" and type(command.value) == "number" then
    setShare(command.output, command.value)
  elseif action == "dim" and type(command.value) == "number" then
    setDim(command.output, command.value)
  elseif action == "night" then
    setNightMode(command.mode)
  elseif action == "caffeine" then
    if type(command.on) == "boolean" then
      setCaffeine(command.on)
    else
      setCaffeine(not caffeine)
    end
  elseif action == "schedule" then
    setSchedule(command)
  elseif action == "temperature" and type(command.value) == "number" then
    configSet("nightlight.temperature_night", math.floor(command.value))
  elseif action == "refresh" and noctalia.nowMs() - lastDdcMs >= DDC_REFRESH_MS then
    readDdc()
  end
  publish()
end

noctalia.state.watch("screen-control.command", handle)

-- noctalia msg plugin omerfuyar/screen-control:service all up [percent]
-- noctalia msg plugin omerfuyar/screen-control:service all down [percent]
-- noctalia msg plugin omerfuyar/screen-control:service all night off|scheduled|on
-- noctalia msg plugin omerfuyar/screen-control:service all caffeine
-- Moves the focused monitor along the scale; "down" stops at the lowest brightness, unless
-- the step_dims setting lets it go on into dimming.
function onIpc(event, payload)
  if event == "caffeine" then
    setCaffeine(not caffeine)
    publish()
    return
  elseif event == "night" then
    if payload == "off" or payload == "scheduled" or payload == "on" then
      setNightMode(payload)
    end
    return
  elseif event ~= "up" and event ~= "down" then
    return
  end
  local name = noctalia.focusedOutputName()
  if name == nil then
    return
  end
  local percent = tonumber(payload or "")
  local amount = percent and percent / 100 or Level.STEP
  step(name, event == "up" and amount or -amount)
  publish()
end

local lastNight = nil

local lastCaffeineMs = 0

function update()
  if gamma == nil and useGamma() then
    publish()
  end
  -- Caffeine can change in Noctalia's own menu; it is read every 2 seconds.
  if noctalia.nowMs() - lastCaffeineMs >= 2000 then
    lastCaffeineMs = noctalia.nowMs()
    readCaffeine()
  end
  readBacklight()
  readWorkspaces()
  -- Night light can change in Noctalia's own settings.
  local location = noctalia.getSetting("location") or {}
  local night = `{nightMode()}{noctalia.getSetting("nightlight.temperature_night")}`
    .. `{location.custom_schedule}{location.sunset}{location.sunrise}`
  if night ~= lastNight then
    lastNight = night
    publish()
  end
end

local skipText = nil

function onConfigChanged()
  noctalia.setUpdateInterval(perWorkspace() and 300 or 1000)
  -- The monitors are read again only when the list to leave out changed.
  local text = table.concat(noctalia.getConfig("skip_monitors") or {}, "\n")
  if text ~= skipText then
    skipText = text
    loadOutputs()
  end
  readWorkspaces()
  publish()
end

-- Gamma stays where hyprsunset has it, so it goes back to full when the plugin stops.
function onExit()
  if useGamma() and gamma and gamma < 100 then
    noctalia.runAsync({ "hyprctl", "hyprsunset", "gamma", "100" })
  end
end

function onOutputsChanged()
  loadOutputs()
end

noctalia.readFileAsync(dataFile, function(text)
  local saved = text and noctalia.json.decode(text)
  if type(saved) == "table" and type(saved.dims) == "table" then
    dims = saved.dims
  end
  loadOutputs()
  onConfigChanged()
end)
