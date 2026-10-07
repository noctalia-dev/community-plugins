--!nonstrict
-- Bar widget: note count, click opens the panel.

local count = 0
local showCount = noctalia.getConfig("show_count") ~= false

local function render()
  barWidget.setGlyph("note")
  if showCount and not barWidget.isVertical() then
    barWidget.setText(tostring(count))
  else
    barWidget.setText("")
  end
  barWidget.setTooltip(noctalia.trp("bar.tooltip", count))
end

-- Every edit republishes the list; only a note added or deleted changes what
-- the bar shows.
noctalia.state.watch("noctes.notes", function(value)
  local next = type(value) == "table" and #value or 0
  if next == count then
    return
  end
  count = next
  render()
end)

function onClick()
  noctalia.togglePanel("remo/noctes:panel")
end

local initial = noctalia.state.get("noctes.notes")
if type(initial) == "table" then
  count = #initial
end
render()
