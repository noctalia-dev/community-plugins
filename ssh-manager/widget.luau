--!nonstrict

local PANEL_ID = "davemhammer/ssh-manager:manager"
local STATE_KEY = "ssh_snapshot"
local COMMAND_KEY = "ssh_command"

local snapshot = noctalia.state.get(STATE_KEY) or {
  available = false,
  hostCount = 0,
  keyCount = 0,
  agentKeys = 0,
}

local requestId = 0

local function render()
  local hosts = tonumber(snapshot.hostCount) or 0
  local keys = tonumber(snapshot.keyCount) or 0
  local agent = tonumber(snapshot.agentKeys) or 0
  local available = snapshot.available == true
  local showCounts = noctalia.getConfig("show_counts") ~= false

  local children = {
    ui.glyph({
      name = "terminal-2",
      size = 16,
      color = available and "on_surface" or "on_surface_variant",
    }),
  }

  if showCounts and available then
    table.insert(children, ui.label({
      text = `{hosts}`,
      fontWeight = "bold",
      color = "on_surface",
    }))
    if agent > 0 then
      table.insert(children, ui.box({
        width = 7,
        height = 7,
        radius = 4,
        fill = "tertiary",
      }))
    end
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))

  if not available then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_missing"))
  else
    barWidget.setTooltip(noctalia.tr("widget.tooltip", {
      hosts = hosts,
      agent = agent,
      keys = keys,
    }))
  end
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

noctalia.setUpdateInterval(5000)
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
