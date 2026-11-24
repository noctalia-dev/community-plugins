--!nonstrict
-- Bar button: left click opens the panel, right click toggles saturation on/off.
local core = require("./core.luau")

local function render()
  local state = core.load()
  barWidget.render(ui.glyph({ name = "contrast", color = state.enabled and "primary" or "on_surface" }))
end

function update()
  noctalia.setUpdateInterval(1500)
  render()
end

function onClick()
  noctalia.togglePanel("nofiltera1/nvibrant:panel")
end

function onRightClick()
  core.toggle()
  render()
end
