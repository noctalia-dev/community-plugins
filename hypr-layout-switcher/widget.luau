--!nonstrict

local glyphs = {
  dwindle   = "layout-grid",
  master    = "layout-sidebar",
  monocle   = "square",
  scrolling = "arrows-horizontal",
}

local current = noctalia.state.get("layout") or "dwindle"

local function render()
  barWidget.setGlyph(glyphs[current] or "layout-grid")
  barWidget.setText(current:sub(1, 1):upper() .. current:sub(2))
end

noctalia.state.watch("layout", function(value)
  if value then
    current = value
    render()
  end
end)

function onClick()
  noctalia.runAsync("noctalia msg plugin maddingo/hypr-layout-switcher:poller all cycle")
end

render()

