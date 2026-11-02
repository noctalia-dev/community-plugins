local showGlyph = noctalia.getConfig("show_glyph")
local customLabels = noctalia.getConfig("custom_labels") or {}
local vertical = barWidget.isVertical()

local function render(submap)
  submap = submap or "reset"
  local label = customLabels[submap] or submap

  if vertical then
    barWidget.render(ui.column({ align = "center" }, {
      ui.label({ text = label }),
    }))
  else
    local children = {}
    if showGlyph then
      table.insert(children, ui.glyph({ name = "keyboard" }))
    end
    table.insert(children, ui.label({ text = label }))
    barWidget.render(ui.row({ gap = 6, align = "center" }, children))
  end
end

noctalia.state.watch("umbriel_submap", function(value)
  render(value and value.current)
end)

local initial = noctalia.state.get("umbriel_submap")
render(initial and initial.current)
