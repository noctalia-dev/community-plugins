--!nonstrict
-- WiFi Enterprise bar widget: shield glyph that reflects whether a configured
-- 802.1X profile is currently active, click opens the panel.

local profiles = {}

local function activeName()
  for _, row in ipairs(profiles) do
    if row.active then
      return row.name
    end
  end
  return nil
end

local function render()
  local name = activeName()
  barWidget.setGlyph(name ~= nil and "shield-lock-filled" or "shield-lock")
  barWidget.setColor(name ~= nil and "primary" or "on_surface_variant")
  if name ~= nil then
    barWidget.setTooltip(noctalia.tr("tooltip.connected", { name = name }))
  else
    barWidget.setTooltip(noctalia.tr("tooltip.disconnected"))
  end
end

noctalia.state.watch("eapwifi.profiles", function(value)
  profiles = type(value) == "table" and value or {}
  render()
end)

function onClick()
  noctalia.togglePanel("andrewdems/wifi-enterprise:panel")
end

render()
