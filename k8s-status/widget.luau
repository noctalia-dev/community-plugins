--!nonstrict

local PANEL_ID = "davemhammer/k8s-status:manager"
local STATE_KEY = "k8s_snapshot"
local COMMAND_KEY = "k8s_command"

local snapshot = noctalia.state.get(STATE_KEY) or {
  available = false,
  readyNodes = 0,
  nodeCount = 0,
  problemPods = 0,
  context = "",
  error = "",
}

local requestId = 0

local function configString(key, fallback)
  local value = noctalia.getConfig(key)
  return type(value) == "string" and value or fallback
end

local function render()
  local available = snapshot.available == true
  local ready = tonumber(snapshot.readyNodes) or 0
  local nodes = tonumber(snapshot.nodeCount) or 0
  local problems = tonumber(snapshot.problemPods) or 0
  local healthy = available and ready == nodes and nodes > 0 and problems == 0
  local showCounts = noctalia.getConfig("show_counts") ~= false
  local okColor = configString("ok_color", "tertiary")
  local warnColor = configString("warn_color", "error")
  local color = available and (healthy and okColor or warnColor) or "on_surface_variant"

  local children = {
    ui.glyph({
      name = "hexagon",
      size = 16,
      color = color,
    }),
  }

  if showCounts and available then
    table.insert(children, ui.label({
      text = `{ready}/{nodes}`,
      fontWeight = "bold",
      color = "on_surface",
    }))
    if problems > 0 then
      table.insert(children, ui.label({
        text = tostring(problems),
        fontWeight = "bold",
        color = warnColor,
      }))
    end
    table.insert(children, ui.box({
      width = 7,
      height = 7,
      radius = 4,
      fill = healthy and okColor or warnColor,
    }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))

  if not available then
    local err = tostring(snapshot.error or "")
    if err:find("kubectl", 1, true) then
      barWidget.setTooltip(noctalia.tr("widget.tooltip_missing"))
    else
      barWidget.setTooltip(noctalia.tr("widget.tooltip_down", {
        error = err ~= "" and err or "unknown",
      }))
    end
  else
    barWidget.setTooltip(noctalia.tr("widget.tooltip_ok", {
      context = snapshot.context ~= "" and snapshot.context or "default",
      ready = ready,
      nodes = nodes,
      problems = problems,
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
