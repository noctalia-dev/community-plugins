--!nonstrict
-- Resurrect bar widget: a lifebuoy, accent while saving, red when the last save failed.
-- Renders "resurrect.model" from service.luau; a click opens the panel.

local PANEL = "omerfuyar/resurrect:panel"

local model = nil

local function render()
  if model == nil then
    return
  end
  -- color nil keeps the bar's own color.
  local color = nil
  local tooltip
  if not model.ready then
    color, tooltip = "error", noctalia.tr("widget.no_git")
  elseif model.running then
    color, tooltip = "primary", noctalia.tr("widget.saving")
  elseif model.error then
    color, tooltip = "error", noctalia.tr("widget.failed", { error = model.error })
  elseif model.lastMs then
    tooltip = noctalia.tr("widget.saved", { time = noctalia.formatTime("%Y-%m-%d %H:%M", math.floor(model.lastMs / 1000)) })
  else
    tooltip = noctalia.tr("widget.never")
  end
  barWidget.render(ui.glyph({ name = "lifebuoy", color = color }))
  barWidget.setTooltip(tooltip)
end

noctalia.state.watch("resurrect.model", function(value)
  model = value
  render()
end)

function update()
  noctalia.setUpdateInterval(60000)
  model = model or noctalia.state.get("resurrect.model")
  render()
end

function onClick()
  noctalia.togglePanel(PANEL)
end
