local title = "Spotify"
local artist = ""
local status = "Stopped"
local artUrl = ""
local artPath = nil
local playerAvailable = false

local requestInFlight = false
local coverRevision = 0

local scrollOffset = 1
local scrollTick = 0
local lastDisplayText = ""

local SCROLL_WIDTH = 16
local SCROLL_SPEED_TICKS = 2
local METADATA_TICKS = 4

local dataDir = noctalia.pluginDataDir()
local spotifyIcon = noctalia.appIconPath("spotify", 18)

local SEP = string.char(31)


local function utf8Chars(value)
  local chars = {}

  for _, codepoint in utf8.codes(value) do
    table.insert(chars, utf8.char(codepoint))
  end

  return chars
end

local function charWidth(char)
  local cp = utf8.codepoint(char)

  if cp == nil then
    return 1
  end

  -- Common CJK / Japanese / Korean ranges.
  if
    (cp >= 0x1100 and cp <= 0x11FF) or
    (cp >= 0x2E80 and cp <= 0xA4CF) or
    (cp >= 0xAC00 and cp <= 0xD7A3) or
    (cp >= 0xF900 and cp <= 0xFAFF) or
    (cp >= 0xFE10 and cp <= 0xFE6F) or
    (cp >= 0xFF00 and cp <= 0xFFEF)
  then
    return 2
  end

  return 1
end

local function scrollingText(value)
  local chars = utf8Chars(value)
  local length = #chars

  -- Ensure short titles still have enough empty space
  -- before wrapping back around.
  
  local extraSpaces = math.max(3, SCROLL_WIDTH - length + 3)
  local padded = value .. string.rep(" ", extraSpaces)

  local sequence = utf8Chars(padded)
  local sequenceLength = #sequence

  local output = {}

  local usedWidth = 0
  local i = 0

  while usedWidth < SCROLL_WIDTH do
    local index = ((scrollOffset + i - 1) % sequenceLength) + 1
    local char = sequence[index]
    local width = charWidth(char)

    if usedWidth + width > SCROLL_WIDTH then
      break
    end

    table.insert(output, char)
    usedWidth = usedWidth + width
    i = i + 1
  end

  return table.concat(output)
end


local function stripNewline(value)
  if value == nil then
    return ""
  end

  return value:gsub("[\r\n]+", " ")
end


local function runPlayerctl(command)
  noctalia.runAsync({
    "playerctl",
    "--player=spotify",
    command,
  })
end


function previousTrack()
  runPlayerctl("previous")
end


function togglePlayback()
  runPlayerctl("play-pause")
end


function nextTrack()
  runPlayerctl("next")
end


function openSpotify()
  noctalia.runAsync({
    "hyprctl",
    "clients",
    "-j",
  }, function(result)
    local clients = result.stdout or ""
    local spotifyClass = nil

    if string.find(clients, '"class"%s*:%s*"spotify"') then
      spotifyClass = "spotify"
    elseif string.find(clients, '"class"%s*:%s*"Spotify"') then
      spotifyClass = "Spotify"
    end

    if spotifyClass ~= nil then
      noctalia.runAsync({
        "hyprctl",
        "dispatch",
        'hl.dsp.focus({ window = "class:^' .. spotifyClass .. '$" })',
      })
    else
      noctalia.runAsync({ "spotify-launcher" })
    end
  end)
end


local function render()
  local playing = status == "Playing"
  local container = barWidget.isVertical() and ui.column or ui.row

  -- Spotify not running: collapse to icon only
  if not playerAvailable then
    local icon

    if spotifyIcon ~= nil then
      icon = ui.image({
        key = "spotify-icon",
        path = spotifyIcon,
        width = 18,
        height = 18,
        fit = "contain",
      })
    else
      icon = ui.glyph({
        name = "brand-spotify",
        size = 16,
        color = "primary",
      })
    end

    barWidget.render(container({
      align = "center",
      onClick = "openSpotify",
    }, {
      icon,
    }))

    return
  end

  local displayText = title

  if artist ~= "" then
    displayText = artist .. " - " .. title
  end

  
  local imagePath = artPath

  if imagePath == nil or imagePath == "" then
    imagePath = spotifyIcon
  end

  barWidget.render(container({
    gap = 0,
    align = "center"
  }, {
    -- Artwork + song info
    ui.row({
      key = "track-info",
      gap = 0,
      align = "center",
    }, {
      ui.image({
        key = "cover",
        path = imagePath,
        width = 20,
        height = 20,
        radius = 4,
        fit = "cover",
        onClick = "openSpotify",
      }),

      ui.button({
        key = "track",
        text = scrollingText(displayText),
        variant = "ghost",
        contentAlign = "start",
        height = 22,
        width = 136,
        tooltip = displayText,
        onClick = "openSpotify",
      }),
    }),

    ui.button({
      key = "previous",
      glyph = "caret-left-filled",
      glyphSize = 16,
      align = "center",
      variant = "ghost",
      width = 22,
      height = 22,
      tooltip = "Previous",
      onClick = "previousTrack",
    }),

    ui.button({
      key = "playpause",
      glyph = playing and "player-pause-filled" or "player-play-filled",
      glyphSize = 14,
      align = "center",
      variant = "ghost",
      width = 22,
      height = 22,
      tooltip = playing and "Pause" or "Play",
      onClick = "togglePlayback",
    }),

    ui.button({
      key = "next",
      glyph = "caret-right-filled",
      glyphSize = 16,
      align = "center",
      variant = "ghost",
      width = 22,
      height = 22,
      tooltip = "Next",
      onClick = "nextTrack",
    }),
  }))
end

local function updateArtwork(newUrl)
  if newUrl == nil or newUrl == "" then
    artUrl = ""
    artPath = nil
    render()
    return
  end

  if newUrl == artUrl then
    return
  end

  artUrl = newUrl

  if string.sub(newUrl, 1, 7) == "file://" then
    artPath = noctalia.string.urlDecode(string.sub(newUrl, 8))
    render()
    return
  end

  if not string.match(newUrl, "^https?://") then
    artPath = nil
    render()
    return
  end

  if dataDir == nil then
    return
  end

  coverRevision = coverRevision + 1

  local revision = coverRevision
  local destination =
    dataDir .. "/cover-" .. tostring(revision % 2) .. ".jpg"

  noctalia.download(newUrl, destination, function(ok)
    if not ok then
      return
    end

    if revision ~= coverRevision then
      return
    end

    artPath = destination
    render()
  end)
end


local function refreshMetadata()
  if requestInFlight then
    return
  end

  requestInFlight = true

  local format =
    "{{status}}" .. SEP ..
    "{{title}}" .. SEP ..
    "{{artist}}" .. SEP ..
    "{{mpris:artUrl}}"

  noctalia.runAsync({
    "playerctl",
    "--player=spotify",
    "metadata",
    "--format",
    format,
  }, function(result)
    requestInFlight = false

    if result.exitCode ~= 0 then
      playerAvailable = false
      title = "Spotify"
      artist = ""
      status = "Stopped"
      artUrl = ""
      artPath = nil
      render()
      return
    end

    playerAvailable = true

    local output = stripNewline(result.stdout)

    local newStatus, newTitle, newArtist, newArtUrl =
      string.match(
        output,
        "^(.-)" .. SEP ..
        "(.-)" .. SEP ..
        "(.-)" .. SEP ..
        "(.*)$"
      )

    if newStatus == nil then
      return
    end

    status = newStatus
    title = newTitle ~= "" and newTitle or "Spotify"
    artist = newArtist or ""

    render()
    updateArtwork(newArtUrl or "")
  end)
end


function update()
  noctalia.setUpdateInterval(250)

  scrollTick = scrollTick + 1

  local displayText = title

  if artist ~= "" then
    displayText = artist .. " - " .. title
  end

  if displayText ~= lastDisplayText then
    lastDisplayText = displayText
    scrollOffset = 1
    scrollTick = 0
    render()
  elseif scrollTick % SCROLL_SPEED_TICKS == 0 then
    scrollOffset = scrollOffset + 1
    render()
  end

  if scrollTick % METADATA_TICKS == 0 then
    refreshMetadata()
  end
end


render()
refreshMetadata()
