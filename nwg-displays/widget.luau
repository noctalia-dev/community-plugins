--!nonstrict
-- Bar widget: active nwg-displays profile; clicking opens the panel.

local nwg = require("./lib/nwg.luau")

local tr = noctalia.tr

local function refresh()
  local active = nwg.readActiveProfile()
  barWidget.setGlyph("device-desktop")
  if active ~= nil then
    barWidget.setText(active)
    barWidget.setTooltip({ { key = tr("widget.tooltip_active"), value = active } })
  else
    barWidget.setText("")
    barWidget.setTooltip(tr("widget.tooltip_none"))
  end
end

-- Applies publish on the state channel; the poll in update() catches profiles
-- applied outside Noctalia.
noctalia.state.watch("active_profile", function()
  refresh()
end)

function update()
  noctalia.setUpdateInterval(5000)
  refresh()
end

function onClick()
  noctalia.togglePanel("micahg/nwg-displays:panel")
end
