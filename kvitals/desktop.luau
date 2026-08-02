--!nonstrict
-- KVitals desktop tile: the same metric chips as the bar widget, stacked
-- vertically and pinned to the desktop. Reads the plugin state like every
-- other surface.

local format = require("./lib/format.luau")
local chips = require("./lib/chips.luau")

local sample = noctalia.state.get("kvitals.sample")
local config = noctalia.state.get("kvitals.config")
local ready = noctalia.state.get("kvitals.ready") == true

local font_size = noctalia.getConfig("font_size") or 12
local show_glyphs = noctalia.getConfig("show_glyphs")
if show_glyphs == nil then show_glyphs = true end

local function chipColor(chip)
  if chip.tint == "critical" then return config.accent end
  if chip.tint == "active" then return format.withAlpha(config.accent, 0.65) end
  return config.font
end

local function render()
  if not ready or sample == nil or config == nil then
    desktopWidget.render(ui.label({
      text = "…",
      fontSize = font_size,
      color = "on_surface_variant",
    }))
    return
  end

  local children = {}
  for _, id in ipairs(config.metricOrder) do
    if config.enabled[id] then
      local chip = chips.chip(id, sample, config)
      if chip then
        local node
        if show_glyphs then
          node = ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = chip.glyph, size = math.floor(font_size * 1.25) }),
            ui.label({ text = chip.text, fontSize = font_size, fontWeight = "medium", color = chipColor(chip) }),
          })
        else
          node = ui.label({ text = chip.text, fontSize = font_size, fontWeight = "medium", color = chipColor(chip) })
        end
        table.insert(children, node)
      end
    end
  end

  if #children == 0 then
    children = { ui.label({ text = "-", fontSize = font_size, color = "on_surface_variant" }) }
  end

  desktopWidget.render(ui.column({ gap = 8, align = "start" }, children))
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
  render()
end
