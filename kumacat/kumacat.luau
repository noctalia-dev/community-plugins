--!nonstrict
-- KumaCat: an animated running cat bar widget and hardware telemetry monitor.
-- Speed reflects real-time system load with zero-overhead idle sleep.

local catFont = noctalia.loadFont("fonts/kumacat.otf")

local GLYPH_IDLE = "a"
local RUN_GLYPHS = { "b", "c", "d", "e", "f" }

local TICK_MS = 80
local WALK_MAX_MS = 380
local WALK_MIN_MS = 180
local RUN_MAX_MS = 160
local RUN_MIN_MS = 55

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

local sampleElapsed = pollIntervalMs
local cpuPercent = 0
local memPercent = 0
local memUsedBytes = 0
local memTotalBytes = 0
local gpuPercent = 0
local cpuTempC = nil
local gpuTempC = nil

local function sampleTelemetry()
  local stats = noctalia.systemStats()
  if stats == nil then
    return
  end

  if stats.cpu and stats.cpu.usagePercent ~= nil then
    cpuPercent = math.clamp(stats.cpu.usagePercent, 0, 100)
    cpuTempC = stats.cpu.tempC
  end

  if stats.memory then
    local used = stats.memory.used or 0
    local total = stats.memory.total or 0
    memUsedBytes = used
    memTotalBytes = total
    if total > 0 then
      memPercent = math.clamp((used / total) * 100, 0, 100)
    end
  end

  if stats.gpu and stats.gpu.usagePercent ~= nil then
    gpuPercent = math.clamp(stats.gpu.usagePercent, 0, 100)
    gpuTempC = stats.gpu.tempC
  end
end

local function activeValue()
  if driveMetric == "memory" then
    return memPercent
  elseif driveMetric == "gpu" then
    return gpuPercent
  end
  return cpuPercent
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

local lastPublishedKey = nil
local function publishState(pace, glyph, color, currentVal)
  local key = `{glyph}|{math.floor(currentVal)}|{color}|{pace}|{math.floor(cpuPercent)}|{math.floor(memPercent)}|{math.floor(gpuPercent)}`
  if key == lastPublishedKey then
    return
  end
  lastPublishedKey = key
  noctalia.state.set("kumacat", {
    glyph = glyph,
    pace = pace,
    color = color,
    driveMetric = driveMetric,
    metricValue = math.floor(currentVal),
    cpuPercent = math.floor(cpuPercent),
    cpuTemp = cpuTempC,
    memPercent = math.floor(memPercent),
    memUsedGiB = memUsedBytes / (1024 ^ 3),
    memTotalGiB = memTotalBytes / (1024 ^ 3),
    gpuPercent = math.floor(gpuPercent),
    gpuTemp = gpuTempC,
  })
end

local function render(pace)
  local currentVal = activeValue()
  local glyph = pace == "sleep" and GLYPH_IDLE or RUN_GLYPHS[frameIndex]
  local color = resolveColor()

  publishState(pace, glyph, color, currentVal)

  local children = {
    ui.label({
      text = glyph,
      fontFamily = catFont,
      baseline = "inkCentered",
      fontSize = catSize,
      color = color,
    }),
  }

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

  local paceLabel = pace == "sleep" and "Idle Sleep (0 FPS)" or (pace == "walk" and "Walking" or "Sprinting")
  local tipLines = {
    `KumaCat: {paceLabel}`,
    `CPU: {math.floor(cpuPercent)}%` .. (cpuTempC and ` ({math.floor(cpuTempC)}°C)` or ""),
    `Memory: {string.format("%.1f", memUsedBytes / (1024 ^ 3))} / {string.format("%.1f", memTotalBytes / (1024 ^ 3))} GiB ({math.floor(memPercent)}%)`,
  }
  if gpuPercent > 0 or gpuTempC ~= nil then
    table.insert(tipLines, `GPU: {math.floor(gpuPercent)}%` .. (gpuTempC and ` ({math.floor(gpuTempC)}°C)` or ""))
  end
  table.insert(tipLines, "Click to open Telemetry HUD")
  barWidget.setTooltip(table.concat(tipLines, "\n"))
end

noctalia.setUpdateInterval(TICK_MS)

function update()
  sampleElapsed += TICK_MS
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
  else
    frameElapsed += TICK_MS
    if frameElapsed >= frameDurationMs then
      frameElapsed = 0
      frameIndex = (frameIndex % #RUN_GLYPHS) + 1
    end
  end

  render(pace)
end

function onClick()
  noctalia.togglePanel("mhdomer/kumacat:panel")
end

function onConfigChanged()
  catSize = noctalia.getConfig("cat_size") or 24
  driveMetric = noctalia.getConfig("drive_metric") or "cpu"
  showMetricPercent = noctalia.getConfig("show_metric_percent") or false
  sleepThreshold = noctalia.getConfig("sleep_threshold") or 5
  turboThreshold = noctalia.getConfig("turbo_threshold") or 75
  pollIntervalMs = (noctalia.getConfig("poll_interval") or 2) * 1000
  colorMode = noctalia.getConfig("cat_color_mode") or "theme"
  customColor = noctalia.getConfig("cat_color") or "#E8A24C"
  render((paceFor(activeValue())))
end
