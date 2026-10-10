--!nonstrict

local rates = require("./rates.luau")

local ACTIVE_BYTES_PER_SECOND = 1024
local TOOLTIP_PORTS = 8

local showSpeed = noctalia.getConfig("show_speed")
local showPorts = noctalia.getConfig("show_ports")
local traffic, listeners

local function rate(container, glyph: string, bytesPerSecond: number, vertical: boolean)
  local text = rates.compact(bytesPerSecond)
  return container({ gap = 2, align = "center" }, {
    ui.glyph({
      name = glyph,
      color = if bytesPerSecond > ACTIVE_BYTES_PER_SECOND then "primary" else "on_surface_variant",
    }),
    -- Padded monospace text keeps the pill from changing width as the rate ticks.
    ui.label({ text = if vertical then text else string.format("%-4s", text), fontFamily = "monospace" }),
  })
end

local function renderTooltip()
  local rows = { noctalia.tr("tooltip.speed", { rx = rates.full(traffic.rx), tx = rates.full(traffic.tx) }) }
  for i = 1, math.min(#listeners, TOOLTIP_PORTS) do
    table.insert(rows, `:{listeners[i].port}  {if listeners[i].process ~= "" then listeners[i].process else noctalia.tr("panel.unknown_process")}`)
  end
  if #listeners > TOOLTIP_PORTS then
    table.insert(rows, noctalia.tr("tooltip.more", { count = #listeners - TOOLTIP_PORTS }))
  end
  barWidget.setTooltip(table.concat(rows, "\n"))
end

local function render()
  local vertical = barWidget.isVertical()
  local container = if vertical then ui.column else ui.row
  local portsShown = showPorts and #listeners > 0

  local parts = {}
  if showSpeed then
    table.insert(parts, rate(container, "arrow-down", traffic.rx, vertical))
    table.insert(parts, rate(container, "arrow-up", traffic.tx, vertical))
  end
  -- A bare plug keeps the pill clickable when nothing else is shown.
  if portsShown or not showSpeed then
    table.insert(parts, container({ gap = 4, align = "center" }, {
      ui.glyph({ name = "plug-connected" }),
      ui.label({ text = tostring(#listeners), fontFamily = "monospace", visible = portsShown }),
    }))
  end

  barWidget.render(container({ gap = 6, align = "center" }, parts))
  renderTooltip()
end

noctalia.state.watch("traffic", function(value)
  traffic = value
  render()
end)

noctalia.state.watch("listeners", function(value)
  listeners = value
  render()
end)

function onClick()
  noctalia.togglePanel("mahmoudomiesh/network-monitor:panel")
end

function onRightClick()
  noctalia.togglePanel("mahmoudomiesh/network-monitor:menu")
end

function onMiddleClick()
  noctalia.state.set("scan", 0)
end

-- Read after the watches exist so a publish in between still arrives.
traffic = noctalia.state.get("traffic") or { rx = 0, tx = 0 }
listeners = noctalia.state.get("listeners") or {}
render()
