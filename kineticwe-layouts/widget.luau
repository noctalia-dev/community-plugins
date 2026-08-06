--!nonstrict
-- Bar indicator for the current KineticWE tiling layout.
-- Purely reactive: the bridge service publishes state changes.

local KIND_INFO = {
  MasterStack = { display = "MasterStack",   glyph = "layout-sidebar-right" },
  Stacked     = { display = "Stacked",        glyph = "layout-rows" },
  CenterTile  = { display = "Center Tile",    glyph = "layout-columns" },
  Monocle     = { display = "Monocle",        glyph = "rectangle" },
  AutoGrid    = { display = "Auto Grid",      glyph = "layout-grid" },
  Columns     = { display = "Columns",        glyph = "columns-3" },
}

local showText = true

local function readShowText()
  local value = noctalia.getConfig("show_text")
  if value == nil then
    value = true
  end
  showText = value
end

readShowText()

local function render(state)
  if state == nil then
    return
  end

  if not state.ok then
    barWidget.setGlyph("alert-triangle")
    barWidget.setText("")
    barWidget.setTooltip("KineticWE layouts: /Tiling DBus interface not found — rebuild KineticWE")
    return
  end

  if state.current == "" then
    barWidget.setGlyph("layout-off")
    barWidget.setText(showText and "Floating" or "")
    barWidget.setTooltip("KineticWE tiling is disabled")
    return
  end

  local info = KIND_INFO[state.current]
  local display = info and info.display or state.current
  barWidget.setGlyph(info and info.glyph or "layout-grid")
  barWidget.setText(showText and display or "")
  barWidget.setTooltip("KineticWE layout: " .. display)
end

noctalia.state.watch("layout", render)
-- Paint the latest value immediately in case the service published first.
render(noctalia.state.get("layout"))

-- Apply the show_text setting without a reload.
function onConfigChanged()
  readShowText()
  render(noctalia.state.get("layout"))
end

function onClick()
  noctalia.togglePanel("theblackdon/kineticwe-layouts:layouts")
end
