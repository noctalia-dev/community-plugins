--!nonstrict
-- Cat: an animated running cat bar widget. Pace reflects CPU usage, read
-- from the host's system monitor, with separately configurable walk/run
-- thresholds. Color follows the theme's secondary role by default, or a
-- pinned custom color.
--
-- The cat shape is a custom pictographic font (fonts/catwalk2.otf, traced
-- from the MIT-licensed CatWalk plasmoid by Driglu4it) so it can be colored
-- like any other bar text: "a" = idle/asleep, "b".."f" = the 5-frame run
-- cycle. Each glyph's advance width is trimmed to the shared ink extent
-- (non-negative left bearing, no dead trailing space) so bar layout doesn't
-- overlap the previous widget or leave a large gap before the next one.
--
-- Font registration is process-global and keyed by file path/family, so this
-- filename must change (not just its contents) whenever the glyph set changes
-- during development, or the shell keeps rendering whatever it cached the
-- first time it saw this path.

local catFont = noctalia.loadFont("fonts/catwalk2.otf")

local GLYPH_IDLE = "a"
local RUN_GLYPHS = { "b", "c", "d", "e", "f" }

local TICK_MS = 80
local WALK_MAX_MS = 380
local WALK_MIN_MS = 180
local RUN_MAX_MS = 160
local RUN_MIN_MS = 55

-- Bounce (plugin_api 52): a paint-only translateY that lifts the cat once per
-- stride (one hop per pass through the 5 run frames), as a fraction of the
-- cat size so it scales with cat_size and with the bigger panel cat. Paint-
-- only means the bar layout never reflows; the capsule may clip the very top
-- of the hop at large sizes on a thin bar.
local BOUNCE_HEIGHT = 0.08

local catSize = noctalia.getConfig("cat_size")
local showCpuPercent = noctalia.getConfig("show_cpu_percent")
local bounce = noctalia.getConfig("bounce")
local walkThreshold = noctalia.getConfig("walk_threshold")
local runThreshold = noctalia.getConfig("run_threshold")
local pollIntervalMs = noctalia.getConfig("poll_interval") * 1000
local colorMode = noctalia.getConfig("cat_color_mode")
local customColor = noctalia.getConfig("cat_color")

local frameIndex = 1
local frameElapsed = 0
local frameDurationMs = WALK_MAX_MS

local sampleElapsed = pollIntervalMs -- sample immediately on first tick
local cpuPercent = 0

-- CPU usage comes from the host's system monitor rather than our own
-- /proc/stat parsing. The host refreshes that sample on its own cadence
-- ([system.monitor] cpu_poll_seconds, 2s by default), so poll_interval only
-- throttles how often we pick it up. nil means the monitor is disabled or has
-- no sample yet; keep the last reading (0 until the first one) in that case.
local function sampleCpu()
  local stats = noctalia.systemStats()
  if stats == nil or stats.cpu == nil or stats.cpu.usagePercent == nil then
    return
  end

  cpuPercent = math.clamp(stats.cpu.usagePercent, 0, 100)
end

-- Returns ("idle" | "walk" | "run", frame-duration-ms-for-that-pace).
local function paceFor(cpu)
  local runFloor = math.max(runThreshold, walkThreshold + 1)

  if cpu < walkThreshold then
    return "idle", WALK_MAX_MS
  elseif cpu < runFloor then
    local range = math.max(runFloor - walkThreshold, 1)
    local t = math.clamp((cpu - walkThreshold) / range, 0, 1)
    return "walk", WALK_MAX_MS - t * (WALK_MAX_MS - WALK_MIN_MS)
  else
    local range = math.max(100 - runFloor, 1)
    local t = math.clamp((cpu - runFloor) / range, 0, 1)
    return "run", RUN_MAX_MS - t * (RUN_MAX_MS - RUN_MIN_MS)
  end
end

local function resolveColor()
  if colorMode == "custom" and customColor and customColor ~= "" then
    return customColor
  end
  return "secondary"
end

-- Returns the current lift as a fraction of cat size (0 = on the ground),
-- tracing half a sine over one stride: frames 1..5 plus progress through the
-- current frame, so it moves smoothly on every 80ms tick, not just per frame.
local function bounceLift(pace)
  if not bounce or pace == "idle" then
    return 0
  end
  local progress = math.clamp(frameElapsed / frameDurationMs, 0, 1)
  local phase = ((frameIndex - 1) + progress) / #RUN_GLYPHS
  return BOUNCE_HEIGHT * math.sin(phase * math.pi)
end

-- The click panel (cat_panel.luau) runs in a separate runtime; it mirrors the
-- bar cat from this shared-state snapshot, republished whenever the visible
-- glyph, whole CPU percent, color, or bounce lift changes (so at most once
-- per 80ms tick while moving, and only on sample/theme changes while idle).
-- `lift` is the bounce as a fraction of cat size, rounded so tiny changes
-- don't republish.
local lastPublished = nil
local function publishState(pace, glyph, color, lift)
  local cpu = math.floor(cpuPercent)
  local liftKey = math.floor(lift * 1000 + 0.5)
  local key = `{glyph}|{cpu}|{color}|{pace}|{liftKey}`
  if key == lastPublished then
    return
  end
  lastPublished = key
  noctalia.state.set("cat", { glyph = glyph, cpu = cpu, color = color, pace = pace, lift = liftKey / 1000 })
end

local function render(pace)
  local glyph = pace == "idle" and GLYPH_IDLE or RUN_GLYPHS[frameIndex]
  local color = resolveColor()
  local lift = bounceLift(pace)

  publishState(pace, glyph, color, lift)

  local children = {
    ui.label({
      text = glyph,
      fontFamily = catFont,
      baseline = "inkCentered",
      fontSize = catSize,
      color = color,
      translateY = -lift * catSize,
    }),
  }

  if showCpuPercent then
    table.insert(children, ui.label({ text = `{math.floor(cpuPercent)}%`, fontSize = 11, color = color }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 4, align = "center" }, children))
  barWidget.setTooltip(noctalia.tr("tooltip", {
    percent = tostring(math.floor(cpuPercent)),
    pace = noctalia.tr(`pace.{pace}`),
  }))
end

noctalia.setUpdateInterval(TICK_MS)

function update()
  sampleElapsed += TICK_MS
  if sampleElapsed >= pollIntervalMs then
    sampleElapsed = 0
    sampleCpu()
  end

  local pace, duration = paceFor(cpuPercent)
  frameDurationMs = duration

  if pace == "idle" then
    frameElapsed = 0
    frameIndex = 1
  else
    frameElapsed += TICK_MS
    if frameElapsed >= frameDurationMs then
      frameElapsed = 0
      frameIndex = frameIndex % #RUN_GLYPHS + 1
    end
  end

  render(pace)
end

function onClick()
  noctalia.togglePanel("dotnetrob/cat:panel")
end

function onConfigChanged()
  catSize = noctalia.getConfig("cat_size")
  showCpuPercent = noctalia.getConfig("show_cpu_percent")
  bounce = noctalia.getConfig("bounce")
  walkThreshold = noctalia.getConfig("walk_threshold")
  runThreshold = noctalia.getConfig("run_threshold")
  pollIntervalMs = noctalia.getConfig("poll_interval") * 1000
  colorMode = noctalia.getConfig("cat_color_mode")
  customColor = noctalia.getConfig("cat_color")
  render((paceFor(cpuPercent)))
end
