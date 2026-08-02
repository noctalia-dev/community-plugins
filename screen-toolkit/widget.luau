--!nonstrict
-- Screen Toolkit — bar [[widget]].
--
-- Crosshair glyph; a pulsing red dot appears while a recording is active.
-- Left click toggles the main panel (or stops a recording); right click
-- quick-picks a color. Recording logic lives in the [[service]] — this widget
-- only reflects the published state and drives the service through the
-- "command" state channel.

local recording = false
local phase = 0

local function render()
  local container = barWidget.isVertical() and ui.column or ui.row
  local children = {}
  if recording then
    table.insert(children, ui.box({
      key = "rec-dot",
      width = 7,
      height = 7,
      radius = 4,
      fill = (phase % 2 == 0) and "error" or "error/0.35",
    }))
  end
  table.insert(children, ui.glyph({ name = "crosshair", size = 14 }))
  barWidget.render(container({ gap = 6, align = "center" }, children))
  barWidget.setTooltip(recording and noctalia.tr("widget.recording") or noctalia.tr("widget.tooltip"))
end

-- Pulse the dot: the bar has no frame ticks, so re-render on a half-second cadence.
function update()
  noctalia.setUpdateInterval(500)
  phase += 1
  render()
end

noctalia.state.watch("recording", function(value)
  recording = value == true
  render()
end)

function onClick()
  if recording then
    noctalia.state.set("command", { action = "recordStop" })
  else
    noctalia.togglePanel("alexander/screen-toolkit:panel")
  end
end

function onRightClick()
  -- Quick pick: copies the color and notifies, but never toggles the panel.
  noctalia.state.set("command", { action = "colorPicker", payload = { reopen = false } })
end

render()
