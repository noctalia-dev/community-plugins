--!nonstrict
-- Noctalia bar widget for NaN Usage.
--
-- The widget holds no logic of its own. `service.luau` polls NaN and publishes what
-- came back on the plugin's shared state; `shared.luau` turns that into the record
-- this file paints. Nothing is spawned, no command has to be on PATH, and the
-- countdowns are rebuilt on every tick from the same data — so they move between
-- polls instead of only when one lands.
--
-- Clicking opens the panel, which Noctalia places next to the widget, so there is
-- no window rule to get wrong. Right-clicking opens this plugin's own settings.

local shared = require("./shared.luau")
local prices = require("./prices.luau")

-- Read per paint rather than once at load, so a change in the settings page lands
-- without a reload. `~= false` for a setting whose manifest default is true, `== true`
-- for one whose default is false: an unset value has to mean what the manifest says,
-- and show_icon defaults to true.
local function showIcon()
  return noctalia.getConfig("show_icon") ~= false
end

local function showGlyph()
  return noctalia.getConfig("show_glyph") == true
end

local function glyphName()
  return noctalia.getConfig("glyph") or "chart-pie"
end

local function showTooltip()
  return noctalia.getConfig("show_tooltip") ~= false
end

-- panel | nothing. The panel is Noctalia's own surface.
local function leftClick()
  return noctalia.getConfig("left_click") or "panel"
end

local function iconStyle()
  return noctalia.getConfig("icon_style") or "ghost"
end

-- percent | used | remaining: what the figure in the bar counts.
local function barValue()
  return noctalia.getConfig("bar_value") or "percent"
end

local function showReset()
  return noctalia.getConfig("show_reset") ~= false
end

local function showCache()
  return noctalia.getConfig("show_cache") == true
end

-- The panel this plugin owns, addressed the way Noctalia names entries.
local PANEL_ID = "cmoro-deusto/nan-usage:panel"

-- The NaN logo, next to this file. The PNGs are rasterised from the SVG beside
-- them, because whether the shell's Qt build can render an SVG is not something to
-- bet on. An image replaces the glyph — the API shows one or the other — so this
-- wins over show_glyph.
--
-- 14 to sit with the glyphs around it: the widget next to this one on a bar draws its
-- provider marks at size 14, and a mark drawn larger than its neighbours' reads as
-- the odd one out. The rasters are 96px squares of a square viewBox, so the draw is
-- neither stretched nor inset.
local ICON_COLOR = "nan.png"
local ICON_GHOST_ON_DARK = "nan-ghost-white.png"
local ICON_GHOST_ON_LIGHT = "nan-ghost-black.png"
local ICON_SIZE = 14

-- The gauges `panel_gauge` offers. bar: ui.progress, the control a bar widget renders a
-- level with. segments10 and segments5: cells that light up, one per 10% or 20%, and
-- ring: a ring filling by 10% steps, both drawn from the rasters in gauges/ (see
-- generate-icons.sh for why they are rasters). battery: Noctalia's battery glyph, draining by quarters as the
-- credits go. sparkline: the period's credits per day, a trend rather than a level.
local GAUGE_WIDTH = 34
local GAUGE_HEIGHT = 5
local SEGMENT_HEIGHT = 8
local RING_SIZE = 14
local SPARK_HEIGHT = 12

-- The track the unlit parts are drawn in, the same for every gauge.
local TRACK = "on_surface/0.16"

-- The two alarm colours. The healthy level keeps the theme's own text colour, so
-- the bar stays quiet until there is something to say.
local COLOR_WARN = "#ff7800"
local COLOR_CRIT = "#e01b24"

-- The cache share has a colour of its own, the one the panel gives cached input, so
-- it is not read as a second usage figure.
local COLOR_CACHE = "#3fb8a8"

-- The muted ink for the countdown, which is context rather than the reading itself.
local MUTED = "on_surface_variant"

-- Text sizes, matching the widgets this sits beside: the figure reads at the bar's
-- size and carries the alarm colour, the countdown and the cache share are a point
-- smaller. In a row centred on the cross axis a smaller label sits a little above
-- the centre of its taller neighbour, which is what makes the pair read as one
-- figure rather than two.
local SIZE_VALUE = 11
local SIZE_CONTEXT = 10

-- How often the record is rebuilt from the data already held. Polling is the
-- service's business; this only moves the countdowns on, so 15 s is plenty and
-- costs nothing.
local UPDATE_MS = 15000

-- Read per tick rather than once, so a change in the settings page lands without
-- a reload.
local function config()
  return {
    gauge = noctalia.getConfig("panel_gauge") or "bar",
    pollSeconds = tonumber(noctalia.getConfig("interval")) or 300,
  }
end

-- The tooltip is the detail the bar has no room for: the period's credits, the
-- cache, and one line per model. Noctalia draws it as key/value rows and cuts a
-- value off past about fourteen characters, with no way to set the font or the
-- width, so every value here stays short and a second detail gets its own row
-- rather than a "·" on the first.
local function rowsFor(record)
  local rows = {}
  local function add(key, value)
    table.insert(rows, { key = key, value = value })
  end
  if record.error ~= nil and record.error ~= "" then
    local text = record.error
    if record.stale == true then
      text = text .. " (showing the last data)"
    end
    add("error", text)
  end
  local account = record.account
  if account ~= nil then
    if account.frozen then
      add("Subscription", "paused")
    end
    add("Used", account.usedText .. " · " .. account.pctText)
    add("Allowance", account.allowanceText)
    add("Left", account.remainingText)
    if account.packs > 0 then
      add("Packs", account.packsText)
      if account.packsExpire ~= "" then
        add("Packs expire", account.packsExpire)
      end
    end
    if account.resetsInLong ~= "" then
      add("Resets in", account.resetsInLong)
      add("Renews", account.resetsAtText)
    end
    if account.projectedText ~= "" then
      add("Pace at reset", account.projectedText .. " · " .. account.projectedPctText)
    end
  end
  add("Today", record.todayText or "0")
  local tokens = record.tokens
  if tokens ~= nil and tokens.cachedPctText ~= "" then
    add("Cached", tokens.cachedPctText .. " of input")
    add("New input", tokens.newText)
    add("Cached input", tokens.cachedText)
    add("Output", tokens.outputText)
  end
  if record.savedText ~= nil and record.savedText ~= "" then
    add("Cache saved", record.savedText)
  end
  for _, model in ipairs(record.models or {}) do
    if model.used then
      add(model.model, model.creditsText .. " · " .. model.shareText)
    end
  end
  return rows
end

-- Which raster to draw: the coloured mark, or the ghost in whichever ink the theme
-- will read.
local function iconFile()
  if iconStyle() == "color" then
    return ICON_COLOR
  end
  if noctalia.isDarkMode() then
    return ICON_GHOST_ON_DARK
  end
  return ICON_GHOST_ON_LIGHT
end

-- The colour a level draws in. "on_surface" for a healthy one, so the widget keeps
-- the theme's own ink until there is something to say.
local function levelColor(level)
  if level == "crit" then
    return COLOR_CRIT
  end
  if level == "warn" then
    return COLOR_WARN
  end
  return "on_surface"
end

-- The figure, its countdown and the cache share, as separate labels so each can
-- carry its own size and ink. `record` is nil when the widget shows a dash.
local function textNodes(level, record)
  if record == nil then
    return ui.label({ text = "—", color = levelColor(level) })
  end
  local account = record.account
  local parts = {
    ui.label({
      text = shared.barFigure(account, barValue()),
      fontSize = SIZE_VALUE,
      fontWeight = "semibold",
      color = levelColor(level),
      maxLines = 1,
    }),
  }
  if showReset() and not account.frozen and account.resetsIn ~= "" then
    parts[#parts + 1] = ui.label({
      text = account.resetsIn,
      fontSize = SIZE_CONTEXT,
      color = MUTED,
      maxLines = 1,
    })
  end
  if showCache() and record.tokens ~= nil and record.tokens.cachedPctText ~= "" then
    parts[#parts + 1] = ui.label({
      text = record.tokens.cachedPctText .. " cached",
      fontSize = SIZE_CONTEXT,
      color = COLOR_CACHE,
      maxLines = 1,
    })
  end
  return ui.row({ gap = 3, align = "center" }, parts)
end

-- The theme half of a gauge raster's name: the rasters are drawn once for a dark
-- theme and once for a light one, where the ink and the track differ.
local function gaugeTheme()
  return noctalia.isDarkMode() and "dark" or "light"
end

-- A segmented bar: one raster per number of lit cells, so the gaps between cells
-- stay even at any scale (a row of separate boxes rounds each gap on its own). Any
-- usage at all lights the first cell, so a period that has started never reads as
-- untouched.
local function segmentsFile(count, level, percent)
  local lit = 0
  if percent > 0 then
    lit = math.max(1, math.min(count, math.floor(percent / (100 / count) + 0.5)))
  end
  return "gauges/seg" .. count .. "-" .. gaugeTheme() .. "-" .. (level or "ok") .. "-" .. lit .. ".png"
end

-- The ring raster for a level, in the 10% step nearest the usage, and never empty
-- once the period has any.
local function ringFile(level, percent)
  local step = math.floor(math.max(0, math.min(percent, 100)) / 10 + 0.5) * 10
  if percent > 0 and step == 0 then
    step = 10
  end
  return "gauges/ring-" .. gaugeTheme() .. "-" .. (level or "ok") .. "-" .. step .. ".png"
end

-- The battery glyph with as many bars as quarters of the allowance are left.
local function batteryGlyph(percent)
  local bars = math.floor((100 - math.max(0, math.min(percent, 100))) / 25 + 0.5)
  if bars <= 0 then
    return "battery"
  end
  return "battery-" .. bars
end

-- The days of the period so far, each as its share of the busiest one. A graph needs
-- two points to draw a line, so a single day is drawn flat.
local function sparkValues(record)
  local values, top = {}, 0
  for _, day in ipairs(record and record.days or {}) do
    if not day.future then
      values[#values + 1] = day.credits
      top = math.max(top, day.credits)
    end
  end
  for index, value in ipairs(values) do
    values[index] = top > 0 and value / top or 0
  end
  if #values == 1 then
    values[2] = values[1]
  end
  return values
end

local function gaugeNode(gauge, level, percent, record)
  percent = math.max(0, tonumber(percent) or 0)
  if gauge == "segments10" or gauge == "segments5" then
    local count = gauge == "segments10" and 10 or 5
    return ui.image({ path = segmentsFile(count, level, percent), width = GAUGE_WIDTH, height = SEGMENT_HEIGHT })
  end
  if gauge == "ring" then
    return ui.image({ path = ringFile(level, percent), width = RING_SIZE, height = RING_SIZE })
  end
  if gauge == "battery" then
    return ui.glyph({ name = batteryGlyph(percent), size = ICON_SIZE + 2, color = levelColor(level) })
  end
  if gauge == "sparkline" then
    return ui.graph({
      values = sparkValues(record),
      color = levelColor(level),
      lineWidth = 1.5,
      fillOpacity = 0.18,
      width = GAUGE_WIDTH,
      height = SPARK_HEIGHT,
    })
  end
  return ui.progress({
    progress = math.min(percent, 100) / 100,
    fill = levelColor(level),
    track = TRACK,
    width = GAUGE_WIDTH,
    height = GAUGE_HEIGHT,
    radius = 3,
  })
end

-- The widget as a tree: the mark, the gauge, the text. One node set per paint, so
-- nothing is left over from the render before it — the same reason the panel's
-- cards set every prop.
local function nodesFor(level, record, percent, gauge)
  local nodes = {}
  if showIcon() then
    table.insert(nodes, ui.image({ path = iconFile(), width = ICON_SIZE, height = ICON_SIZE }))
  elseif showGlyph() then
    table.insert(nodes, ui.glyph({ name = glyphName(), size = ICON_SIZE, color = levelColor(level) }))
  end
  if gauge ~= "none" then
    table.insert(nodes, gaugeNode(gauge, level, percent, record))
  end
  table.insert(nodes, textNodes(level, record))
  return nodes
end

local function paint(level, record, percent, gauge, tooltip)
  barWidget.render(ui.row({ gap = 6, align = "center" }, nodesFor(level, record, percent, gauge)))
  if not showTooltip() then
    return
  end
  if tooltip == nil or (type(tooltip) == "table" and #tooltip == 0) then
    barWidget.clearTooltip()
  else
    barWidget.setTooltip(tooltip)
  end
end

-- No data at all yet, or nothing to show: a dash, no gauge — a hollow bar next to a
-- dash reads as a broken widget — and the reason in the tooltip.
local function paintNothing(record)
  local reason = record.error
  if reason == nil or reason == "" then
    reason = "no data"
  end
  if record.stale == true then
    reason = reason .. " (showing the last data)"
  end
  paint("ok", nil, 0, "none", reason)
end

local function paintRecord(record)
  local account = record.account
  if account == nil then
    if record.ok and (record.error == nil or record.error == "") then
      paintNothing({ error = "This account isn't billed in credits" })
    else
      paintNothing(record)
    end
    return
  end
  -- A paused subscription draws no gauge: it measures nothing while requests are
  -- refused.
  local gauge = account.frozen and "none" or (record.gauge or "bar")
  local percent = account.usingPacks and 100 or account.pct
  paint(account.level, record, percent, gauge, rowsFor(record))
end

local function repaint(data)
  if data == nil then
    paintNothing({ error = "waiting for the first poll" })
    return
  end
  paintRecord(shared.build(data, config(), os.time(), prices))
end

-- The service publishes as soon as a poll lands, so the bar never waits for the
-- next tick to show it.
noctalia.state.watch("data", repaint)

-- Between polls, rebuild from the data already held: that is what moves the
-- countdowns, and it is the only reason this widget has a tick at all.
function update()
  noctalia.setUpdateInterval(UPDATE_MS)
  repaint(noctalia.state.get("data"))
end

function onClick()
  if leftClick() == "nothing" then
    return
  end
  noctalia.togglePanel(PANEL_ID)
end

-- The plugin's own page is the cog, and it is where the key path, the poll interval
-- and the gauge live.
function onRightClick()
  noctalia.openSettings()
end

repaint(noctalia.state.get("data"))
