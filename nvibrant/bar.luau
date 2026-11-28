--!nonstrict
-- Bar button: left click opens the panel, right click toggles saturation on/off. The icon is lit only while a
-- saturation is actually applied.
local core = require("./core.luau")

local function render()
  barWidget.render(ui.glyph({ name = "contrast", color = core.appliedOn() and "primary" or "on_surface" }))
end

noctalia.state.watch("applied", function() render() end)

function update()
  noctalia.setUpdateInterval(1500)
  render()
end

function onClick()
  noctalia.togglePanel("nofiltera1/nvibrant:panel")
end

function onRightClick()
  core.toggle(function() render() end)
end
