--!nonstrict
-- CPU: compact gauge glyph + percent (gauge toggleable in widget settings).
-- Hover adds current clock speed and package power draw (RAPL, Intel only).

local RAPL_PATH = "/sys/class/powercap/intel-rapl:0/energy_uj"
local FREQ_PATH = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"

local gpuPct = nil
local pct = 0.0
local ghz = nil
local watts = nil

local progress = 0.0 -- 0 = closed, 1 = fully open
local target = 0.0

-- Same tuning as the clock/volume widgets: 0.16 @ 16ms (~60fps).
local EASE = 0.16
local ANIM_INTERVAL = 16
local IDLE_INTERVAL = 1000

-- utf8.len/offset find character boundaries so a partial reveal never cuts a
-- multi-byte character in half (raw string.sub broke exactly this way when we
-- first tried an animated reveal on the volume widget's "―"/"●" glyphs).
local function utf8Sub(s: string, charCount: number): string
  if charCount <= 0 then
    return ""
  end
  local len = utf8.len(s)
  if not len or charCount >= len then
    return s
  end
  local offset = utf8.offset(s, charCount + 1)
  if not offset then
    return s
  end
  return s:sub(1, offset - 1)
end

local prevIdle = nil
local prevTotal = nil
local prevEnergyUj = nil
local prevEnergyAt = nil

local function readCpuTimes()
  local stat = noctalia.readFile("/proc/stat")
  if not stat then
    return nil
  end
  local user, nice, system, idle, iowait, irq, softirq, steal =
    string.match(stat, "^cpu%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
  if not user then
    return nil
  end
  local idleTotal = tonumber(idle) + tonumber(iowait)
  local total = tonumber(user) + tonumber(nice) + tonumber(system) + idleTotal + tonumber(irq) + tonumber(softirq)
    + tonumber(steal)
  return idleTotal, total
end

local function updatePct()
  local idle, total = readCpuTimes()
  if not idle then
    return
  end
  if prevIdle then
    local idleDelta = idle - prevIdle
    local totalDelta = total - prevTotal
    if totalDelta > 0 then
      pct = (1 - idleDelta / totalDelta) * 100
    end
  end
  prevIdle = idle
  prevTotal = total
end

local function updateGpu()
  if noctalia.getConfig("show_gpu") == false then gpuPct = nil; return end
  local stats = noctalia.systemStats()
  local value = stats and stats.gpu and stats.gpu.usagePercent
  gpuPct = type(value) == "number" and math.max(0, math.min(100, value)) or nil
end

local function updateFreq()
  local raw = noctalia.readFile(FREQ_PATH)
  if raw then
    local khz = tonumber(string.match(raw, "%d+"))
    if khz then
      ghz = khz / 1000000
    end
  end
end

local function updatePower()
  local raw = noctalia.readFile(RAPL_PATH)
  if not raw then
    return
  end
  local energyUj = tonumber(string.match(raw, "%d+"))
  local now = noctalia.nowMs() / 1000
  if energyUj and now and prevEnergyUj and prevEnergyAt and energyUj >= prevEnergyUj then
    local dt = now - prevEnergyAt
    if dt > 0 then
      watts = (energyUj - prevEnergyUj) / 1000000 / dt
    end
  end
  prevEnergyUj = energyUj
  prevEnergyAt = now
end

-- Real vertical block-element glyphs (▁..█), each one grows from the bottom
-- like an actual gauge -- confirmed present in the system monospace font
-- (Noto Sans Mono), unlike Adwaita Sans which lacks this whole block.
local BLOCKS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

local function gaugeChar(v: number): string
  local idx = math.floor(v / 100 * #BLOCKS + 0.5)
  if idx < 1 then
    idx = 1
  elseif idx > #BLOCKS then
    idx = #BLOCKS
  end
  return BLOCKS[idx]
end

local function render()
  barWidget.setGlyph("cpu-usage")
  local pctText = `{math.floor(pct + 0.5)}%`
  local useGauge = noctalia.getConfig("gauge")

  if useGauge ~= false then
    barWidget.setFont("monospace")
  else
    barWidget.setFont("Adwaita Sans")
  end

  local parts = {}
  if useGauge ~= false then
    parts[#parts + 1] = gaugeChar(pct)
  end
  parts[#parts + 1] = pctText
  if noctalia.getConfig("show_gpu") ~= false then
    parts[#parts + 1] = gpuPct ~= nil and `GPU {math.floor(gpuPct + 0.5)}%` or "GPU —"
  end
  local base = table.concat(parts, " ")

  local extraParts = {}
  if ghz then
    extraParts[#extraParts + 1] = `{string.format("%.1f", ghz)}GHz`
  end
  if watts then
    extraParts[#extraParts + 1] = `{string.format("%.1f", watts)}W`
  end
  local extra = table.concat(extraParts, " ")

  local revealLen = math.floor(utf8.len(extra) * progress + 0.5)
  if revealLen > 0 then
    barWidget.setText(`{base} {utf8Sub(extra, revealLen)}`)
  else
    barWidget.setText(base)
  end
end

local function step()
  if math.abs(progress - target) < 0.01 then
    progress = target
    noctalia.setUpdateInterval(IDLE_INTERVAL)
    updatePct()
    updateGpu()
    updateFreq()
    updatePower()
  else
    progress = progress + (target - progress) * EASE
    noctalia.setUpdateInterval(ANIM_INTERVAL)
  end
  render()
end

function update()
  step()
end

function onHover(isHovering: boolean)
  target = isHovering and 1.0 or 0.0
  step()
end

function onClick()
  noctalia.runAsync("noctalia msg panel-toggle control-center system")
end
