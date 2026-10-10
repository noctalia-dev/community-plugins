--!nonstrict

local listenersLib = require("./listeners.luau")
local rates = require("./rates.luau")

-- Keep idle traffic from filling the graph just because its peak is small.
local GRAPH_MIN_PEAK = 10000
local STOP_RESCAN_DELAY_MS = 600
local HOVER_SETTLE_MS = 32

local traffic, listeners, scanError
local isOpen = false
-- Hover transfers from a row to its buttons; render after both events arrive.
local hoverCounts = {}
local hoverElapsed = 0

local function trafficGraph()
  local peak = GRAPH_MIN_PEAK
  for i = 1, #traffic.rxHistory do
    peak = math.max(peak, traffic.rxHistory[i], traffic.txHistory[i])
  end
  local rx, tx = {}, {}
  for i = 1, #traffic.rxHistory do
    rx[i] = traffic.rxHistory[i] / peak
    tx[i] = traffic.txHistory[i] / peak
  end
  return ui.graph({ values = rx, values2 = tx, color = "primary", color2 = "secondary", fillOpacity = 0.15, height = 56 })
end

local function legend(glyph: string, bytesPerSecond: number, color: string)
  return ui.row({ gap = 4, align = "center" }, {
    ui.glyph({ name = glyph, size = 13, color = color }),
    ui.label({ text = rates.full(bytesPerSecond), fontSize = 13, fontFamily = "monospace", color = color }),
  })
end

local function trafficCard()
  return ui.column({ fill = "surface_variant", radius = 12, padding = 14, gap = 8 }, {
    ui.row({ gap = 12, align = "center" }, {
      legend("download-speed", traffic.rx, "primary"),
      legend("upload-speed", traffic.tx, "secondary"),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = noctalia.tr("panel.traffic"), fontSize = 13, color = "on_surface_variant" }),
    }),
    trafficGraph(),
  })
end

local function metaLine(listener): string
  local parts = { string.upper(listener.proto) }
  if listener.pid > 0 then
    table.insert(parts, noctalia.tr("panel.pid", { pid = listener.pid }))
  end
  table.insert(parts, table.concat(listener.addresses, ", "))
  return table.concat(parts, " · ")
end

local function listenerRow(listener)
  local function onHover(state)
    hoverCounts[listener.key] = (hoverCounts[listener.key] or 0) + (if state == "true" then 1 else -1)
    hoverElapsed = 0
    panel.setNeedsFrameTick(true)
  end
  local hovered = (hoverCounts[listener.key] or 0) > 0
  local chipColor = if listener.localOnly then "on_surface_variant" else "tertiary"

  return ui.row({ key = listener.key, fill = "surface", radius = 8 }, {
    ui.row({
      fill = if hovered then "hover/0.08" else "surface/0",
      radius = 8,
      paddingH = 12,
      paddingV = 8,
      gap = 12,
      align = "center",
      flexGrow = 1,
      onHover = onHover,
    }, {
      -- Padded so process names line up whatever the port's digit count.
      ui.label({
        text = string.format("%-5d", listener.port),
        fontSize = 16,
        fontWeight = "bold",
        fontFamily = "monospace",
        color = "primary",
      }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({
          text = if listener.process ~= "" then listener.process else noctalia.tr("panel.unknown_process"),
          color = if listener.process ~= "" then "on_surface" else "on_surface_variant",
          maxLines = 1,
        }),
        ui.label({ text = metaLine(listener), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
      }),
      ui.row({ fill = `{chipColor}/0.12`, radius = 3, paddingH = 6, paddingV = 2, onHover = onHover }, {
        ui.label({
          text = noctalia.tr(if listener.localOnly then "panel.local" else "panel.exposed"),
          fontSize = 11,
          color = chipColor,
        }),
      }),
      ui.row({ gap = 4, align = "center", visible = hovered }, {
        ui.button({
          key = "open",
          glyph = "external-link",
          variant = "ghost",
          width = 24,
          height = 24,
          glyphSize = 14,
          tooltip = noctalia.tr("panel.open_in_browser"),
          visible = listener.proto == "tcp",
          onHover = onHover,
          onClick = function()
            noctalia.runAsync({ "xdg-open", `http://localhost:{listener.port}` })
            panel.close()
          end,
        }),
        ui.button({
          key = "stop",
          glyph = "x",
          variant = "ghost",
          width = 24,
          height = 24,
          glyphSize = 14,
          tooltip = noctalia.tr("panel.stop"),
          onHover = onHover,
          onClick = function()
            noctalia.runAsync(listenersLib.stopCommand(listener), function()
              noctalia.state.set("scan", STOP_RESCAN_DELAY_MS)
            end)
          end,
        }),
      }),
    }),
  })
end

local function portsCard()
  local body
  if #listeners == 0 then
    body = ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
      ui.glyph({ name = "plug-connected-x", size = 48, color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr(if scanError then "panel.scan_error" else "panel.no_ports"), color = "on_surface_variant" }),
    })
  else
    local rows = {}
    for _, listener in listeners do
      table.insert(rows, listenerRow(listener))
    end
    body = ui.scroll({ flexGrow = 1, gap = 4 }, rows)
  end

  return ui.column({ fill = "surface_variant", radius = 12, padding = 14, gap = 8, flexGrow = 1 }, {
    ui.row({ gap = 4, align = "center" }, {
      ui.glyph({ name = "plug-connected", size = 13, color = "primary" }),
      ui.label({ text = noctalia.tr("panel.listening_ports"), fontSize = 13, color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = tostring(#listeners), fontSize = 13, fontFamily = "monospace" }),
    }),
    body,
  })
end

local function render()
  if not isOpen then
    return
  end
  local sections = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "network", size = 20, color = "primary" }),
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.refresh"), onClick = "onRefresh" }),
      ui.button({ glyph = "settings", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.settings"), onClick = "onSettings" }),
      ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.close"), onClick = "onCloseClicked" }),
    }),
  }
  if traffic ~= nil then
    table.insert(sections, trafficCard())
  end
  table.insert(sections, portsCard())
  panel.render(ui.column({ flexGrow = 1, gap = 12 }, sections))
end

function onRefresh()
  noctalia.state.set("scan", 0)
end

function onSettings()
  noctalia.openSettings()
end

function onCloseClicked()
  panel.close()
end

function onOpen()
  isOpen = true
  hoverCounts = {}
  noctalia.state.set("scan", 0)
  render()
end

-- The panel's script outlives its surface; skip renders while it is closed.
function onClose()
  isOpen = false
end

noctalia.state.watch("traffic", function(value)
  traffic = value
  render()
end)

noctalia.state.watch("listeners", function(value)
  listeners = value
  render()
end)

noctalia.state.watch("scan_error", function(value)
  scanError = value
  render()
end)

-- Read after the watches exist so a publish in between still arrives.
traffic = noctalia.state.get("traffic")
listeners = noctalia.state.get("listeners") or {}
scanError = noctalia.state.get("scan_error") == true

function onFrameTick(deltaMs)
  hoverElapsed += tonumber(deltaMs)
  if hoverElapsed >= HOVER_SETTLE_MS then
    panel.setNeedsFrameTick(false)
    render()
  end
end
