--!nonstrict
-- Control-center tile: toggles the media-lyrics panel (size preset from the
-- panel_size setting: compact / medium / large).
local function panelIdForSize()
  local sz = noctalia.getConfig("panel_size")
  if sz == "compact" then return "panel-compact" end
  if sz == "large" then return "panel-large" end
  return "panel"
end

function onClick()
  noctalia.togglePanel("tranzem/media-lyrics:" .. panelIdForSize())
end
