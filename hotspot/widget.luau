--!nonstrict

local PANEL_ID = "cleboost/hotspot:panel"
local COMMAND_KEY = "hotspot_command"

local status = noctalia.state.get("hotspot_status") or {
  active = false,
  busy = false,
  available = true,
  clients = {},
  clientCount = 0,
}

local glyph = noctalia.getConfig("glyph") or "router"

local function sendCommand(action)
  noctalia.state.set(COMMAND_KEY, { action = action })
end

local function render()
  if status.available == false then
    barWidget.setGlyph("wifi-off")
    barWidget.setGlyphColor("error")
    barWidget.setTooltip(status.error ~= "" and status.error or noctalia.tr("tooltip.unavailable"))
  elseif status.busy == true then
    barWidget.setGlyph("loader-2")
    barWidget.setGlyphColor("primary")
    barWidget.setTooltip(noctalia.tr("tooltip.changing"))
  elseif status.active == true then
    barWidget.setGlyph(glyph)
    barWidget.setGlyphColor("tertiary")
    local count = status.clientCount or #(status.clients or {})
    barWidget.setText(count > 0 and tostring(count) or "")
    barWidget.setTooltip(noctalia.tr("tooltip.active", {
      ssid = status.ssid or "?",
      count = tostring(count),
    }))
  else
    barWidget.setGlyph(glyph)
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setText("")
    barWidget.setTooltip(noctalia.tr("tooltip.inactive"))
  end
end

noctalia.state.watch("hotspot_status", function(value)
  if type(value) == "table" then
    status = value
    render()
  end
end)

render()

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  if status.available == false then
    noctalia.notifyError(noctalia.tr("title"), status.error or noctalia.tr("error.missing_dependencies"))
    return
  end
  if status.busy == true then return end
  sendCommand("toggle")
end

function onMiddleClick()
  sendCommand("refresh")
end

function onConfigChanged()
  glyph = noctalia.getConfig("glyph") or "router"
  render()
end
