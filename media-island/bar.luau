--!nonstrict
-- Compact launcher for the floating media island. Playback data is supplied
-- by the singleton media-state service through shared plugin state.

local player = noctalia.state.get("player")
local commandSerial = 0

local function request(action)
  commandSerial += 1
  noctalia.state.set("command", {
    action = action,
    nonce = tostring(noctalia.nowMs()) .. ":" .. tostring(commandSerial),
  })
end

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
  local artPath = type(player) == "table" and tostring(player.artPath or "") or ""
  local hasArtwork = artPath ~= "" and noctalia.fileExists(artPath)
  local title = type(player) == "table" and tostring(player.title or "") or ""
  if type(player) ~= "table" or not player.playing or not hasArtwork or title == "" then
    barWidget.render(ui.label({ text = "" }))
    barWidget.setTooltip("")
    return
  end

  local limit = tonumber(noctalia.getConfig("title_limit")) or 30
  local shortTitle = shorten(title, limit)

  local cd_image = ui.image({
    path = artPath,
    width = 20,
    height = 20,
    radius = 10,
    fit = "cover",
  })
  local title_label = ui.button({
    text = shortTitle,
    variant = "ghost",
    controlSize = "sm",
    tooltip = noctalia.tr("widget.open-island"),
    onClick = function() onTitleClick() end,
  })
  local children = {}
  children[#children + 1] = cd_image
  children[#children + 1] = title_label
  barWidget.render(ui.row({ gap = 6, align = "center" }, children))
  -- Tooltip
  barWidget.setTooltip({
    { key = noctalia.tr("tooltip.title"), value = title },
    { key = noctalia.tr("tooltip.artist"), value = tostring(player.artist or "") }
  })
end

function onTitleClick()
  local action = noctalia.getConfig("click_action") or "island"
  if action == "panel" then
    noctalia.runAsync({"noctalia", "msg", "panel-toggle", "control-center", "media"})
  else
    request("preview-panel")
  end
end

function onAudioSpectrum(valuesCsv, stateCsv)
  local active = type(player) == "table" and player.playing
    and noctalia.getConfig("audio_visualizer") ~= false
    and string.sub(stateCsv or "", 1, 1) == "1"
  local values = {}
  if active then
    for value in string.gmatch(valuesCsv or "", "[^,]+") do
      values[#values + 1] = math.max(0, math.min(1, tonumber(value) or 0))
    end
  end
  noctalia.state.set("audio-spectrum", { active = active and #values > 0, values = values })
end

noctalia.state.watch("player", function(value)
  player = value
  render()
end)

function update()
  noctalia.setUpdateInterval(1000)
  render()
end

render()
