--!nonstrict
-- Bar widget entry for Command Runner plugin

local PANEL_ID = "nocode-96/cmd-runner:panel"
local state = noctalia.state.get("cmd_runner_state") or { runningMap = {} }

local function isAnyRunning()
  if type(state) == "table" and type(state.runningMap) == "table" then
    for _, running in pairs(state.runningMap) do
      if running == true then return true end
    end
  end
  return false
end

local function render()
  local running = isAnyRunning()
  local showLabel = noctalia.getConfig("show_label") ~= false

  local children = {
    ui.glyph({
      name = running and "player-play" or "terminal",
      size = 16,
      color = running and "primary" or "on_surface",
    }),
  }

  if showLabel or running then
    table.insert(children, ui.label({
      text = running and noctalia.tr("panel.running") or noctalia.tr("widget.label"),
      fontWeight = "bold",
      color = running and "primary" or "on_surface",
    }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, children))
  barWidget.setTooltip(noctalia.tr("widget.tooltip"))
end

noctalia.state.watch("cmd_runner_state", function(val)
  if type(val) == "table" then
    state = val
    render()
  end
end)

render()

function update()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  noctalia.togglePanel(PANEL_ID)
end
