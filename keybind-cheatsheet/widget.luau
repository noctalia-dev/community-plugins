--!nonstrict
-- Static, event-only bar entry. Parsing and cache ownership belong to the data
-- service; this widget only toggles the panel or requests a refresh.

local PANEL_ID = "kenn/keybind-cheatsheet:cheatsheet"
local REFRESH_REQUEST_KEY = "keybind-cheatsheet.refresh-request"

local function render()
  barWidget.setGlyph(noctalia.getConfig("glyph") or "keyboard")
  barWidget.setTooltip(noctalia.tr("widget_tooltip"))
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onIpc(event, _payload)
  if event == "toggle" then
    noctalia.togglePanel(PANEL_ID)
  elseif event == "refresh" then
    local generation = tonumber(noctalia.state.get(REFRESH_REQUEST_KEY)) or 0
    noctalia.state.set(REFRESH_REQUEST_KEY, generation + 1)
  end
end

render()
