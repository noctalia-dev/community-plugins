--!nonstrict
-- Desktop widget: one of four layouts (Status, Graph, Gauges, Readout) drawn
-- from the service's shared state. Position, size and the Background block
-- belong to Noctalia; this script only builds the ui.* tree.
--
-- Content is 252 px wide, a 272 px tile with the default background padding.
-- Type and icon sizes match the built-in Weather and System Monitor widgets.

local shared = require("./shared.luau")

local KEYS = shared.KEYS
local W = 252
local HERO = 31.5
local SECONDARY = 20
local BODY = 14
local CAPTION = 13
local DIM = 0.45
local GRAPH_H = 112
local TRACK = "on_surface/0.12"

-- Settings, all read up front so `noctalia plugins lint` sees every key

local display = noctalia.getConfig("display") or "status"
local colors = {
  base = noctalia.getConfig("color") or "primary",
  base2 = noctalia.getConfig("color2") or "secondary",
  base3 = noctalia.getConfig("color3") or "on_surface_variant",
  warning = noctalia.getConfig("warning_color") or "tertiary",
  alert = noctalia.getConfig("alert_color") or "error",
}
local highLoad = tonumber(noctalia.getConfig("high_load")) or 80
local dateStyle = noctalia.getConfig("date_style") or "short"

local statusCfg = {
  big1 = noctalia.getConfig("big1") or "battery_pct",
  big2 = noctalia.getConfig("big2") or "none",
  style = noctalia.getConfig("number_style") or "side_by_side",
  details = { noctalia.getConfig("detail1"), noctalia.getConfig("detail2"), noctalia.getConfig("detail3") },
}
local graphCfg = {
  line1 = noctalia.getConfig("line1") or "load_w",
  line2 = noctalia.getConfig("line2") or "none",
  span = noctalia.getConfig("time_span") or "2m",
  showLabel = noctalia.getConfig("show_label") ~= false,
}
local gaugeCfg = {
  layout = noctalia.getConfig("gauge_layout") or "rows",
  bars = { noctalia.getConfig("bar1"), noctalia.getConfig("bar2"), noctalia.getConfig("bar3") },
  statusLine = noctalia.getConfig("status_line") ~= false,
}
-- Readout switches, keyed by setting (shared.ROWS maps each row to one).
local rowsOn = {
  row_model_firmware = noctalia.getConfig("row_model_firmware"),
  row_ratings = noctalia.getConfig("row_ratings"),
  row_state = noctalia.getConfig("row_state"),
  row_voltages = noctalia.getConfig("row_voltages"),
  row_frequencies = noctalia.getConfig("row_frequencies"),
  row_battery = noctalia.getConfig("row_battery"),
  row_load = noctalia.getConfig("row_load"),
  row_line = noctalia.getConfig("row_line"),
  row_test = noctalia.getConfig("row_test"),
  row_last_event = noctalia.getConfig("row_last_event"),
  extra_nut = noctalia.getConfig("extra_nut"),
}

-- Shared state

local snap = noctalia.state.get(KEYS.snapshot)
local link = noctalia.state.get(KEYS.link)
local events = noctalia.state.get(KEYS.events)
local test = noctalia.state.get(KEYS.test)
local series = if display == "graph" then noctalia.state.get(shared.seriesKey(graphCfg.span)) else nil

-- Small builders

local function label(text: string, size: number, color: string, extra)
  local props = { text = text, fontSize = size, color = color }
  if extra then
    for key, value in extra do
      props[key] = value
    end
  end
  return ui.label(props)
end

local function glyph(name: string, size: number, color: string, opacity: number?)
  return ui.glyph({ name = name, size = size, color = color, opacity = opacity })
end

-- Stat color for a number or line: the entry's base color, switching to the
-- Warning/Alert colors with the UPS state.
local function statColor(statKey: string, base: string): string
  return shared.statColor(statKey, snap, base, colors, highLoad)
end

-- "Lost communication · last data 12 s ago"
local function lostText(now: number): string
  return shared.lostText(link, now)
end

-- Noctalia lines labels up by their boxes, not their baselines, so a small
-- label next to a big one sits low. lift() nudges it back up (pixel values
-- for Inter).
local LIFT = {
  [`{HERO}/{BODY}`] = 4,
  [`{SECONDARY}/{BODY}`] = 1,
  [`{HERO}/{SECONDARY}`] = 3,
}

local function lift(node, bigSize: number, smallSize: number)
  local px = LIFT[`{bigSize}/{smallSize}`] or 0
  if px == 0 then
    return node
  end
  return ui.column({ gap = 0 }, { node, ui.spacer({ height = px, flexGrow = 0 }) })
end

-- Big number with a smaller unit ("180" + "W") on one baseline; percentages
-- stay whole.
local function hero(statKey: string, size: number, color: string)
  local number, unit = shared.heroParts(statKey, snap)
  local parts = { label(number, size, color, { fontWeight = "bold" }) }
  if unit ~= "" then
    table.insert(parts, lift(label(unit, BODY, color), size, BODY))
  end
  return ui.row({ gap = 3, align = "end" }, parts)
end

local function messageTile(icon: string, title: string, reason: string?)
  local textWidth = W - 46
  local lines = { label(title, BODY, "on_surface", { fontWeight = "medium", width = textWidth }) }
  if reason ~= nil and reason ~= "" then
    -- The longer reasons wrap to three lines.
    table.insert(lines, label(reason, CAPTION, "on_surface_variant", { width = textWidth, maxLines = 4 }))
  end
  return ui.row({ width = W, gap = 12, align = "center" }, {
    glyph(icon, 34, "outline_variant"),
    ui.column({ width = textWidth, gap = 2 }, lines),
  })
end

-- Status

local function detailLine(ctx): string
  local parts = {}
  for _, key in statusCfg.details do
    if key ~= nil and key ~= "none" then
      local text = shared.detailText(key, snap, ctx)
      if text ~= nil then
        table.insert(parts, text)
      end
    end
  end
  return table.concat(parts, " · ")
end

local function statusLayout(ctx, level: string, lost: boolean)
  local dim = if lost then DIM else 1
  local powerColor = shared.levelColor(level, colors.base, colors)
  local detail = if lost then lostText(ctx.now) else detailLine(ctx)
  local detailColor = if level == "warning" or level == "alert"
    then shared.levelColor(level, colors.base, colors)
    else "on_surface_variant"
  local big1, big2 = statusCfg.big1, statusCfg.big2

  if big2 == "none" then
    return ui.row({ width = W, gap = 12, align = "center" }, {
      glyph(shared.powerIcon(snap, level), 42, powerColor, dim),
      ui.column({ flexGrow = 1, gap = 0 }, {
        ui.row({ opacity = dim }, { hero(big1, HERO, statColor(big1, "on_surface")) }),
        label(detail, CAPTION, detailColor, { maxLines = 1 }),
      }),
    })
  end

  if statusCfg.style == "main_secondary" then
    -- Numbers share a baseline with their captions underneath; the detail line
    -- runs full width below so the longer on-battery text still fits.
    return ui.column({ width = W, gap = 8 }, {
      ui.row({ width = W, gap = 12, align = "center" }, {
        glyph(shared.powerIcon(snap, level), 42, powerColor, dim),
        ui.column({ flexGrow = 1, gap = 0, opacity = dim }, {
          ui.row({ align = "end", justify = "space_between" }, {
            hero(big1, HERO, statColor(big1, "on_surface")),
            lift(hero(big2, SECONDARY, statColor(big2, colors.base2)), HERO, SECONDARY),
          }),
          ui.row({ justify = "space_between" }, {
            label(noctalia.tr("caption." .. big1), CAPTION, "on_surface_variant"),
            label(noctalia.tr("caption." .. big2), CAPTION, "on_surface_variant"),
          }),
        }),
      }),
      label(detail, CAPTION, detailColor, { width = W, maxLines = 1 }),
    })
  end

  -- Side by side: two equal numbers split by a thin rule, detail line below.
  local left = math.floor((W - 1) / 2)
  local right = W - 1 - left
  local function cell(statKey: string, icon: string, iconColor: string, width: number)
    return ui.column({ width = width, gap = 0, align = "center" }, {
      ui.row({ gap = 6, align = "center" }, {
        glyph(icon, 22, iconColor),
        hero(statKey, HERO, statColor(statKey, "on_surface")),
      }),
      label(noctalia.tr("caption." .. statKey), CAPTION, "on_surface_variant"),
    })
  end
  return ui.column({ width = W, gap = 8, align = "center" }, {
    ui.row({ width = W, align = "center", opacity = dim }, {
      cell(big1, shared.powerIcon(snap, level), powerColor, left),
      ui.separator({ orientation = "vertical", thickness = 1, color = TRACK, height = 48 }),
      cell(big2, shared.statIcon(big2, snap), statColor(big2, colors.base2), right),
    }),
    label(detail, CAPTION, detailColor, { width = W, textAlign = "center", maxLines = 1 }),
  })
end

-- Graph

local function normalized(statKey: string)
  local values = series and series[statKey]
  if values == nil then
    return nil
  end
  local lo, hi = shared.graphRange(statKey, values, snap)
  return shared.normalize(values, lo, hi)
end

local function legendItem(statKey: string, color: string)
  return ui.row({ gap = 4, align = "center" }, {
    glyph(shared.statIcon(statKey, snap), 16, color),
    label(shared.formatStat(statKey, snap), CAPTION, color, { fontWeight = "medium" }),
  })
end

local function graphLayout(ctx, _level: string, lost: boolean)
  local line1, line2 = graphCfg.line1, graphCfg.line2
  local color1 = statColor(line1, colors.base)
  local props = {
    width = W,
    height = GRAPH_H,
    values = normalized(line1) or {},
    color = color1,
    lineWidth = 0.75,
    fillOpacity = 0.2,
    opacity = if lost then DIM else 1,
  }
  local legend = { legendItem(line1, color1) }
  if line2 ~= "none" then
    local color2 = statColor(line2, colors.base2)
    props.values2 = normalized(line2) or {}
    props.color2 = color2
    table.insert(legend, legendItem(line2, color2))
  end

  local children = { ui.graph(props) }
  if lost then
    table.insert(children, label(lostText(ctx.now), CAPTION, "on_surface_variant", { width = W, textAlign = "center" }))
  elseif graphCfg.showLabel then
    table.insert(children, ui.row({ gap = 12, align = "center" }, legend))
  end
  return ui.column({ width = W, gap = 6, align = "center" }, children)
end

-- Gauges

local function activeBars()
  local bars = {}
  local bases = { colors.base, colors.base2, colors.base3 }
  for i, statKey in gaugeCfg.bars do
    if statKey ~= nil and statKey ~= "none" then
      table.insert(bars, { stat = statKey, color = statColor(statKey, bases[i]) })
    end
  end
  return bars
end

-- Vertical pill: a track with a fill growing from the bottom.
local function pill(fraction: number, color: string)
  return ui.column({ width = 8, height = 40, radius = 4, fill = TRACK, justify = "end" }, {
    ui.box({ width = 8, height = math.floor(fraction * 40 + 0.5), radius = 4, fill = color }),
  })
end

local function gaugesLayout(ctx, level: string, lost: boolean)
  local dim = if lost then DIM else 1
  local children = {}

  if gaugeCfg.statusLine or lost then
    local stateColor = shared.levelColor(level, colors.base2, colors)
    local stateText = if lost then lostText(ctx.now) else shared.statusText(snap)
    -- Let the state text wrap: the lost message is wider than the tile.
    local line = {
      ui.row({ flexGrow = 1, gap = 6, align = "center" }, {
        glyph(shared.powerIcon(snap, level), 16, stateColor),
        label(stateText, CAPTION, stateColor, { fontWeight = "medium", flexGrow = 1, maxLines = 2 }),
      }),
    }
    local source = if lost then nil else shared.sourceText(snap)
    if source ~= nil then
      table.insert(line, label(source, CAPTION, "on_surface_variant"))
    end
    table.insert(children, ui.row({ width = W, gap = 8, align = "center" }, line))
  end

  local bars = activeBars()
  if #bars == 0 then
    if #children == 0 then
      table.insert(children, label(noctalia.tr("gauges.empty"), CAPTION, "on_surface_variant", { width = W, maxLines = 2 }))
    end
  elseif gaugeCfg.layout == "columns" then
    local colW = math.floor(W / math.max(#bars, 1))
    local columns = {}
    for _, bar in bars do
      table.insert(columns, ui.column({ width = colW, gap = 6, align = "center" }, {
        glyph(shared.statIcon(bar.stat, snap), 18, bar.color),
        ui.progress({
          progress = shared.gaugeFraction(bar.stat, snap),
          fill = bar.color, track = TRACK, radius = 3, width = colW - 16, height = 6,
        }),
        label(shared.formatStat(bar.stat, snap), CAPTION, "on_surface", { fontWeight = "medium" }),
      }))
    end
    table.insert(children, ui.row({ width = W, opacity = dim }, columns))
  elseif gaugeCfg.layout == "pills" then
    local groups = { ui.spacer({ flexGrow = 1 }) }
    for _, bar in bars do
      table.insert(groups, ui.row({ gap = 7, align = "center" }, {
        glyph(shared.statIcon(bar.stat, snap), 16, bar.color),
        pill(shared.gaugeFraction(bar.stat, snap), bar.color),
        label(shared.formatStat(bar.stat, snap), CAPTION, "on_surface", { fontWeight = "medium" }),
      }))
      table.insert(groups, ui.spacer({ flexGrow = 1 }))
    end
    table.insert(children, ui.row({ width = W, align = "center", opacity = dim }, groups))
  else
    local valueW = 76 -- room for "23 h 59 min"
    for _, bar in bars do
      table.insert(children, ui.row({ width = W, gap = 10, align = "center", opacity = dim }, {
        glyph(shared.statIcon(bar.stat, snap), 16, bar.color),
        ui.progress({
          progress = shared.gaugeFraction(bar.stat, snap),
          fill = bar.color, track = TRACK, radius = 3, width = W - 16 - valueW - 20, height = 6,
        }),
        label(shared.formatStat(bar.stat, snap), CAPTION, "on_surface", {
          width = valueW, textAlign = "end", fontWeight = "medium",
        }),
      }))
    end
  end
  return ui.column({ width = W, gap = 9 }, children)
end

-- Readout

local function readoutLayout(ctx, level: string, lost: boolean)
  local rows = {}
  if lost then
    table.insert(rows, label(lostText(ctx.now), CAPTION, "on_surface_variant", { width = W }))
  end
  for _, row in shared.ROWS do
    if rowsOn[row.setting] then
      local value = shared.rowValue(row.key, snap, ctx)
      if value ~= nil then
        local valueColor = if row.key == "state" then shared.levelColor(level, colors.base2, colors) else "on_surface"
        table.insert(rows, ui.row({ width = W, gap = 12, align = "start", opacity = if lost then DIM else 1 }, {
          label(noctalia.tr("rows." .. row.key), CAPTION, "on_surface_variant"),
          label(value, CAPTION, valueColor, { flexGrow = 1, textAlign = "end", maxLines = 2, fontWeight = "medium" }),
        }))
      end
    end
  end
  if #rows == 0 then
    table.insert(rows, label(noctalia.tr("readout.empty"), CAPTION, "on_surface_variant", { width = W, maxLines = 2 }))
  end
  return ui.column({ width = W, gap = 5 }, rows)
end

-- Render

local tickMs = 0

function render()
  local now = os.time()
  local level = shared.level(snap, link)
  local tree
  if level == "none" then
    if link == nil or link.state == "starting" then
      tree = messageTile("plug", noctalia.tr("status.starting"), nil)
    else
      tree = messageTile("plug-off", noctalia.tr("status.none"), link.message)
    end
  else
    local ctx = { style = dateStyle, now = now, test = test, lastEvent = shared.lastPowerEvent(events) }
    local lost = level == "lost"
    if display == "graph" then
      tree = graphLayout(ctx, level, lost)
    elseif display == "gauges" then
      tree = gaugesLayout(ctx, level, lost)
    elseif display == "readout" then
      tree = readoutLayout(ctx, level, lost)
    else
      tree = statusLayout(ctx, level, lost)
    end
  end

  -- Lost data shows its age by the second; otherwise a slow tick keeps
  -- relative dates current between snapshots.
  local wanted = if level == "lost" then 1000 else 60000
  if wanted ~= tickMs then
    tickMs = wanted
    noctalia.setUpdateInterval(wanted)
  end
  desktopWidget.render(tree)
end

-- The link always arrives right after the snapshot, so it does the rendering.
noctalia.state.watch(KEYS.snapshot, function(value)
  snap = value
end)
noctalia.state.watch(KEYS.link, function(value)
  link = value
  render()
end)
noctalia.state.watch(KEYS.events, function(value)
  events = value
  render()
end)
noctalia.state.watch(KEYS.test, function(value)
  test = value
  render()
end)
if display == "graph" then
  noctalia.state.watch(shared.seriesKey(graphCfg.span), function(value)
    series = value
    render()
  end)
end

function update()
  render()
end
