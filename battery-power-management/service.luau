--!nonstrict
-- Battery & Power Management — headless [[service]] entry.
--
-- Owns every read and write to the system and publishes one immutable snapshot
-- table on "battery.snapshot". UI entries (widget, panel) read that snapshot and
-- push commands back on "battery.command" ({ action, value, requestId }); the
-- requestId nonce guarantees even a repeated identical command re-fires watch.
--
--   noctalia.readFile(path)            sysfs battery uevent / charge threshold
--   noctalia.runAsync(cmd, cb)         powerprofilesctl / upower / sysfs write
--   noctalia.commandExists(name)       feature-gate optional tools
--   noctalia.state.set/watch           publish snapshot / receive commands
--   noctalia.setUpdateInterval(ms)     poll cadence

local SNAPSHOT = "battery.snapshot"
local COMMAND = "battery.command"

local POLL_MS = 2000
local ETA_EVERY = 5 -- poll upower every 5 ticks (~10s); it spawns a process

local HAS_PPD = noctalia.commandExists("powerprofilesctl")
local HAS_UPOWER = noctalia.commandExists("upower")

local snapshot = {
  percent = 0,
  status = "Unknown", -- raw sysfs status: Charging / Discharging / Full / Not charging / Unknown
  watt = 0.0,
  eta = "", -- pre-formatted "1h 20m" / "" when unknown
  profile = "balanced",
  threshold = 80,
  hasThreshold = false,
  hasProfile = HAS_PPD,
}

local tick = 0

-- Wrap a value for safe use inside a shell command string (runAsync runs a shell).
local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Accept a bare device ("BAT0") or a full path; keep only the trailing name.
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

-- Publish a fresh copy so watchers always see a distinct value and re-render.
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

-- "1.2 hours" / "34 minutes" (upower units) -> "1h 12m" / "34m".
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

-- ── Synchronous sysfs reads ──────────────────────────────────────────────────

local function pollBattery()
  local content = noctalia.readFile(sysfsBase() .. "/uevent")
  if not content then
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

local function pollThreshold()
  local content = noctalia.readFile(sysfsBase() .. "/charge_control_end_threshold")
  if content then
    local v = tonumber(noctalia.string.trim(content))
    if v and v >= 50 and v <= 100 then
      snapshot.threshold = v
      snapshot.hasThreshold = true
      return
    end
  end
  snapshot.hasThreshold = false
end

-- ── Async system calls ───────────────────────────────────────────────────────

local function pollProfile()
  if not HAS_PPD then
    return
  end
  noctalia.runAsync("powerprofilesctl get", function(res)
    if res.exitCode == 0 then
      local p = noctalia.string.trim(res.stdout)
      if p ~= "" and p ~= snapshot.profile then
        snapshot.profile = p
        publish()
      end
    end
  end)
end

local function pollEta()
  if not HAS_UPOWER then
    return
  end
  local dev = deviceName()
  noctalia.runAsync("upower -i /org/freedesktop/UPower/devices/battery_" .. dev, function(res)
    local eta = ""
    if res.exitCode == 0 then
      for line in res.stdout:gmatch("[^\n]+") do
        local l = noctalia.string.trim(line)
        local val = l:match("^time to empty:%s*(.+)$") or l:match("^time to full:%s*(.+)$")
        if val then
          eta = formatUpowerTime(val)
          break
        end
      end
    end
    if eta ~= snapshot.eta then
      snapshot.eta = eta
      publish()
    end
  end)
end

-- ── Commands from the UI entries ─────────────────────────────────────────────

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
    snapshot.profile = p -- optimistic; pollProfile confirms
    publish()
    noctalia.runAsync("powerprofilesctl set " .. shellQuote(p), function(res)
      if res.exitCode ~= 0 then
        noctalia.log("powerprofilesctl set failed: " .. (res.stderr or ""))
      end
      pollProfile()
    end)
  elseif cmd.action == "set_threshold" then
    local v = tonumber(cmd.value)
    if not v then
      return
    end
    v = math.max(50, math.min(100, math.floor(v + 0.5)))
    snapshot.threshold = v -- optimistic; pollThreshold confirms
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
      pollThreshold()
      publish()
    end)
  end
end)

-- ── Lifecycle ────────────────────────────────────────────────────────────────

function update()
  pollBattery()
  pollThreshold()
  if tick % ETA_EVERY == 0 then
    pollProfile()
    pollEta()
  end
  tick += 1
  publish()
end

function onConfigChanged()
  -- battery_device may have changed; re-read immediately.
  tick = 0
  pollBattery()
  pollThreshold()
  pollProfile()
  pollEta()
  publish()
end

noctalia.setUpdateInterval(POLL_MS)

-- Seed state so the widget/panel have data before the first tick.
pollBattery()
pollThreshold()
pollProfile()
pollEta()
publish()
