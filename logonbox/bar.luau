--!nonstrict
-- LogonBox bar widget: a thin client. The service owns all state and
-- model.barView decides what to show; this only maps it onto barWidget calls.

local model = require("./model.luau")

local snapshot = nil

local function render()
  -- barView treats only `false` as hidden, so an unset setting keeps the label.
  local view = model.barView(snapshot, noctalia.getConfig("show_label"))
  barWidget.setGlyph(view.glyph)
  barWidget.setColor(view.labelColor)
  barWidget.setGlyphColor(view.color)
  barWidget.setText(view.label)
  barWidget.setTooltip(view.tooltip)
end

-- Re-applies the view each tick; this is how a show_label change takes effect.
function update()
  render()
end

function onClick()
  noctalia.togglePanel("3dprogramin/logonbox:panel")
end

noctalia.state.watch("logonbox.state", function(value)
  snapshot = value
  render()
end)

render()

-- state.watch does not replay an old value, so ask the service for a snapshot.
noctalia.state.set("logonbox.request", { action = "refresh" })
