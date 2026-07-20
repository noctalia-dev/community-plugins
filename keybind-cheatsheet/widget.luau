--!nonstrict
-- Static, event-only bar entry. Parsing belongs to the panel and only happens
-- while the user is interacting with it.

local PANEL_ID = "kenn/keybind-cheatsheet:cheatsheet"

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
    local generation = tonumber(noctalia.state.get("refresh_generation")) or 0
    noctalia.state.set("refresh_generation", generation + 1)
  end
end

render()
