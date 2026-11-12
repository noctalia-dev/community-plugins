--!nonstrict
-- Small bar status: bell + next alarm time. Click to open the attached panel.

local PANEL_ID = "spont-427/alarm-clock:panel"
local barText = ""
local ringing = false

local function render()
  local color = ringing and "error" or "on_surface"
  local glyph = "alarm-clock"
  local children = {
    ui.glyph({ name = glyph, color = color, size = 14 }),
  }
  if barText ~= "" then
    table.insert(children, ui.label({ text = barText, color = color, fontWeight = ringing and "bold" or "medium" }))
  end
  barWidget.render(ui.row({ gap = 5, align = "center" }, children))
end

noctalia.state.watch("alarm.barText", function(value)
  barText = type(value) == "string" and value or ""
  render()
end)

noctalia.state.watch("alarm.barRinging", function(value)
  ringing = value == true
  render()
end)

function update()
  local text = noctalia.state.get("alarm.barText")
  local state = noctalia.state.get("alarm.barRinging")
  barText = type(text) == "string" and text or ""
  ringing = state == true
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end
