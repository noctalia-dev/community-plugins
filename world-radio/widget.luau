-- widget.luau
-- Bar widget: opens the World Radio panel; while a radio is playing it shows
-- the station name ("tocando agora"), published through the plugin state channel.

local currentName = ""
local currentFlag = ""
local showName = noctalia.getConfig("show_now_playing") ~= false

local function displayText()
  if currentName == "" then
    return ""
  end
  if currentFlag ~= "" then
    return currentFlag .. " " .. currentName
  end
  return currentName
end

function render()
  barWidget.setGlyph(noctalia.getConfig("glyph") or "radio")
  barWidget.setText(showName and displayText() or "")
  if currentName ~= "" then
    barWidget.setTooltip(noctalia.tr("widget.playing_tooltip", { name = currentName }))
  else
    barWidget.setTooltip(noctalia.tr("widget.tooltip"))
  end
end

noctalia.state.watch("playing", function(value)
  local name = ""
  local flag = ""
  if value ~= nil and type(value.name) == "string" then
    name = value.name
  end
  if value ~= nil and type(value.flag) == "string" then
    flag = value.flag
  end
  if name ~= currentName or flag ~= currentFlag then
    currentName = name
    currentFlag = flag
    render()
  end
end)

local initial = noctalia.state.get("playing")
if initial ~= nil and type(initial.name) == "string" then
  currentName = initial.name
end
if initial ~= nil and type(initial.flag) == "string" then
  currentFlag = initial.flag
end

function onClick()
  noctalia.togglePanel("nilsonlinux/world-radio:Panel")
end

function onConfigChanged()
  showName = noctalia.getConfig("show_now_playing") ~= false
  render()
end

render()