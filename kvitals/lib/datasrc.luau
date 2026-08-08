--!nonstrict
-- sysfs / proc data sources: battery, fan, disk temperature, CPU frequency,
-- disk I/O deltas, and the local IPv4 address.
--
-- These are the readings the host System Monitor does not expose. All file
-- reads go through lib/sys.luau's serial queue. Paths are discovered once at
-- load, so a tick performs at most five tiny reads plus one occasional
-- `ip` subprocess.

local sys = require("./sys.luau")

local M = {}

-- Discovered paths (nil when the sensor is absent).
local batteryDir = nil
local fanInput = nil
local diskTempInput = nil
local cpuFreqInput = nil

local hasIp = noctalia.commandExists("ip")

-- Disk I/O delta state.
local prevDiskRead = 0
local prevDiskWrite = 0
local prevDiskMs = nil

-- Local IP (refreshed every 30 ticks).
local currentIp = nil
local ipTick = 0

local function trim(s)
  if s == nil then return "" end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ── hwmon scan ───────────────────────────────────────────────────────────

-- Finds the first live fan input and the best disk-temperature input.
local function scanHwmon()
  local dirs = noctalia.listDir("/sys/class/hwmon") or {}
  local fans = {}
  local temps = {}

  for _, dir in ipairs(dirs) do
    local base = "/sys/class/hwmon/" .. dir
    local driver = trim(noctalia.readFile(base .. "/name"))
    local inputs = noctalia.listDir(base) or {}

    for _, name in ipairs(inputs) do
      local fanN = string.match(name, "^fan(%d+)_input$")
      if fanN then
        local rpm = tonumber(noctalia.readFile(base .. "/" .. name))
        if rpm and rpm > 0 then
          table.insert(fans, { path = base .. "/" .. name, rpm = rpm })
        end
      end

      local tempN = string.match(name, "^temp(%d+)_input$")
      if tempN then
        local label = trim(noctalia.readFile(base .. "/temp" .. tempN .. "_label"))
        local milli = tonumber(noctalia.readFile(base .. "/" .. name))
        table.insert(temps, {
          path = base .. "/" .. name,
          driver = driver,
          label = label,
          valueC = (milli or 0) / 1000,
        })
      end
    end
  end

  if #fans > 0 then
    fanInput = fans[1].path
  end

  -- Score: NVMe and ATA controllers beat everything else.
  local best = nil
  local bestScore = -1
  local function score(t)
    local s = 0
    if t.driver:match("nvme") then s = s + 4 end
    if t.driver:match("ahci") or t.driver:match("ata") then s = s + 3 end
    if t.label:match("Composite") then s = s + 3 end
    if t.label:match("[Dd]isk") or t.label:match("[Dd]rive") then s = s + 2 end
    if t.valueC > 0 and t.valueC < 200 then s = s + 1 end
    return s
  end
  for _, t in ipairs(temps) do
    local s = score(t)
    if s > bestScore then
      bestScore = s
      best = t
    end
  end
  if best ~= nil then
    diskTempInput = best.path
  end
end

-- ── power_supply scan ────────────────────────────────────────────────────

local function scanBattery()
  local dirs = noctalia.listDir("/sys/class/power_supply") or {}
  for _, dir in ipairs(dirs) do
    local base = "/sys/class/power_supply/" .. dir
    if trim(noctalia.readFile(base .. "/type")) == "Battery" then
      batteryDir = base
      return
    end
  end
end

-- ── CPU frequency path ───────────────────────────────────────────────────

local function scanCpuFreq()
  local p = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
  if noctalia.fileExists(p) then
    cpuFreqInput = p
    return
  end
  p = "/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_cur_freq"
  if noctalia.fileExists(p) then
    cpuFreqInput = p
  end
end

-- ── /proc/diskstats ──────────────────────────────────────────────────────

-- Returns (sectorsRead, sectorsWritten) byte totals over physical devices.
local function parseDiskstats(contents)
  local rx, tx = 0, 0
  if contents == nil then return rx, tx end
  for line in contents:gmatch("[^\n]+") do
    local major, minor, name, rest = line:match("(%d+)%s+(%d+)%s+(%S+)%s+(.*)")
    if major and minor and name and rest then
      if not (name:match("^loop") or name:match("^ram") or name:match("^zram")
        or name:match("^dm%-") or name:match("^sr") or name:match("^md")) then
        local tokens = {}
        for token in rest:gmatch("%S+") do
          table.insert(tokens, token)
        end
        -- Field order after the device name:
        -- reads, merged, sectors read, ms read, writes, merged, sectors written.
        local sectorsRead = tonumber(tokens[3]) or 0
        local sectorsWritten = tonumber(tokens[7]) or 0
        rx = rx + sectorsRead * 512
        tx = tx + sectorsWritten * 512
      end
    end
  end
  return rx, tx
end

-- ── battery reading ──────────────────────────────────────────────────────

-- Reads capacity, status, and power draw. cb({capacity, status, powerW}).
local function readBattery(cb)
  if batteryDir == nil then
    cb(nil)
    return
  end
  local out = {}
  sys.readInt(batteryDir .. "/capacity", function(capacity)
    out.capacity = capacity
    sys.read(batteryDir .. "/status", function(status)
      out.status = trim(status)
      local powerNow = batteryDir .. "/power_now"
      if noctalia.fileExists(powerNow) then
        sys.readInt(powerNow, function(uw)
          if uw then out.powerW = uw / 1000000 end
          cb(out)
        end)
      else
        sys.readInt(batteryDir .. "/current_now", function(uA)
          if uA == nil then
            cb(out)
            return
          end
          sys.readInt(batteryDir .. "/voltage_now", function(uV)
            if uV then out.powerW = uA * uV / 1000000000000 end
            cb(out)
          end)
        end)
      end
    end)
  end)
end

-- ── local IP ─────────────────────────────────────────────────────────────

local function refreshIp()
  noctalia.runAsync("ip -j -brief addr", function(result)
    if not result or result.exitCode ~= 0 then return end
    local parsed = noctalia.json.decode(result.stdout)
    if parsed == nil or type(parsed) ~= "table" then return end
    local found = nil
    for _, iface in ipairs(parsed) do
      if found then break end
      local name = iface.ifname
      if name ~= "lo" and type(iface.addr_info) == "table" then
        for _, addr in ipairs(iface.addr_info) do
          if addr.family == "inet" and addr["local"] and not addr["local"]:match("^127%.") then
            found = addr["local"]
            break
          end
        end
      end
    end
    if found then currentIp = found end
  end, 2000)
end

-- ── init ─────────────────────────────────────────────────────────────────

scanHwmon()
scanBattery()
scanCpuFreq()
prevDiskRead, prevDiskWrite = parseDiskstats(noctalia.readFile("/proc/diskstats"))
prevDiskMs = noctalia.nowMs()

-- ── tick ─────────────────────────────────────────────────────────────────

-- Gathers all sensor readings for one sample. cb(extras) fires once, after
-- every queued read completes. extras is a flat table of whatever is present.
function M.tickAsync(cb)
  local out = {}
  local pending = 0

  local function done()
    pending = pending - 1
    if pending == 0 then cb(out) end
  end

  local function enqueue(fn, key)
    pending = pending + 1
    fn(function(value)
      out[key] = value
      done()
    end)
  end

  if cpuFreqInput then
    enqueue(function(doneRead)
      sys.readInt(cpuFreqInput, function(khz)
        doneRead(khz and khz * 1000 or nil) -- kHz -> Hz
      end)
    end, "cpuFreqHz")
  end

  if fanInput then
    enqueue(function(doneRead)
      sys.readInt(fanInput, function(rpm)
        doneRead(rpm)
      end)
    end, "fanRpm")
  end

  if diskTempInput then
    enqueue(function(doneRead)
      sys.readInt(diskTempInput, function(milli)
        doneRead(milli and milli / 1000 or nil) -- millidegrees -> °C
      end)
    end, "diskTempC")
  end

  enqueue(function(doneRead)
    readBattery(doneRead)
  end, "battery")

  enqueue(function(doneRead)
    local now = noctalia.nowMs()
    sys.read("/proc/diskstats", function(contents)
      local rx, tx = parseDiskstats(contents)
      if prevDiskMs == nil then
        prevDiskRead, prevDiskWrite, prevDiskMs = rx, tx, now
        doneRead({ rx = 0, tx = 0 })
        return
      end
      local dt = (now - prevDiskMs) / 1000
      local drx = 0
      local dtx = 0
      if dt > 0 then
        drx = (rx - prevDiskRead) / dt
        dtx = (tx - prevDiskWrite) / dt
        if drx < 0 then drx = 0 end
        if dtx < 0 then dtx = 0 end
      end
      prevDiskRead, prevDiskWrite, prevDiskMs = rx, tx, now
      doneRead({ rx = drx, tx = dtx })
    end)
  end, "diskIo")

  out.netIp = currentIp
  ipTick = ipTick + 1
  if hasIp and ipTick % 30 == 1 then
    refreshIp()
  end

  if pending == 0 then
    cb(out)
  end
end

return M
