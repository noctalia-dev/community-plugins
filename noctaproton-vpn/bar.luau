--!nonstrict
-- Proton VPN Bar Widget
-- Displays connection status with dynamic theme coloring.
-- Left-click toggles the attached control panel; Right-click toggles connection.

local PANEL_ID = "riversyx/noctaproton-vpn:panel"
local STATE_KEY = "protonvpn.status"
local COMMAND_KEY = "protonvpn.cmd"

local snapshot = noctalia.state.get(STATE_KEY) or {
  connected = false,
  connecting = false,
  server = "",
  country = "",
  ip = "",
  traffic = { rxRate = 0, txRate = 0 },
}

local function formatSpeed(bps)
  local v = tonumber(bps) or 0
  if v < 1024 then
    return string.format("%d B/s", v)
  elseif v < 1024 * 1024 then
    return string.format("%.1f KB/s", v / 1024)
  else
    return string.format("%.1f MB/s", v / (1024 * 1024))
  end
end

local function render()
  local connected = (snapshot.connected == true)
  local connecting = (snapshot.connecting == true)

  local glyphName = "shield-lock"
  local glyphColor = "on_surface_variant"

  if connected then
    glyphName = "shield-check"
    glyphColor = "primary"
  elseif connecting then
    glyphName = "shield"
    glyphColor = "tertiary"
  end

  local children = {
    ui.glyph({
      name = glyphName,
      color = glyphColor,
      size = 16,
    }),
  }

  if connected then
    local labelText = snapshot.country ~= "" and snapshot.country:upper() or (snapshot.server ~= "" and snapshot.server or "ON")
    table.insert(children, ui.label({
      text = labelText,
      fontSize = 11,
      fontWeight = "bold",
      color = "primary",
    }))
  elseif connecting then
    table.insert(children, ui.label({
      text = "...",
      fontSize = 11,
      color = "tertiary",
    }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 4, align = "center" }, children))

  -- Tooltip with dynamic details
  if connected then
    local rx = formatSpeed(snapshot.traffic and snapshot.traffic.rxRate or 0)
    local tx = formatSpeed(snapshot.traffic and snapshot.traffic.txRate or 0)
    local sName = snapshot.server ~= "" and snapshot.server or "VPN"
    local cName = snapshot.country ~= "" and snapshot.country or ""
    local ipStr = snapshot.ip ~= "" and snapshot.ip or "Protected"
    barWidget.setTooltip(noctalia.tr("widget.tooltip_connected", {
      server = sName,
      country = cName,
      ip = ipStr,
      rxRate = rx,
      txRate = tx,
    }))
  elseif connecting then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_connecting"))
  else
    barWidget.setTooltip(noctalia.tr("widget.tooltip_disconnected"))
  end
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  if snapshot.connected then
    noctalia.state.set(COMMAND_KEY, { op = "disconnect" })
  else
    noctalia.state.set(COMMAND_KEY, { op = "connect", target = "fastest" })
  end
end

render()
