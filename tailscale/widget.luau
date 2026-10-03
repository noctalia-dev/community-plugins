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

  -- Two independent, opt-in settings (both default false — behaviour is
  -- unchanged unless a widget instance turns one on):
  --   hide_when_healthy — collapse to nothing while running.
  --   flag_problem      — error-tinted status dot while not running,
  --                       instead of the neutral grey one.
  -- They compose: a permanently-visible widget can still flag a problem,
  -- and a hidden-while-healthy widget stays reachable via the /ts
  -- launcher provider whenever it matters.
  local hideWhenHealthy = noctalia.getConfig("hide_when_healthy") == true
  local flagProblem = noctalia.getConfig("flag_problem") == true

  if hideWhenHealthy then
    if running then
      barWidget.setVisible(false)
      return
    end
    barWidget.setVisible(true)
  end

  -- Connected = green logo, stopped = grey logo (never red) — except
  -- with flag_problem on, where the one non-connected state earns the
  -- error colour, since that setting exists to make a permanently-
  -- visible widget read as an alert.
  local isProblem = flagProblem and not running
  local color = running and COLOR_CONNECTED or COLOR_DISCONNECTED

  local children = {
    ui.image({
      path = running and ICON_ON or ICON_OFF,
      width = 16,
      height = 16,
      fit = "contain",
    }),
  }

  if isProblem and not (showCounts and available) then
    -- Restrained problem indicator when there is nothing else to show:
    -- brand mark plus an error-tinted dot, no counts/exit-node detail —
    -- that stays in the manager panel this widget opens on click.
    table.insert(children, ui.box({
      width = 7,
      height = 7,
      radius = 4,
      fill = "error",
    }))
  elseif showCounts and available then
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
      fill = isProblem and "error" or color,
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
