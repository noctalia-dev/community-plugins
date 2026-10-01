--!nonstrict
-- Control-center tile: toggles the media-lyrics panel (size preset from the
-- panel_size setting: compact / medium / large / pinned).
local function panelIdForSize()
  local sz = noctalia.getConfig("panel_size")
  if sz == "mini" then return "panel-mini" end
  if sz == "compact" then return "panel-compact" end
  if sz == "large" then return "panel-large" end
  if sz == "pinned" then return "panel-pinned" end
  return "panel"
end

function onClick()
  noctalia.togglePanel("tranzem/media-lyrics:" .. panelIdForSize())
end
