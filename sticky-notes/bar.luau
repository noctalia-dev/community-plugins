--!nonstrict
-- Sticky Notes bar widget — shows the note icon and optional note count.
-- Click opens the panel.

local notes = {}
local blurred = false

local function render()
  barWidget.setGlyph("note")
  local showCount = noctalia.getConfig("show_count")
  if showCount == nil then showCount = true end

  if not blurred and showCount and #notes > 0 then
    barWidget.setText(tostring(#notes))
  else
    barWidget.setText("")
  end
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("ahmedhossamdev/sticky-notes:panel")
end

noctalia.state.watch("sticky_notes.notes", function(value)
  notes = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("sticky_notes.blurred", function(value)
  blurred = value == true
  render()
end)

render()
