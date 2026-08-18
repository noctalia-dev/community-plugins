--!nonstrict

local SNAPSHOT = "battery.snapshot"
local COMMAND = "battery.command"

local POLL_MS = 5000
local PROBE_EVERY = 3 -- powerprofilesctl+upower round every Nth tick (~15s)
local READ_TIMEOUT_MS = 4000
local PROBE_TIMEOUT_MS = 5000
local SEP = "__NBPM_SEP__" -- separates command outputs in one shell run

local HAS_PPD = noctalia.commandExists("powerprofilesctl")
local HAS_UPOWER = noctalia.commandExists("upower")

local snapshot = {
  percent = 0,
  status = "Unknown", -- raw sysfs status: Charging / Discharging / Full / Not charging / Unknown
  watt = 0.0,
  eta = "", -- pre-formatted "1h 20m", "" when unknown
  profile = "balanced",
  threshold = 80,
  hasThreshold = false,
  hasProfile = HAS_PPD,
}

local tick = 0
local reading = false -- sysfs read in flight
local probing = false -- profile/eta round in flight

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Accept "BAT0" or a full sysfs path.
local function deviceName()
  local d = noctalia.getConfig("battery_device")
  if type(d) ~= "string" or d == "" then
    return "BAT0"
  end
  d = noctalia.string.trim(d):gsub("/+$", "")
  return d:match("[^/]+$") or "BAT0"
end

local function sysfsBase()
  return "/sys/class/power_supply/" .. deviceName()
end

-- Fresh copy each publish so watchers see a distinct value.
local function publish()
  noctalia.state.set(SNAPSHOT, {
    percent = snapshot.percent,
    status = snapshot.status,
    watt = snapshot.watt,
    eta = snapshot.eta,
    profile = snapshot.profile,
    threshold = snapshot.threshold,
    hasThreshold = snapshot.hasThreshold,
    hasProfile = snapshot.hasProfile,
  })
end

-- upower units ("1.2 hours" / "34 minutes") -> "1h 12m" / "34m".
local function formatUpowerTime(value)
  local numStr, unit = value:match("^(%S+)%s*(%S*)")
  local num = tonumber(numStr)
  if not num then
    return ""
  end
  local minutes
  if unit:sub(1, 4) == "hour" then
    minutes = num * 60
  elseif unit:sub(1, 6) == "minute" then
    minutes = num
  elseif unit:sub(1, 6) == "second" then
    minutes = num / 60
  elseif unit:sub(1, 3) == "day" then
    minutes = num * 1440
  else
    return value
  end
  local total = math.floor(minutes + 0.5)
  local h = total // 60
  local m = total % 60
  if h > 0 then
    return string.format("%dh %dm", h, m)
  end
  return string.format("%dm", m)
end

local function parseBattery(content)
  if not content or content == "" then
    return
  end
  local cap = snapshot.percent
  local powerNow, currentNow, voltageNow
  local status = snapshot.status
  for line in content:gmatch("[^\n]+") do
    local k, v = line:match("^([%w_]+)=(.*)$")
    if k == "POWER_SUPPLY_CAPACITY" then
      cap = tonumber(v) or cap
    elseif k == "POWER_SUPPLY_POWER_NOW" then
      powerNow = tonumber(v)
    elseif k == "POWER_SUPPLY_CURRENT_NOW" then
      currentNow = tonumber(v)
    elseif k == "POWER_SUPPLY_VOLTAGE_NOW" then
      voltageNow = tonumber(v)
    elseif k == "POWER_SUPPLY_STATUS" then
      status = noctalia.string.trim(v)
    end
  end
  -- POWER_NOW is microwatts; some drivers only expose CURRENT_NOW (µA) + VOLTAGE_NOW (µV).
  local watt = 0.0
  if powerNow then
    watt = math.abs(powerNow) / 1000000.0
  elseif currentNow and voltageNow then
    watt = math.abs(currentNow * voltageNow) / 1000000000000.0
  end
  snapshot.percent = cap
  snapshot.status = status
  snapshot.watt = watt
end

local function parseThreshold(content)
  local v = content and tonumber(noctalia.string.trim(content))
  if v and v >= 50 and v <= 100 then
    snapshot.threshold = v
    snapshot.hasThreshold = true
  else
    snapshot.hasThreshold = false
  end
end

-- Read battery uevent + charge threshold asynchronously so update() never blocks
-- on a slow sysfs/EC access.
local function readSysfs()
  if reading then
    return
  end
  reading = true
  local base = sysfsBase()
  local cmd = "cat " .. shellQuote(base .. "/uevent") .. "; echo " .. SEP
    .. "; cat " .. shellQuote(base .. "/charge_control_end_threshold") .. " 2>/dev/null"
  local launched = noctalia.runAsync(cmd, function(res)
    reading = false
    local out = res.stdout or ""
    local sepAt = out:find(SEP, 1, true)
    parseBattery(sepAt and out:sub(1, sepAt - 1) or out)
    parseThreshold(sepAt and out:sub(sepAt + #SEP) or "")
    publish()
  end, READ_TIMEOUT_MS)
  if not launched then
    reading = false
  end
end

local function probeProfileAndEta()
  if probing or not (HAS_PPD or HAS_UPOWER) then
    return
  end
  probing = true

  local profileCmd = HAS_PPD and "powerprofilesctl get" or "true"
  local etaCmd = HAS_UPOWER
      and ("upower -i "
        .. shellQuote("/org/freedesktop/UPower/devices/battery_" .. deviceName()))
    or "true"
  local cmd = profileCmd .. "; echo " .. SEP .. "; " .. etaCmd

  local launched = noctalia.runAsync(cmd, function(res)
    probing = false
    local out = res.stdout or ""
    local sepAt = out:find(SEP, 1, true)
    local profOut = sepAt and out:sub(1, sepAt - 1) or ""
    local etaOut = sepAt and out:sub(sepAt + #SEP) or out

    if HAS_PPD then
      local p = noctalia.string.trim(profOut)
      if p ~= "" then
        snapshot.profile = p
      end
    end

    local eta = ""
    if HAS_UPOWER then
      for line in etaOut:gmatch("[^\n]+") do
        local l = noctalia.string.trim(line)
        local val = l:match("^time to empty:%s*(.+)$") or l:match("^time to full:%s*(.+)$")
        if val then
          eta = formatUpowerTime(val)
          break
        end
      end
    end
    snapshot.eta = eta
    publish()
  end, PROBE_TIMEOUT_MS)

  if not launched then
    probing = false
  end
end

noctalia.state.watch(COMMAND, function(cmd)
  if type(cmd) ~= "table" then
    return
  end

  if cmd.action == "set_profile" then
    if not HAS_PPD then
      return
    end
    local p = tostring(cmd.value or "")
    if p == "" then
      return
    end
    snapshot.profile = p -- optimistic; confirmed by the next probe
    publish()
    noctalia.runAsync("powerprofilesctl set " .. shellQuote(p), function(res)
      if res.exitCode ~= 0 then
        noctalia.log("powerprofilesctl set failed: " .. (res.stderr or ""))
      end
    end, PROBE_TIMEOUT_MS)
  elseif cmd.action == "set_threshold" then
    local v = tonumber(cmd.value)
    if not v then
      return
    end
    v = math.max(50, math.min(100, math.floor(v + 0.5)))
    snapshot.threshold = v -- optimistic; confirmed by the next read
    publish()
    local path = sysfsBase() .. "/charge_control_end_threshold"
    noctalia.runAsync("echo " .. v .. " > " .. shellQuote(path), function(res)
      if res.exitCode ~= 0 then
        noctalia.notifyError(
          noctalia.tr("notify.threshold_error_title"),
          noctalia.tr("notify.threshold_error_body")
        )
        noctalia.log("threshold write failed: " .. (res.stderr or ""))
      end
      readSysfs()
    end, PROBE_TIMEOUT_MS)
  end
end)

function update()
  readSysfs()
  if tick % PROBE_EVERY == 0 then
    probeProfileAndEta()
  end
  tick += 1
end

function onConfigChanged()
  -- battery_device may have changed; re-read now.
  tick = 0
  reading = false
  probing = false
  readSysfs()
  probeProfileAndEta()
end

noctalia.setUpdateInterval(POLL_MS)

-- Seed state before the first async read completes.
publish()
readSysfs()
probeProfileAndEta()
