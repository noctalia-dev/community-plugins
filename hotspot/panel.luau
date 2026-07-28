--!nonstrict

local opened = false
local render

local status = noctalia.state.get("hotspot_status") or {
  active = false,
  busy = false,
  available = true,
  clients = {},
  clientCount = 0,
  error = "",
}

local function sendCommand(action)
  noctalia.state.set("hotspot_command", { action = action })
end

local function phaseDetails()
  if status.busy == true then
    if status.active == true then
      return noctalia.tr("panel.status.stopping_title"), noctalia.tr("panel.status.stopping_message"), "on_surface_variant", "loader-2"
    end
    return noctalia.tr("panel.status.starting_title"), noctalia.tr("panel.status.starting_message"), "on_surface_variant", "loader-2"
  end

  if status.active == true then
    return noctalia.tr("panel.status.active_title"), noctalia.tr("panel.status.active_message", {
      ssid = status.ssid or "?",
      interface = status.interface or "?",
    }), "tertiary", "router"
  end

  if status.available == false then
    local message = status.error
    if message == nil or message == "" then
      message = noctalia.tr("error.missing_dependencies")
    end
    return noctalia.tr("panel.status.error_title"), message, "error", "alert-circle"
  end

  return noctalia.tr("panel.status.inactive_title"), noctalia.tr("panel.status.inactive_message"), "on_surface_variant", "wifi-off"
end

local function clientRow(client)
  local subtitle = client.mac
  if client.ip ~= nil and client.ip ~= "" then
    subtitle = client.ip .. "  ·  " .. client.mac
  end

  local trailing = nil
  if client.signal ~= nil then
    trailing = ui.label({
      text = tostring(client.signal) .. " dBm",
      fontSize = 11,
      color = "on_surface_variant",
    })
  end

  return ui.row({
    align = "center",
    gap = 10,
    paddingH = 14,
    paddingV = 10,
    fill = "surface_variant/0.35",
    radius = 10,
  }, {
    ui.glyph({ name = "device-mobile", size = 18, color = "primary" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = client.ip ~= "" and client.ip or client.mac, fontWeight = "medium", maxLines = 1 }),
      ui.label({ text = subtitle, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    trailing,
  })
end

render = function()
  local busy = status.busy == true
  local active = status.active == true
  local canToggle = status.available ~= false and not busy
  local stateTitle, stateMessage, stateColor, stateGlyph = phaseDetails()

  local actionText = noctalia.tr("panel.action.start")
  local actionGlyph = "player-play"
  local actionVariant = "primary"

  if active then
    actionText = noctalia.tr("panel.action.stop")
    actionGlyph = "player-stop"
    actionVariant = "destructive"
  elseif busy then
    actionText = active and noctalia.tr("panel.action.stopping") or noctalia.tr("panel.action.starting")
    actionGlyph = "loader-2"
  end

  local children = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ align = "center", gap = 9, flexGrow = 1 }, {
        ui.glyph({ name = "router", size = 18, color = "primary" }),
        ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold" }),
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        tooltip = noctalia.tr("panel.refresh"),
        enabled = not busy,
        onClick = "onRefresh",
      }),
      ui.button({
        glyph = "close",
        variant = "ghost",
        tooltip = noctalia.tr("panel.close"),
        onClick = "onCloseClicked",
      }),
    }),
    ui.row({
      align = "center",
      gap = 10,
      fill = "surface_variant/0.45",
      radius = 10,
      padding = 12,
    }, {
      ui.glyph({ name = stateGlyph, size = 18, color = stateColor }),
      ui.column({ gap = 3, flexGrow = 1 }, {
        ui.label({ text = stateTitle, fontWeight = "medium", color = stateColor }),
        ui.label({ text = stateMessage, color = "on_surface_variant", maxLines = 3 }),
      }),
    }),
  }

  if status.gateway ~= nil and status.gateway ~= "" then
    table.insert(children, ui.label({
      text = noctalia.tr("panel.gateway", { address = status.gateway }),
      fontSize = 11,
      color = "on_surface_variant",
    }))
  end

  table.insert(children, ui.button({
    text = actionText,
    glyph = actionGlyph,
    variant = actionVariant,
    controlSize = "lg",
    enabled = canToggle,
    onClick = "onToggle",
  }))

  table.insert(children, ui.row({ align = "center", justify = "space_between" }, {
    ui.label({
      text = noctalia.tr("panel.clients_title"),
      fontWeight = "medium",
      color = "on_surface_variant",
    }),
    ui.label({
      text = tostring(status.clientCount or #(status.clients or {})),
      fontSize = 11,
      color = "on_surface_variant",
    }),
  }))

  local clients = status.clients or {}
  if #clients == 0 then
    table.insert(children, ui.label({
      text = active and noctalia.tr("panel.no_clients") or noctalia.tr("panel.clients_inactive"),
      color = "on_surface_variant",
      maxLines = 2,
      padding = 12,
    }))
  else
    local listChildren = {}
    for _, client in ipairs(clients) do
      table.insert(listChildren, clientRow(client))
    end
    table.insert(children, ui.scroll({ flexGrow = 1, gap = 8 }, listChildren))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, children))
end

noctalia.state.watch("hotspot_status", function(value)
  if type(value) ~= "table" then return end
  status = value
  if opened then render() end
end)

function onOpen(_context)
  opened = true
  status = noctalia.state.get("hotspot_status") or status
  sendCommand("refresh")
  render()
end

function onClose()
  opened = false
end

function onCloseClicked()
  panel.close()
end

function onToggle()
  if status.busy == true or status.available == false then return end
  sendCommand("toggle")
end

function onRefresh()
  sendCommand("refresh")
end
