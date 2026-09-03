--!nonstrict
-- Connection controls and live tunnel statistics.

local status = {
  state = "checking",
  available = false,
  busy = false,
  message = "",
  mode = "",
  protocol = "",
  endpoint = "",
  colo = "",
  latencyMs = nil,
  loss = nil,
  bytesSent = nil,
  bytesReceived = nil,
  handshakeSecs = nil,
  tlsVersion = "",
  tlsCurve = "",
  postQuantum = false,
  alwaysOn = false,
  switchLocked = false,
  splitTunnelMode = "",
  splitTunnelCount = 0,
  statsAvailable = false,
}

local MODE_IDS = { "warp", "doh", "warp+doh", "dot", "warp+dot", "proxy", "tunnel_only" }

local function modeOptions()
  return {
    "WARP",
    "DoH",
    "WARP + DoH",
    "DoT",
    "WARP + DoT",
    "SOCKS5 proxy",
    "Tunnel only",
  }
end

local function modeDescription()
  local descriptions = {
    warp = "panel.mode_warp_description",
    doh = "panel.mode_doh_description",
    ["warp+doh"] = "panel.mode_warp_doh_description",
    dot = "panel.mode_dot_description",
    ["warp+dot"] = "panel.mode_warp_dot_description",
    proxy = "panel.mode_proxy_description",
    tunnel_only = "panel.mode_tunnel_only_description",
  }
  return noctalia.tr(descriptions[status.mode] or "panel.mode-description")
end

local function modeIndex()
  for index, id in ipairs(MODE_IDS) do
    if id == status.mode then
      return index - 1
    end
  end
  return 0
end

local function send(action, mode)
  noctalia.state.set("warp.command", { action = action, mode = mode })
end

local function stateLabel(state)
  local known = {
    checking = true,
    connected = true,
    connecting = true,
    disconnecting = true,
    disconnected = true,
    unavailable = true,
    error = true,
  }
  return noctalia.tr(if known[state] then `status.{state}` else "status.error")
end

local function valueOrDash(value)
  if value == nil or value == "" then
    return "—"
  end
  return tostring(value)
end

local function formatBytes(value)
  local bytes = tonumber(value)
  if bytes == nil then
    return "—"
  end

  local units = { "B", "KiB", "MiB", "GiB", "TiB" }
  local index = 1
  while bytes >= 1024 and index < #units do
    bytes /= 1024
    index += 1
  end
  local decimals = if index == 1 or bytes >= 10 then 0 else 1
  return string.format(`%.{decimals}f %s`, bytes, units[index])
end

local function formatLatency(value)
  local latency = tonumber(value)
  return if latency == nil then "—" else string.format("%.0f ms", latency)
end

local function formatLoss(value)
  local loss = tonumber(value)
  return if loss == nil then "—" else string.format("%.2f%%", loss * 100)
end

local function formatDuration(value)
  local seconds = tonumber(value)
  if seconds == nil then
    return "—"
  elseif seconds < 60 then
    return string.format("%.0f s", seconds)
  end
  return string.format("%dm %02ds", math.floor(seconds / 60), math.floor(seconds % 60))
end

local function statRow(label, value, color)
  return ui.row({ gap = 8, justify = "space_between", align = "center" }, {
    ui.label({ text = label, color = "on_surface_variant", fontSize = 12 }),
    ui.label({ text = valueOrDash(value), color = color or "on_surface", fontSize = 12, fontWeight = "bold", textAlign = "right", maxWidth = 240 }),
  })
end

local function section(title, rows)
  local children = {
    ui.label({ text = title, color = "primary", fontSize = 12, fontWeight = "bold" }),
  }
  for _, row in ipairs(rows) do
    table.insert(children, row)
  end
  return ui.column({ gap = 7, padding = 10, fill = "surface_variant/0.35", radius = 8 }, children)
end

local function render()
  local connected = status.state == "connected" or status.state == "connecting"
  local stateColor = if status.state == "connected" then "primary"
    elseif status.state == "error" or status.state == "unavailable" then "error"
    else "on_surface_variant"
  local splitTunnel = if status.splitTunnelMode == "" then "—"
    else `{status.splitTunnelMode} · {status.splitTunnelCount}`
  local pq = if not status.statsAvailable then "—"
    elseif status.postQuantum then noctalia.tr("panel.enabled")
    else noctalia.tr("panel.disabled")

  local details = {
    section(noctalia.tr("panel.connection"), {
      ui.column({ gap = 4 }, {
        ui.row({ gap = 8, justify = "space_between", align = "center" }, {
          ui.label({ text = noctalia.tr("panel.mode"), color = "on_surface_variant", fontSize = 12 }),
          ui.select({
            options = modeOptions(),
            selectedIndex = modeIndex(),
            enabled = status.available and not status.busy and not status.switchLocked,
            onChange = "onModeChanged",
            width = 220,
          }),
        }),
        ui.label({ text = modeDescription(), color = "on_surface_variant", fontSize = 11, maxLines = 2 }),
      }),
      statRow(noctalia.tr("panel.protocol"), status.protocol),
      statRow(noctalia.tr("panel.endpoint"), status.endpoint),
      statRow(noctalia.tr("panel.edge"), status.colo),
      statRow(noctalia.tr("panel.latency"), formatLatency(status.latencyMs)),
      statRow(noctalia.tr("panel.loss"), formatLoss(status.loss)),
    }),
    section(noctalia.tr("panel.traffic"), {
      statRow(noctalia.tr("panel.received"), formatBytes(status.bytesReceived)),
      statRow(noctalia.tr("panel.sent"), formatBytes(status.bytesSent)),
      statRow(noctalia.tr("panel.handshake"), formatDuration(status.handshakeSecs)),
    }),
    section(noctalia.tr("panel.security"), {
      statRow(noctalia.tr("panel.tls"), status.tlsVersion),
      statRow(noctalia.tr("panel.key-exchange"), status.tlsCurve),
      statRow(noctalia.tr("panel.post-quantum"), pq, if status.postQuantum then "primary" else "on_surface_variant"),
    }),
    section(noctalia.tr("panel.policy"), {
      statRow(noctalia.tr("panel.always-on"), if status.alwaysOn then noctalia.tr("panel.enabled") else noctalia.tr("panel.disabled")),
      statRow(noctalia.tr("panel.split-tunnel"), splitTunnel),
    }),
  }

  panel.render(ui.column({ gap = 10, padding = 12, flexGrow = 1 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "cloud-lock", size = 20, color = stateColor }),
      ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", tooltip = noctalia.tr("panel.refresh"), onClick = "onRefresh" }),
      ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
    }),
    ui.column({ gap = 8, padding = 12, fill = "surface_variant/0.5", radius = 10 }, {
      ui.row({ justify = "space_between", align = "center" }, {
        ui.column({ gap = 2 }, {
          ui.label({ text = stateLabel(status.state), color = stateColor, fontSize = 15, fontWeight = "bold" }),
          ui.label({ text = status.message, color = "error", fontSize = 11, maxLines = 2, maxWidth = 300 }),
        }),
        ui.toggle({ checked = connected, enabled = status.available and not status.busy, onChange = "onToggle" }),
      }),
    }),
    ui.scroll({ flexGrow = 1, gap = 8 }, details),
  }))
end

local function applyStatus(value)
  if type(value) == "table" then
    status.state = value.state or "checking"
    status.available = value.available == true
    status.busy = value.busy == true
    status.message = value.message or ""
    status.mode = value.mode or ""
    status.protocol = value.protocol or ""
    status.endpoint = value.endpoint or ""
    status.colo = value.colo or ""
    status.latencyMs = value.latencyMs
    status.loss = value.loss
    status.bytesSent = value.bytesSent
    status.bytesReceived = value.bytesReceived
    status.handshakeSecs = value.handshakeSecs
    status.tlsVersion = value.tlsVersion or ""
    status.tlsCurve = value.tlsCurve or ""
    status.postQuantum = value.postQuantum == true
    status.alwaysOn = value.alwaysOn == true
    status.switchLocked = value.switchLocked == true
    status.splitTunnelMode = value.splitTunnelMode or ""
    status.splitTunnelCount = value.splitTunnelCount or 0
    status.statsAvailable = value.statsAvailable == true
  end
  render()
end

function onOpen(_context)
  applyStatus(noctalia.state.get("warp.status"))
  send("refresh")
end

function onToggle(_value)
  if status.available and not status.busy then
    send("toggle")
  end
end

function onModeChanged(index, _label)
  local selected = MODE_IDS[(tonumber(index) or 0) + 1]
  if selected ~= nil and not status.busy and not status.switchLocked then
    send("set-mode", selected)
  end
end

function onRefresh()
  send("refresh")
end

function onCloseClicked()
  panel.close()
end

applyStatus(noctalia.state.get("warp.status"))
noctalia.state.watch("warp.status", applyStatus)
