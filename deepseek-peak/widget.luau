--!nonstrict
-- DeepSeek Peak Hours - Noctalia v5 bar widget entry.
-- API: global update()/onClick(); noctalia.*; barWidget.*; ui.*
-- Schedule logic lives in lib/schedule.luau; runtime overrides (provider)
-- live in lib/settings.luau. Right-click opens the widget's settings via the
-- manifest's [widget.actions] default.

local schedule = require("./lib/schedule.luau")
local settings = require("./lib/settings.luau")

local isPeakNow = false
local secondsToNext = 0
local progress = 0
local drift = false

local function provider()
  return settings.provider()
end

local function color()
  if drift then
    return settings.get("driftColor", "#fbbf24")
  end
  if isPeakNow then
    return settings.get("peakColor", "#f87171")
  end
  return settings.get("offPeakColor", "#4ade80")
end

local function label()
  local mode = settings.get("displayMode", "compact")
  local countdown = schedule.formatCountdown(secondsToNext)
  if mode == "icon" then
    return ""
  elseif mode == "full" then
    return (isPeakNow and noctalia.tr("bar.peak") .. " " or noctalia.tr("bar.off-peak") .. " ")
      .. countdown
  end
  return countdown
end

-- Dual-provider tooltip grid; the active provider is marked with a dot.
local function tooltipRows()
  local now = os.time()
  local rows = {}
  for _, which in ipairs({ "deepseek", "ollama" }) do
    local active = which == provider()
    local peak = schedule.isPeakAt(now, which)
    local secs = schedule.secondsUntilNext(now, which)
    local ratio = schedule.progress(now, which)
    table.insert(rows, {
      key = (active and "● " or "○ ") .. schedule.providerName(which),
      value = (peak and noctalia.tr("bar.tooltip-peak") or noctalia.tr("bar.tooltip-off-peak"))
        .. " · " .. schedule.formatHMS(secs)
        .. " · " .. tostring(math.floor(ratio * 100 + 0.5)) .. "%",
    })
  end
  if drift then
    table.insert(rows, { key = noctalia.tr("bar.peak"), value = noctalia.tr("bar.drift-suffix") })
  end
  return rows
end

local function render()
  local mode = settings.get("displayMode", "compact")
  local stateColor = color()
  local vertical = barWidget.isVertical()
  local glyph = ui.glyph({ name = "circle-filled", size = 10, color = stateColor })
  local text = ui.label({
    text = label(),
    fontWeight = "bold",
    color = stateColor,
    visible = mode ~= "icon",
  })

  if vertical then
    barWidget.render(ui.column({ gap = 4, align = "center" }, { glyph, text }))
  else
    -- Dot + countdown on top, block-progress gauge underneath (clipped to the
    -- bar capsule thickness).
    barWidget.render(ui.column({ gap = 1, align = "center" }, {
      ui.row({ gap = 6, align = "center" }, { glyph, text }),
      ui.progress({
        progress = progress,
        fill = stateColor,
        track = "surface_variant",
        radius = 2,
        height = 3,
        width = 56,
        visible = mode ~= "icon",
      }),
    }))
  end

  if settings.get("showTooltip", true) then
    barWidget.setTooltip(tooltipRows())
  else
    barWidget.clearTooltip()
  end
end

local function refresh()
  local now = os.time()
  local which = provider()
  local snap = schedule.snapshot(now, which)
  isPeakNow = snap.isPeak
  secondsToNext = snap.secondsToNext
  progress = snap.progress
  render()
end

function update()
  refresh()
end

function onClick()
  noctalia.togglePanel("alpzy/deepseek-peak:panel")
end

drift = noctalia.state.get("deepseek-peak.drift") == true
noctalia.state.watch("deepseek-peak.drift", function(value)
  drift = value == true
  refresh()
end)

settings.watch(function()
  refresh()
end)

noctalia.setUpdateInterval(1000)
refresh()
