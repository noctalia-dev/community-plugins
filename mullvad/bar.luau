--!nonstrict
-- Mullvad bar widget: a thin client. The service owns all state and
-- model.barView decides what to show; this only maps it onto barWidget calls.

local model = require("./model.luau")

local snapshot = nil

local function render()
  -- `== false` so an unset setting keeps the label (default is true).
  local view = model.barView(snapshot, noctalia.getConfig("show_label"), noctalia.getConfig("show_flags") ~= false)
  barWidget.setGlyph(view.glyph)
  barWidget.setColor(view.color)
  barWidget.setText(view.label)
  barWidget.setTooltip(view.tooltip)
end

-- Re-applies the view each tick; this is how a show_label change takes effect.
function update()
  render()
end

function onClick()
  noctalia.togglePanel("3dprogramin/mullvad:panel")
end

noctalia.state.watch("mullvad.state", function(value)
  snapshot = value
  render()
end)

render()

-- state.watch does not replay an old value, so ask the service for a snapshot.
noctalia.state.set("mullvad.request", { action = "refresh" })
