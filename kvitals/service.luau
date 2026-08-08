--!nonstrict
-- KVitals sampler service.
--
-- Aggregates the host System Monitor, sysfs/proc data sources, and a
-- rolling history, then publishes one merged sample to the plugin state
-- every refresh_ms. The bar widget, panel, and desktop tile watch that
-- state; they never touch the sensors themselves.
--
-- Published keys:
--   kvitals.sample   one merged sample table
--   kvitals.history  rolling per-metric series (cpu/ram/gpu as 0-1, net in B/s)
--   kvitals.config   resolved plugin settings (units, toggles, thresholds)
--   kvitals.ready    true once the first sample lands

local datasrc = require("./lib/datasrc.luau")

local HISTORY_LEN = 60

local DEFAULTS = {
  cpu = { act = 50, crit = 90 },
  ram = { act = 60, crit = 90 },
  temp = { act = 60, crit = 85 },
  gpu = { act = 50, crit = 95 },
  vram = { act = 60, crit = 90 },
  net = { act = 1, crit = 50 },
  disk = { act = 80, crit = 95 },
}

local config = {}
local sample = nil
local history = nil

-- ── config ───────────────────────────────────────────────────────────────

local function readConfig()
  local function threshold(keyAct, keyCrit, def)
    return {
      act = noctalia.getConfig(keyAct) or def.act,
      crit = noctalia.getConfig(keyCrit) or def.crit,
    }
  end
  -- Older configs do not contain "vram"; insert it after "gpu" once.
  local order = noctalia.getConfig("metric_order")
    or { "cpu", "ram", "temp", "gpu", "vram", "fan", "battery", "net", "disk" }
  local hasVram = false
  for _, id in ipairs(order) do
    if id == "vram" then hasVram = true break end
  end
  if not hasVram then
    local migrated = {}
    local inserted = false
    for _, id in ipairs(order) do
      table.insert(migrated, id)
      if id == "gpu" and not inserted then
        table.insert(migrated, "vram")
        inserted = true
      end
    end
    if not inserted then table.insert(migrated, "vram") end
    order = migrated
  end
  return {
    refreshMs = noctalia.getConfig("refresh_ms") or 1000,
    tempUnit = noctalia.getConfig("temp_unit") or "c",
    netUnit = noctalia.getConfig("net_unit") or "auto",
    metricOrder = order,
    enabled = {
      cpu = noctalia.getConfig("enabled_cpu") ~= false,
      ram = noctalia.getConfig("enabled_ram") ~= false,
      temp = noctalia.getConfig("enabled_temp") ~= false,
      gpu = noctalia.getConfig("enabled_gpu") ~= false,
      vram = noctalia.getConfig("enabled_vram") ~= false,
      fan = noctalia.getConfig("enabled_fan") ~= false,
      battery = noctalia.getConfig("enabled_battery") ~= false,
      net = noctalia.getConfig("enabled_net") ~= false,
      disk = noctalia.getConfig("enabled_disk") ~= false,
    },
    showCpuFreq = noctalia.getConfig("show_cpu_freq") ~= false,
    showPowerDraw = noctalia.getConfig("show_power_draw") ~= false,
    showNetIp = noctalia.getConfig("show_net_ip") == true,
    icons = {
      cpu = noctalia.getConfig("icon_cpu") or "cpu",
      ram = noctalia.getConfig("icon_ram") or "database",
      temp = noctalia.getConfig("icon_temp") or "temperature",
      gpu = noctalia.getConfig("icon_gpu") or "device-desktop-analytics",
      vram = noctalia.getConfig("icon_vram") or "memory",
      fan = noctalia.getConfig("icon_fan") or "wind",
      net = noctalia.getConfig("icon_net") or "network",
      disk = noctalia.getConfig("icon_disk") or "device-floppy",
    },
    thresholds = {
      cpu = threshold("cpu_act", "cpu_crit", DEFAULTS.cpu),
      ram = threshold("ram_act", "ram_crit", DEFAULTS.ram),
      temp = threshold("temp_act", "temp_crit", DEFAULTS.temp),
      gpu = threshold("gpu_act", "gpu_crit", DEFAULTS.gpu),
      vram = threshold("vram_act", "vram_crit", DEFAULTS.vram),
      net = threshold("net_act", "net_crit", DEFAULTS.net),
      disk = threshold("disk_act", "disk_crit", DEFAULTS.disk),
    },
    accent = noctalia.getConfig("accent_color") or "primary",
    font = noctalia.getConfig("font_color") or "on_surface",
  }
end

-- ── history ring ─────────────────────────────────────────────────────────

local function newHistory()
  return { cpu = {}, ram = {}, gpu = {}, vram = {}, netRx = {}, netTx = {} }
end

local function pushSeries(series, value)
  if value == nil then return end
  table.insert(series, value)
  if #series > HISTORY_LEN then
    table.remove(series, 1)
  end
end

-- ── publish ──────────────────────────────────────────────────────────────

local function publish()
  noctalia.state.set("kvitals.sample", sample)
  noctalia.state.set("kvitals.history", history)
  noctalia.state.set("kvitals.config", config)
  noctalia.state.set("kvitals.ready", true)
end

-- ── sampling ─────────────────────────────────────────────────────────────

local function tick()
  local now = noctalia.nowMs()
  local stats = noctalia.systemStats()
  local round = {}
  round.ok = stats ~= nil
  round.sampledAtMs = now

  if stats then
    round.cpu = { usage = stats.cpu.usagePercent, temp = stats.cpu.tempC }
    round.ram = {
      usage = stats.ram.usagePercent,
      used = stats.ram.usedMb * 1000000,
      total = stats.ram.totalMb * 1000000,
    }
    round.swap = {
      used = stats.swap.usedMb * 1000000,
      total = stats.swap.totalMb * 1000000,
    }
    round.gpu = {
      usage = stats.gpu.usagePercent,
      temp = stats.gpu.tempC,
      vramUsed = stats.gpu.vramUsedBytes,
      vramTotal = stats.gpu.vramTotalBytes,
    }
    round.net = { rx = stats.net.rxBytesPerSec, tx = stats.net.txBytesPerSec }
    round.load = stats.loadAvg
  end

  round.diskUsage = noctalia.diskStats("/")

  datasrc.tickAsync(function(extras)
    round.battery = extras.battery
    round.fanRpm = extras.fanRpm
    round.diskTempC = extras.diskTempC
    round.cpuFreqHz = extras.cpuFreqHz
    round.diskIo = extras.diskIo
    round.netIp = extras.netIp

    if history == nil then history = newHistory() end
    if round.cpu then pushSeries(history.cpu, round.cpu.usage / 100) end
    if round.ram then pushSeries(history.ram, round.ram.usage / 100) end
    if round.gpu and round.gpu.usage then pushSeries(history.gpu, round.gpu.usage / 100) end
    if round.gpu and round.gpu.vramUsed and round.gpu.vramTotal and round.gpu.vramTotal > 0 then
      pushSeries(history.vram, round.gpu.vramUsed / round.gpu.vramTotal)
    end
    if round.net then
      pushSeries(history.netRx, round.net.rx)
      pushSeries(history.netTx, round.net.tx)
    end

    sample = round
    publish()
  end)
end

-- ── entry points ─────────────────────────────────────────────────────────

config = readConfig()
noctalia.setUpdateInterval(config.refreshMs)

function update()
  tick()
end

function onConfigChanged()
  config = readConfig()
  noctalia.setUpdateInterval(config.refreshMs)
  publish()
end

function onEnable()
  tick()
end
