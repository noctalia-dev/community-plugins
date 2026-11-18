--!nonstrict
-- KumaCat bar widget: paces an animated runner against host CPU, RAM, or GPU
-- load. While below sleep_threshold, update() drops its timer interval to
-- poll_interval so zero animation wakeups occur while idle.

local catFont = noctalia.loadFont("fonts/kumacat.otf")

local GLYPH_IDLE = "a"
local RUN_GLYPHS = { "b", "c", "d", "e", "f" }

local SPRITE_PACKS = {
  ["flash-cat"] = {
    aspect = 84 / 36,
    frames = {
      "runners/flash-cat/frame-0.png",
      "runners/flash-cat/frame-1.png",
      "runners/flash-cat/frame-2.png",
      "runners/flash-cat/frame-3.png",
      "runners/flash-cat/frame-4.png",
    },
  },
  ["cat-tail"] = {
    aspect = 100 / 36,
    frames = {
      "runners/cat-tail/frame-0.png",
      "runners/cat-tail/frame-1.png",
      "runners/cat-tail/frame-2.png",
      "runners/cat-tail/frame-3.png",
      "runners/cat-tail/frame-4.png",
      "runners/cat-tail/frame-5.png",
      "runners/cat-tail/frame-6.png",
      "runners/cat-tail/frame-7.png",
    },
  },
}
local SLEEP_SPRITE = "runners/sleep.png"

local TICK_MS = 80
local WALK_MAX_MS = 380
local WALK_MIN_MS = 180
local RUN_MAX_MS = 160
local RUN_MIN_MS = 55

local runnerStyle = noctalia.getConfig("runner_style") or "flash-cat"
local catSize = noctalia.getConfig("cat_size") or 24
local driveMetric = noctalia.getConfig("drive_metric") or "cpu"
local showMetricPercent = noctalia.getConfig("show_metric_percent") or false
local sleepThreshold = noctalia.getConfig("sleep_threshold") or 5
local turboThreshold = noctalia.getConfig("turbo_threshold") or 75
local pollIntervalMs = (noctalia.getConfig("poll_interval") or 2) * 1000
local colorMode = noctalia.getConfig("cat_color_mode") or "theme"
local customColor = noctalia.getConfig("cat_color") or "#E8A24C"

local frameIndex = 1
local frameElapsed = 0
local frameDurationMs = WALK_MAX_MS
local activeTickMs = TICK_MS

local sampleElapsed = pollIntervalMs
local cpuPercent = 0
local ramPercent = 0
local ramUsedGiB = 0
local ramTotalGiB = 0
local gpuPercent = 0
local cpuTempC = nil
local gpuTempC = nil

-- API 46 requires explicit GPU opt-in per entry; avoid keeping discrete GPUs
-- awake when the bar widget is driven by CPU or RAM.
local function syncGpuMonitoring()
  if noctalia.setGpuMonitoring ~= nil then
    noctalia.setGpuMonitoring(driveMetric == "gpu")
  end
end

local function setTickInterval(targetMs)
  if targetMs ~= activeTickMs then
    activeTickMs = targetMs
    noctalia.setUpdateInterval(targetMs)
  end
end

local function sampleTelemetry()
  local stats = noctalia.systemStats()
  if stats == nil then
    return
  end

  if stats.cpu and stats.cpu.usagePercent ~= nil then
    cpuPercent = math.clamp(stats.cpu.usagePercent, 0, 100)
    cpuTempC = stats.cpu.tempC
  end

  if stats.ram then
    ramPercent = math.clamp(stats.ram.usagePercent or 0, 0, 100)
    ramUsedGiB = (stats.ram.usedMb or 0) / 1024
    ramTotalGiB = (stats.ram.totalMb or 0) / 1024
  end

  if stats.gpu then
    if stats.gpu.usagePercent ~= nil then
      gpuPercent = math.clamp(stats.gpu.usagePercent, 0, 100)
    end
    gpuTempC = stats.gpu.tempC
  end
end

local function activeValue()
  if driveMetric == "memory" then
    return ramPercent
  elseif driveMetric == "gpu" then
    return gpuPercent
  end
  return cpuPercent
end

local function frameCount()
  local pack = SPRITE_PACKS[runnerStyle]
  if pack then
    return #pack.frames
  end
  return #RUN_GLYPHS
end

local function paceFor(metricVal)
  local effectiveTurbo = math.max(turboThreshold, sleepThreshold + 1)

  if metricVal < sleepThreshold then
    return "sleep", WALK_MAX_MS
  elseif metricVal < effectiveTurbo then
    local range = math.max(effectiveTurbo - sleepThreshold, 1)
    local t = math.clamp((metricVal - sleepThreshold) / range, 0, 1)
    return "walk", WALK_MAX_MS - t * (WALK_MAX_MS - WALK_MIN_MS)
  else
    local range = math.max(100 - effectiveTurbo, 1)
    local t = math.clamp((metricVal - effectiveTurbo) / range, 0, 1)
    return "sprint", RUN_MAX_MS - t * (RUN_MAX_MS - RUN_MIN_MS)
  end
end

local function resolveColor()
  if colorMode == "custom" and customColor and customColor ~= "" then
    return customColor
  end
  return "secondary"
end

local function currentVisual(pace)
  local pack = SPRITE_PACKS[runnerStyle]
  if pack then
    if pace == "sleep" then
      return nil, SLEEP_SPRITE, 1
    end
    local idx = ((frameIndex - 1) % #pack.frames) + 1
    return nil, pack.frames[idx], pack.aspect
  end

  local idx = ((frameIndex - 1) % #RUN_GLYPHS) + 1
  local glyph = pace == "sleep" and GLYPH_IDLE or RUN_GLYPHS[idx]
  return glyph, nil, 1
end

local lastPublishedKey = nil
local function publishState(pace, glyph, imagePath, imageAspect, color, currentVal)
  local visualKey = imagePath or glyph or ""
  local key = `{runnerStyle}|{visualKey}|{math.floor(currentVal)}|{color}|{pace}|{math.floor(cpuPercent)}|{math.floor(ramPercent)}|{math.floor(gpuPercent)}`
  if key == lastPublishedKey then
    return
  end
  lastPublishedKey = key
  noctalia.state.set("kumacat", {
    runnerStyle = runnerStyle,
    glyph = glyph,
    imagePath = imagePath,
    imageAspect = imageAspect,
    pace = pace,
    color = color,
    driveMetric = driveMetric,
    metricValue = math.floor(currentVal),
    cpuPercent = math.floor(cpuPercent),
    cpuTemp = cpuTempC,
    ramPercent = math.floor(ramPercent),
    ramUsedGiB = ramUsedGiB,
    ramTotalGiB = ramTotalGiB,
    gpuPercent = math.floor(gpuPercent),
    gpuTemp = gpuTempC,
  })
end

local function render(pace)
  local currentVal = activeValue()
  local glyph, imagePath, imageAspect = currentVisual(pace)
  local color = resolveColor()

  publishState(pace, glyph, imagePath, imageAspect, color, currentVal)

  local runnerNode
  if imagePath then
    runnerNode = ui.image({
      path = imagePath,
      width = math.max(12, math.floor(catSize * imageAspect + 0.5)),
      height = catSize,
      fit = "contain",
    })
  else
    runnerNode = ui.label({
      text = glyph,
      fontFamily = catFont,
      baseline = "inkCentered",
      fontSize = catSize,
      color = color,
    })
  end

  local children = { runnerNode }
  if showMetricPercent then
    table.insert(
      children,
      ui.label({
        text = `{math.floor(currentVal)}%`,
        fontSize = 11,
        color = color,
      })
    )
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 4, align = "center" }, children))

  local paceLabel = pace == "sleep" and "Idle Sleep (0 FPS)" or (pace == "walk" and "Active Pace" or "Turbo Sprint")
  local tipLines = {
    `KumaCat: {paceLabel}`,
    `CPU: {math.floor(cpuPercent)}%` .. (cpuTempC and ` ({math.floor(cpuTempC)}°C)` or ""),
    `Memory: {string.format("%.1f", ramUsedGiB)} / {string.format("%.1f", ramTotalGiB)} GiB ({math.floor(ramPercent)}%)`,
  }
  if gpuPercent > 0 or gpuTempC ~= nil then
    table.insert(tipLines, `GPU: {math.floor(gpuPercent)}%` .. (gpuTempC and ` ({math.floor(gpuTempC)}°C)` or ""))
  end
  table.insert(tipLines, "Click to toggle Telemetry HUD")
  barWidget.setTooltip(table.concat(tipLines, "\n"))
end

syncGpuMonitoring()
noctalia.setUpdateInterval(TICK_MS)

function update()
  sampleElapsed += activeTickMs
  if sampleElapsed >= pollIntervalMs then
    sampleElapsed = 0
    sampleTelemetry()
  end

  local val = activeValue()
  local pace, duration = paceFor(val)
  frameDurationMs = duration

  if pace == "sleep" then
    frameElapsed = 0
    frameIndex = 1
    setTickInterval(pollIntervalMs)
  else
    setTickInterval(TICK_MS)
    frameElapsed += TICK_MS
    if frameElapsed >= frameDurationMs then
      frameElapsed = 0
      frameIndex = (frameIndex % frameCount()) + 1
    end
  end

  render(pace)
end

function onClick()
  noctalia.togglePanel("mhdomer/kumacat:panel")
end

function onConfigChanged()
  runnerStyle = noctalia.getConfig("runner_style") or "flash-cat"
  catSize = noctalia.getConfig("cat_size") or 24
  driveMetric = noctalia.getConfig("drive_metric") or "cpu"
  showMetricPercent = noctalia.getConfig("show_metric_percent") or false
  sleepThreshold = noctalia.getConfig("sleep_threshold") or 5
  turboThreshold = noctalia.getConfig("turbo_threshold") or 75
  pollIntervalMs = (noctalia.getConfig("poll_interval") or 2) * 1000
  colorMode = noctalia.getConfig("cat_color_mode") or "theme"
  customColor = noctalia.getConfig("cat_color") or "#E8A24C"
  frameIndex = 1
  syncGpuMonitoring()

  local pace = paceFor(activeValue())
  setTickInterval(pace == "sleep" and pollIntervalMs or TICK_MS)
  render(pace)
end
