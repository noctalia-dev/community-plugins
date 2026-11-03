--!nonstrict

local function render(on)
  barWidget.setVisible(on)
  if on then
    barWidget.setGlyph("click")
    barWidget.setGlyphColor("primary")
    barWidget.setTooltip("Auto Clicker running (click to stop)")
  end
end

render(noctalia.state.get("running") == true)

noctalia.state.watch("running", function(value)
  render(value == true)
end)

-- Visible only while running, so a click always means "stop".
function onClick()
  noctalia.state.set("stop_request", noctalia.nowMs())
end
