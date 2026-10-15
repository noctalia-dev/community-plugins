--!nonstrict
-- MacBook Fan & Thermal Background Service
-- High-efficiency background service for sysfs hardware telemetry and fan controls.
-- Publishes live state to 'macbook_fan.snapshot'.

local SNAPSHOT = "macbook_fan.snapshot"
local COMMAND = "macbook_fan.command"

local snapshot = {
  rpm = 0,
  min_rpm = 1200,
  max_rpm = 6500,
  target_rpm = 1200,
  percent = 0,
  temp = 0,
  daemon_active = false,
  driver_available = false,
  control_mode = "auto", -- "auto" | "manual"
  display_mode = "rpm", -- "rpm" | "percent" | "both"
  onboarded = false,
  version = "1.2.0",
}

local lastPublished = {
  rpm = -1,
  temp = -1,
  daemon_active = nil,
  driver_available = nil,
  control_mode = nil,
  display_mode = nil,
  target_rpm = -1,
  onboarded = nil,
}

local reading = false
local discovered = false
local applesmcDir = nil
local tempFile = nil

local function getPluginDir()
  return noctalia.pluginDir() or ""
end

local function shellQuote(str)
  return "'" .. string.gsub(str, "'", "'\\''") .. "'"
end

local function getOnboardFile()
  local ok, dataDir = pcall(noctalia.pluginDataDir)
  if ok and dataDir and dataDir ~= "" then
    return dataDir .. "/.onboarded"
  end
  return getPluginDir() .. "/.onboarded"
end

local function makeDiscoveryCmd()
  local dir = getPluginDir()
  local onboardPath = getOnboardFile()
  return "for d in /sys/devices/platform/applesmc.*; do [ -d \"$d\" ] && echo \"$d\" && break; done; "
    .. "for f in /sys/devices/platform/coretemp.0/hwmon/hwmon*/temp1_input /sys/class/thermal/thermal_zone0/temp; do [ -f \"$f\" ] && echo \"$f\" && break; done; "
    .. "cat /sys/devices/platform/applesmc.*/fan1_min 2>/dev/null || echo 1200; "
    .. "cat /sys/devices/platform/applesmc.*/fan1_max 2>/dev/null || echo 6500; "
    .. "([ -f \"" .. onboardPath .. "\" ] || [ -f \"" .. dir .. "/.onboarded\" ]) && echo \"done\" || echo \"\"; "
    .. "grep -m1 '^version' \"" .. dir .. "/plugin.toml\" 2>/dev/null | cut -d'\"' -f2 || echo \"1.2.0\""
end

local function makePollCmd()
  if not discovered or not applesmcDir or not tempFile then
    return makeDiscoveryCmd()
  end
  return string.format(
    "cat %s/fan1_input %s/fan1_manual %s/fan1_output %s 2>/dev/null; [ -f /run/mbpfan.pid ] && echo active || systemctl is-active mbpfan 2>/dev/null",
    applesmcDir,
    applesmcDir,
    applesmcDir,
    tempFile
  )
end

local function publish()
  -- Performance dirty check: skip state broadcast if user-facing properties haven't changed
  if lastPublished.rpm == snapshot.rpm
     and lastPublished.temp == snapshot.temp
     and lastPublished.daemon_active == snapshot.daemon_active
     and lastPublished.driver_available == snapshot.driver_available
     and lastPublished.control_mode == snapshot.control_mode
     and lastPublished.display_mode == snapshot.display_mode
     and lastPublished.target_rpm == snapshot.target_rpm
     and lastPublished.onboarded == snapshot.onboarded then
    return
  end

  lastPublished.rpm = snapshot.rpm
  lastPublished.temp = snapshot.temp
  lastPublished.daemon_active = snapshot.daemon_active
  lastPublished.driver_available = snapshot.driver_available
  lastPublished.control_mode = snapshot.control_mode
  lastPublished.display_mode = snapshot.display_mode
  lastPublished.target_rpm = snapshot.target_rpm
  lastPublished.onboarded = snapshot.onboarded

  noctalia.state.set(SNAPSHOT, {
    rpm = snapshot.rpm,
    min_rpm = snapshot.min_rpm,
    max_rpm = snapshot.max_rpm,
    target_rpm = snapshot.target_rpm,
    percent = snapshot.percent,
    temp = snapshot.temp,
    daemon_active = snapshot.daemon_active,
    driver_available = snapshot.driver_available,
    control_mode = snapshot.control_mode,
    display_mode = snapshot.display_mode,
    onboarded = snapshot.onboarded,
    version = snapshot.version,
  })
end

local function parseDiscovery(stdout)
  local lines = {}
  for line in stdout:gmatch("[^\r\n]+") do
    table.insert(lines, noctalia.string.trim(line))
  end

  if #lines >= 4 and lines[1]:find("applesmc") then
    applesmcDir = lines[1]
    tempFile = lines[2]
    snapshot.min_rpm = tonumber(lines[3]) or 1200
    snapshot.max_rpm = tonumber(lines[4]) or 6500

    local onboardVer = lines[5] or ""
    local pluginVer = lines[6] or "1.2.0"
    if pluginVer ~= "" then
      snapshot.version = pluginVer
    end
    snapshot.onboarded = (onboardVer ~= "" and onboardVer == snapshot.version)
    discovered = true
    snapshot.driver_available = true
  else
    discovered = false
    snapshot.driver_available = false
  end
end

local function parsePoll(stdout)
  local lines = {}
  for line in stdout:gmatch("[^\r\n]+") do
    table.insert(lines, noctalia.string.trim(line))
  end

  if #lines < 4 then
    -- Telemetry failed or sysfs path invalid, mark for re-discovery
    snapshot.driver_available = false
    discovered = false
    return
  end

  -- Line 1: Current RPM
  local parsedRpm = tonumber(lines[1])
  if parsedRpm and parsedRpm >= 0 then
    snapshot.rpm = parsedRpm
    snapshot.driver_available = true
  else
    snapshot.driver_available = false
    discovered = false
    return
  end

  -- Calculate percentage
  if snapshot.max_rpm > snapshot.min_rpm then
    local span = snapshot.max_rpm - snapshot.min_rpm
    local pct = math.floor(((snapshot.rpm - snapshot.min_rpm) / span) * 100)
    snapshot.percent = math.clamp(pct, 0, 100)
  end

  -- Line 2: fan1_manual (1 = manual, 0 = auto)
  local parsedManual = tonumber(lines[2])

  -- Line 3: fan1_output
  local parsedOutput = tonumber(lines[3])
  if parsedOutput and parsedOutput > 0 and snapshot.control_mode == "manual" then
    snapshot.target_rpm = parsedOutput
  elseif snapshot.target_rpm == nil or snapshot.target_rpm == 0 then
    snapshot.target_rpm = (parsedOutput and parsedOutput > 0) and parsedOutput or snapshot.rpm
  end

  -- Line 4: CPU Temperature (milli-degrees C)
  local parsedTemp = tonumber(lines[4])
  if parsedTemp and parsedTemp > 0 then
    snapshot.temp = math.floor((parsedTemp / 1000) * 10) / 10
  else
    if noctalia.systemStats then
      local stats = noctalia.systemStats()
      if stats and stats.cpu and stats.cpu.tempC then
        snapshot.temp = stats.cpu.tempC
      end
    end
  end

  -- Line 5: Daemon status
  local rawDaemon = lines[5] or ""
  snapshot.daemon_active = (rawDaemon == "active")

  -- Initialize control mode if not explicitly set
  if snapshot.control_mode == nil then
    if snapshot.daemon_active and parsedManual ~= 1 then
      snapshot.control_mode = "auto"
    elseif parsedManual == 1 then
      snapshot.control_mode = "manual"
    else
      snapshot.control_mode = "auto"
    end
  end
end

local function readHardware()
  if reading then
    return
  end
  reading = true

  if not discovered then
    noctalia.runAsync(makeDiscoveryCmd(), function(res)
      if res.exitCode == 0 and res.stdout and res.stdout ~= "" then
        parseDiscovery(res.stdout)
      else
        snapshot.driver_available = false
        discovered = false
      end

      -- If discovered successfully, immediately execute first poll
      if discovered then
        noctalia.runAsync(makePollCmd(), function(pollRes)
          reading = false
          if pollRes.exitCode == 0 and pollRes.stdout and pollRes.stdout ~= "" then
            parsePoll(pollRes.stdout)
          end
          publish()
        end, 2000)
      else
        reading = false
        publish()
      end
    end, 3000)
  else
    noctalia.runAsync(makePollCmd(), function(res)
      reading = false
      if res.exitCode == 0 and res.stdout and res.stdout ~= "" then
        parsePoll(res.stdout)
      else
        snapshot.driver_available = false
        discovered = false
      end
      publish()
    end, 2000)
  end
end

-- Watch commands dispatched by widget or panel
noctalia.state.watch(COMMAND, function(cmd)
  if type(cmd) ~= "table" then
    return
  end

  if cmd.action == "set_display_mode" and cmd.mode then
    snapshot.display_mode = cmd.mode
    publish()
  elseif cmd.action == "set_fan_mode" and cmd.mode then
    local dirTarget = applesmcDir or "/sys/devices/platform/applesmc.*"
    if cmd.mode == "auto" then
      snapshot.control_mode = "auto"
      publish()
      local autoCmd = string.format("echo 0 > %s/fan1_manual 2>/dev/null || true", dirTarget)
      noctalia.runAsync(autoCmd, function()
        readHardware()
      end, 2000)
    elseif cmd.mode == "manual" then
      snapshot.control_mode = "manual"
      local minR = snapshot.min_rpm or 1200
      local maxR = snapshot.max_rpm or 6500
      local target = math.clamp(tonumber(cmd.rpm) or snapshot.target_rpm or snapshot.rpm or minR, minR, maxR)
      snapshot.target_rpm = target
      publish()
      local manualCmd = string.format(
        "echo 1 > %s/fan1_manual 2>/dev/null || true; echo %d > %s/fan1_output 2>/dev/null || true",
        dirTarget,
        target,
        dirTarget
      )
      noctalia.runAsync(manualCmd, function()
        readHardware()
      end, 2000)
    end
  elseif cmd.action == "set_rpm" and cmd.rpm then
    snapshot.control_mode = "manual"
    local minR = snapshot.min_rpm or 1200
    local maxR = snapshot.max_rpm or 6500
    local target = math.clamp(tonumber(cmd.rpm) or minR, minR, maxR)
    snapshot.target_rpm = target

    -- Optimistic percentage calculation for instant UI feedback
    local span = math.max(1, maxR - minR)
    snapshot.percent = math.clamp(math.floor(((target - minR) / span) * 100), 0, 100)
    publish()

    local dirTarget = applesmcDir or "/sys/devices/platform/applesmc.*"
    local setCmd = string.format(
      "echo 1 > %s/fan1_manual 2>/dev/null || true; echo %d > %s/fan1_output 2>/dev/null || true",
      dirTarget,
      target,
      dirTarget
    )
    noctalia.runAsync(setCmd, function()
      readHardware()
    end, 2000)
  elseif cmd.action == "run_setup" then
    local script = getPluginDir() .. "/scripts/setup-requirements.sh"
    noctalia.notify(noctalia.tr("notify.title"), noctalia.tr("notify.setup_started"))
    noctalia.runInTerminal("bash " .. shellQuote(script))
  elseif cmd.action == "complete_onboarding" then
    local ver = snapshot.version or "1.2.0"
    local onboardFile = getOnboardFile()
    snapshot.onboarded = true
    publish()
    local writeCmd = string.format("mkdir -p $(dirname %s) && echo -n '%s' > %s", shellQuote(onboardFile), ver, shellQuote(onboardFile))
    noctalia.runAsync(writeCmd, function()
      readHardware()
    end, 2000)
  end
end)

function onConfigChanged()
  local mode = noctalia.getConfig("display_mode")
  if type(mode) == "string" and mode ~= "" then
    snapshot.display_mode = mode
  end
  local interval = tonumber(noctalia.getConfig("poll_interval_ms")) or 2000
  noctalia.setUpdateInterval(math.clamp(interval, 500, 30000))
  readHardware()
end

function update()
  readHardware()
end

-- Initialize display mode from config
local initialMode = noctalia.getConfig("display_mode")
if type(initialMode) == "string" and initialMode ~= "" then
  snapshot.display_mode = initialMode
end

local initialInterval = tonumber(noctalia.getConfig("poll_interval_ms")) or 2000
noctalia.setUpdateInterval(math.clamp(initialInterval, 500, 30000))

readHardware()
