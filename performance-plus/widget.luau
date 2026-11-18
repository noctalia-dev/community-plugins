local core = require("./core.luau")

local function render()
  local on = noctalia.state.get("performance") == true
  barWidget.setGlyph(on and "rocket" or "rocket-off")
  barWidget.setGlyphColor(on and "primary" or "on_surface")
  barWidget.setTooltip({
    { key = "Performance Plus", value = on and "Active" or "Disabled" },
    { key = "Left Click", value = "Toggle" },
  })
end
render()

function onClick()
  local current = noctalia.state.get("performance") == true
  local newMode = not current
  noctalia.state.set("performance", newMode)
  core.toggle(newMode)
  render()
end

noctalia.state.watch("performance", function(_val)
  render()
end)
