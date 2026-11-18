--!nonstrict

local PANEL_ID = "8bury/mini-docker:manager"
local snapshot = noctalia.state.get("docker_snapshot") or {
  available = false,
  loading = true,
  runningCount = 0,
}
local requestId = 0

local function configString(key, fallback)
  local value = noctalia.getConfig(key)
  return type(value) == "string" and value or fallback
end

local function render()
  local runningCount = tonumber(snapshot.runningCount) or 0
  local available = snapshot.available == true
  local showCount = noctalia.getConfig("show_count") ~= false
  local statusMode = configString("status_mode", "always")
  local activeColor = configString("active_color", "tertiary")
  local inactiveColor = configString("inactive_color", "error")
  local showStatus = available
    and statusMode ~= "hidden"
    and (statusMode ~= "running_only" or runningCount > 0)

  local children = {
    ui.glyph({
      name = "brand-docker",
      size = 16,
      color = available and configString("glyph_color", "on_surface") or "on_surface_variant",
    }),
  }
  if showCount and available then
    table.insert(children, ui.label({
      text = tostring(runningCount),
      fontWeight = "bold",
      color = "on_surface",
    }))
  end
  if showStatus then
    table.insert(children, ui.box({
      width = 7,
      height = 7,
      radius = 4,
      fill = runningCount > 0 and activeColor or inactiveColor,
    }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))
  barWidget.setTooltip(if available
    then noctalia.tr("widget.running", { count = runningCount })
    else noctalia.tr("widget.unavailable"))
end

noctalia.state.watch("docker_snapshot", function(value)
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
  if snapshot.available == true then
    noctalia.togglePanel(PANEL_ID)
  else
    noctalia.notifyError(noctalia.tr("title"), snapshot.error or noctalia.tr("widget.unavailable"))
  end
end

function onRightClick()
  requestId += 1
  noctalia.state.set("docker_command", { action = "refresh", requestId = `widget-{requestId}` })
  noctalia.notify(noctalia.tr("title"), noctalia.tr("widget.refresh_requested"))
end
