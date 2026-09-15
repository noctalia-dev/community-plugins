-- widget.luau
-- Bar widget: opens the World Radio panel; while a radio is playing it shows
-- the station name ("tocando agora"), published through the plugin state channel.

local currentName = ""
local showName = noctalia.getConfig("show_now_playing") ~= false

function render()
  barWidget.setGlyph(noctalia.getConfig("glyph") or "radio")
  barWidget.setText(showName and currentName or "")
  if currentName ~= "" then
    barWidget.setTooltip(noctalia.tr("widget.playing_tooltip", { name = currentName }))
  else
    barWidget.setTooltip(noctalia.tr("widget.tooltip"))
  end
end

noctalia.state.watch("playing", function(value)
  local name = ""
  if value ~= nil and type(value.name) == "string" then
    name = value.name
  end
  if name ~= currentName then
    currentName = name
    render()
  end
end)

local initial = noctalia.state.get("playing")
if initial ~= nil and type(initial.name) == "string" then
  currentName = initial.name
end

function onClick()
  noctalia.togglePanel("nilsonlinux/world-radio:Panel")
end

function onConfigChanged()
  showName = noctalia.getConfig("show_now_playing") ~= false
  render()
end

render()