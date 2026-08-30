--!nonstrict
-- Bar widget: a single glyph that opens the panel, with the connection count
-- in its tooltip.

local shared = require("./shared.luau")

local PANEL_ID = "rylos/remmina:connections"

local function refreshTooltip()
  local profiles = shared.profiles(noctalia.getConfig("profiles_path"))
  if profiles == nil then
    barWidget.setTooltip(noctalia.tr("profiles-missing"))
    return
  end
  barWidget.setTooltip(noctalia.tr("panel.count", { count = #profiles }))
end

barWidget.setGlyph("device-desktop")
refreshTooltip()

function onClick()
  -- The count is cheap to recheck (it only re-reads the folder when its mtime
  -- changed) and this is the moment the user is looking at the widget.
  refreshTooltip()
  noctalia.togglePanel(PANEL_ID)
end
