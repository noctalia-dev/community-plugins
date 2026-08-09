--!nonstrict

local PANEL_ID = "davemhammer/tailscale:manager"
local STATE_KEY = "ts_snapshot"
local COMMAND_KEY = "ts_command"

-- Brand mark (Simple Icons Tailscale 3×3 dots), tinted for connection state.
local COLOR_CONNECTED = "#73c936"
local COLOR_DISCONNECTED = "on_surface_variant"
local ICON_ON = "assets/tailscale-green.png"
local ICON_OFF = "assets/tailscale-grey.png"

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
  local showCounts = noctalia.getConfig("show_counts") ~= false
  local exitNode = tostring(snapshot.exitNode or "")
  local hasExit = exitNode ~= ""

  -- Connected = green logo, stopped = grey logo (never red).
  local color = running and COLOR_CONNECTED or COLOR_DISCONNECTED

  local children = {
    ui.image({
      path = running and ICON_ON or ICON_OFF,
      width = 16,
      height = 16,
      fit = "contain",
    }),
  }

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
