--!nonstrict
-- Compact launcher for the floating media island. Playback data is supplied
-- by the singleton media-state service through shared plugin state.

local player = noctalia.state.get("player")
local commandSerial = 0

local function shorten(text, limit)
  text = tostring(text or "")
  local byteIndex = 1
  local characterCount = 0
  while byteIndex <= #text and characterCount < limit do
    local byte = string.byte(text, byteIndex)
    if byte >= 0xF0 then
      byteIndex += 4
    elseif byte >= 0xE0 then
      byteIndex += 3
    elseif byte >= 0xC0 then
      byteIndex += 2
    else
      byteIndex += 1
    end
    characterCount += 1
  end
  if byteIndex > #text then
    return text
  end

  byteIndex = 1
  characterCount = 0
  while byteIndex <= #text and characterCount < limit - 1 do
    local byte = string.byte(text, byteIndex)
    if byte >= 0xF0 then
      byteIndex += 4
    elseif byte >= 0xE0 then
      byteIndex += 3
    elseif byte >= 0xC0 then
      byteIndex += 2
    else
      byteIndex += 1
    end
    characterCount += 1
  end
  return string.sub(text, 1, byteIndex - 1) .. "…"
end

local function render()
  if type(player) ~= "table" then
    barWidget.setGlyph("music")
    barWidget.setText(noctalia.tr("widget.no-media"))
    barWidget.setTooltip(noctalia.tr("widget.open-island"))
    return
  end

  local artPath = tostring(player.artPath or "")
  if artPath ~= "" and noctalia.fileExists(artPath) then
    barWidget.setImage(artPath, true, 18, 18)
  else
    barWidget.setGlyph(player.playing and "player-pause" or "player-play")
  end

  local title = tostring(player.title or "")
  if title == "" then
    title = noctalia.tr("widget.unknown-title")
  end
  barWidget.setText(shorten(title, 36))
  barWidget.setTooltip({
    { key = noctalia.tr("tooltip.title"), value = title },
    { key = noctalia.tr("tooltip.artist"), value = tostring(player.artist or "") },
    {
      key = noctalia.tr("tooltip.playback"),
      value = player.playing and noctalia.tr("tooltip.playing") or noctalia.tr("tooltip.paused"),
    },
  })
end

local function request(action)
  commandSerial += 1
  noctalia.state.set("command", {
    action = action,
    nonce = tostring(noctalia.nowMs()) .. ":" .. tostring(commandSerial),
  })
end

noctalia.state.watch("player", function(value)
  player = value
  render()
end)

function onClick()
  request("toggle-panel")
end

function update()
  noctalia.setUpdateInterval(1000)
  render()
end

render()
