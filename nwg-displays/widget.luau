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

-- Applies publish on the state channel, and the panel republishes what it reads
-- when it opens, so a click refreshes the name without any polling. A profile
-- applied outside Noctalia shows up the next time the panel is opened.
noctalia.state.watch("active_profile", function()
  refresh()
end)

refresh()

function onClick()
  noctalia.togglePanel("micahg/nwg-displays:panel")
end
