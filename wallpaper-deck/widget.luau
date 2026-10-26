--!nonstrict
-- Bar widget for Wallpaper Deck

local PANEL_ID = "ishan0121/wallpaper-deck:picker"

local function render()
  local glyph = noctalia.getConfig("glyph")
  if not glyph or glyph == "" then
    glyph = "cards"
  end
  barWidget.setGlyph(glyph)
  barWidget.setTooltip("Wallpaper Deck")
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onIpc(event: string, _payload: any)
  if event == "toggle" or event == "click" then
    onClick()
  end
end

render()
