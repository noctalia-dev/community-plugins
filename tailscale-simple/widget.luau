--!nonstrict

local PANEL_ID = "alivault/tailscale-simple:manager"
local STATE_KEY = "ts_snapshot"
local COMMAND_KEY = "ts_command"

-- Semantic colors follow the shell palette, just like built-in glyphs.
local COLOR_CONNECTED = "on_surface"
local COLOR_DISCONNECTED = "on_surface_variant"

local snapshot = noctalia.state.get(STATE_KEY) or {
  available = false,
  running = false,
  onlineCount = 0,
  peerCount = 0,
  backendState = "",
  exitNode = "",
  error = "",
  installed = false,
}

local requestId = 0

local function render()
  local available = snapshot.available == true
  local running = snapshot.running == true
  local online = tonumber(snapshot.onlineCount) or 0
  local total = tonumber(snapshot.peerCount) or 0
  local showCounts = noctalia.getConfig("show_counts") == true
  local exitNode = tostring(snapshot.exitNode or "")
  local hasExit = exitNode ~= ""

  local color = running and COLOR_CONNECTED or COLOR_DISCONNECTED
  local rows = {}
  for row = 1, 3 do
    local dots = {}
    for col = 1, 3 do
      local solid = row == 2 or (row == 3 and col == 2)
      table.insert(dots, ui.box({ width = 3, height = 3, radius = 1.5,
        fill = solid and color or (color .. "/0.3") }))
    end
    table.insert(rows, ui.row({ width = 13, height = 3, gap = 2 }, dots))
  end
  local children = { ui.column({ width = 14, height = 14, align = "center", justify = "center" }, {
    ui.column({ width = 13, height = 13, gap = 2 }, rows),
  }) }

  if showCounts and available then
    table.insert(children, ui.label({
      text = `{online}/{total}`,
      fontWeight = "bold",
      color = "on_surface",
    }))
    if hasExit then
      table.insert(children, ui.glyph({
        name = "world",
        size = 12,
        color = (snapshot.exitNodeOnline and COLOR_CONNECTED) or COLOR_DISCONNECTED,
      }))
    end
    table.insert(children, ui.box({
      width = 7,
      height = 7,
      radius = 4,
      fill = color,
    }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))

  if not snapshot.installed then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_missing"))
  elseif not available then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_down", {
      error = tostring(snapshot.error or "unknown"),
    }))
  elseif not running then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_stopped", { total = total }))
  else
    barWidget.setTooltip(noctalia.tr("widget.tooltip_ok", {
      state = tostring(snapshot.backendState or "Running"),
      online = online,
      total = total,
      exit = hasExit and exitNode or "—",
    }))
  end
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

noctalia.setUpdateInterval(8000)
render()

function update()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  requestId += 1
  noctalia.state.set(COMMAND_KEY, { action = "refresh", requestId = `widget-{requestId}` })
  noctalia.notify(noctalia.tr("title"), noctalia.tr("widget.refresh_requested"))
end
