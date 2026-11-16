--!nonstrict
-- Bar widget: state of the bridge between the computer and the phone.
--
-- * green : the phone is connected to the server
-- * amber : there are messages queued for the phone
-- * grey  : the phone is not connected
-- * red   : the notes server is not responding

local PANEL_ID = "faminec/notes-plus:panel"

local function tr(key, params)
  if params ~= nil then
    return noctalia.tr(key, params)
  end
  return noctalia.tr(key)
end

local function render()
  local glyph = noctalia.getConfig("glyph") or "device-mobile"
  barWidget.setGlyph(glyph)

  local sync = noctalia.state.get("notes_sync") or {}
  local serverUp = sync.serverUp == true
  local connected = sync.phoneConnected == true
  local pending = tonumber(sync.pending) or 0

  local color = "on_surface_variant"
  if not serverUp then
    color = "error"
  elseif pending > 0 then
    color = "warning"
  elseif connected then
    color = "primary"
  end

  barWidget.setGlyphColor(color)
  if type(barWidget.setColor) == "function" then
    barWidget.setColor(if color == "error" or color == "primary" then color else "")
  end

  local showText = noctalia.getConfig("show_text") == true
  if showText then
    if not serverUp then
      barWidget.setText("!")
    elseif pending > 0 then
      barWidget.setText(tostring(pending))
    elseif connected then
      barWidget.setText("on")
    else
      barWidget.setText("off")
    end
  else
    barWidget.setText("")
  end

  local tip
  if not serverUp then
    tip = tr("tooltip_offline")
  elseif pending > 0 then
    tip = tr("tooltip_pending", { count = pending })
  elseif connected then
    tip = tr("tooltip_online")
  else
    tip = tr("tooltip_disconnected")
  end
  barWidget.setTooltip(tip)
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

-- Redrawn when the state published by the service changes.
noctalia.state.watch("notes_sync", function()
  render()
end)

render()
