--!nonstrict
-- KVitals bar widget: compact metric chips that tint toward the accent
-- color as a value crosses its activity threshold.
--
-- Left click toggles the sparkline panel. Right click opens the settings.
-- The host's built-in middle-click default (open this widget's settings)
-- stays untouched. The tree is one control tall, so the capsule clips
-- cleanly in a horizontal or vertical bar.

local format = require("./lib/format.luau")
local chips = require("./lib/chips.luau")

local PANEL_ID = "royalebiskut/kvitals:sparkline"

local sample = noctalia.state.get("kvitals.sample")
local config = noctalia.state.get("kvitals.config")
local ready = noctalia.state.get("kvitals.ready") == true

-- Per-instance presentation settings (the host rebuilds this entry when
-- they change).
local font_size = noctalia.getConfig("font_size") or 12
local display_mode = noctalia.getConfig("display_mode") or "both"
local hide_absent = noctalia.getConfig("hide_absent")
if hide_absent == nil then hide_absent = true end

local function chipColor(chip)
  if chip.tint == "critical" then return config.accent end
  if chip.tint == "active" then return format.withAlpha(config.accent, 0.65) end
  return config.font
end

local function hasSysfsData(s)
  return s.battery ~= nil or s.fanRpm ~= nil or s.diskTempC ~= nil
    or s.cpuFreqHz ~= nil or s.diskIo ~= nil
end

local function chipNode(chip)
  local color = chipColor(chip)
  local label = ui.label({
    text = chip.text,
    fontSize = font_size,
    fontWeight = "medium",
    color = color,
  })

  if display_mode == "text" then
    return label
  end

  local glyph = ui.glyph({
    name = chip.glyph,
    size = math.floor(font_size * 1.25),
    color = display_mode == "icons" and config.accent or nil,
  })

  if display_mode == "icons" then
    return glyph
  end

  return ui.row({ gap = 4, align = "center" }, { glyph, label })
end

local function render()
  local container = barWidget.isVertical() and ui.column or ui.row

  if not ready or sample == nil then
    barWidget.render(ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "activity", size = 14, color = "on_surface_variant" }),
      ui.label({ text = "…", fontSize = font_size, color = "on_surface_variant" }),
    }))
    return
  end

  if sample.ok == false and not hasSysfsData(sample) then
    barWidget.render(ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "alert-triangle", size = 14, color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("widget.sysmon_off"), fontSize = font_size, color = "on_surface_variant" }),
    }))
    return
  end

  local children = {}
  for _, id in ipairs(config.metricOrder) do
    if config.enabled[id] then
      local chip = chips.chip(id, sample, config)
      if chip then
        table.insert(children, chipNode(chip))
      elseif not hide_absent then
        table.insert(children, ui.label({
          text = "–",
          fontSize = font_size,
          color = "on_surface_variant",
        }))
      end
    end
  end

  if #children == 0 then
    children = {
      ui.label({ text = "-", fontSize = font_size, color = "on_surface_variant" }),
    }
  end

  barWidget.render(container({ gap = 8, align = "center" }, children))
  barWidget.setTooltip(chips.tooltipRows(sample, config))
end

noctalia.state.watch("kvitals.sample", function(value)
  sample = value
  render()
end)

noctalia.state.watch("kvitals.config", function(value)
  config = value
  render()
end)

noctalia.state.watch("kvitals.ready", function(value)
  ready = value == true
  render()
end)

function update()
  noctalia.setUpdateInterval(1000)
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  noctalia.openSettings()
end
