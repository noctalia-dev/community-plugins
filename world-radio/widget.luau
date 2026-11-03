-- widget.luau
-- Bar widget: opens the World Radio panel; while a radio is playing it shows
-- the station name ("tocando agora"), published through the plugin state channel.
-- Scrolling up/down asks the background service to skip to the next/previous
-- station through MPRIS, so switching works with the panel closed.

local currentName = ""
local currentFlag = ""
local lastSkipId = 0
local showName = noctalia.getConfig("show_now_playing") == true

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

local function requestSkip(dir)
  local request = noctalia.state.get("skip_request")
  local id = lastSkipId
  if type(request) == "table" then
    local current = tonumber(request.id)
    if current ~= nil and current > id then
      id = current
    end
  end
  id = id + 1
  lastSkipId = id
  noctalia.state.set("skip_request", { id = id, dir = dir })
end

function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" or not startsGesture then
    return
  end
  local count = tonumber(steps) or 0
  if count == 0 or currentName == "" then
    return
  end
  -- Negative steps scroll up (next station), positive scroll down (previous).
  requestSkip(count < 0 and 1 or -1)
end

function onConfigChanged()
  showName = noctalia.getConfig("show_now_playing") == true
  render()
end

render()