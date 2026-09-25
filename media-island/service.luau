--!nonstrict
-- Poll Noctalia's selected MPRIS player, publish a shared snapshot, and show
-- the floating island briefly when playback starts or the track changes.

local PANEL_ID = "notoxus/media-island:island"
local GET_ACTIVE_PLAYER = {
  "busctl",
  "--user",
  "--json=short",
  "call",
  "dev.noctalia.Mpris",
  "/dev/noctalia/Mpris",
  "dev.noctalia.Mpris",
  "GetActivePlayer",
}

local queryPending = false
local publishedKey = ""
local currentPlayer = nil
local observedPlayer = false
local previousPlaying = false
local previousTrackKey = ""
local panelOpen = false
local panelCloseAtMs = 0

local artworkRequestUrl = ""
local artworkResolvedUrl = ""
local artworkResolvedPath = ""
local artworkGeneration = 0
local artworkRetryUrl = ""
local artworkRetryAtMs = 0

local function nowMs()
  return noctalia.nowMs()
end

local function field(fields, key, fallback)
  local wrapped = fields[key]
  if type(wrapped) == "table" and wrapped.data ~= nil then
    return wrapped.data
  end
  return fallback
end

local function runNoctaliaMessage(...)
  local argv = { "noctalia", "msg" }
  for i = 1, select("#", ...) do
    argv[#argv + 1] = select(i, ...)
  end
  noctalia.runAsync(argv)
end

local function openPanel()
  runNoctaliaMessage("panel-open", PANEL_ID)
end

local function closePanel()
  panelCloseAtMs = 0
  runNoctaliaMessage("panel-close", PANEL_ID)
end

local function previewDurationMs()
  local seconds = tonumber(noctalia.getConfig("preview_seconds")) or 2
  return math.max(1, math.min(10, seconds)) * 1000
end

local function showPreview()
  if noctalia.getConfig("auto_show") == false then
    return
  end
  openPanel()
  panelCloseAtMs = nowMs() + previewDurationMs()
end

local function publish(player)
  local key = "none"
  if type(player) == "table" then
    key = table.concat({
      player.trackKey or "",
      player.title or "",
      player.artist or "",
      player.album or "",
      player.status or "",
      tostring(player.positionUs or 0),
      tostring(player.lengthUs or 0),
      player.artPath or "",
    }, "\31")
  end

  if key == publishedKey then
    return
  end
  publishedKey = key
  noctalia.state.set("player", player)
end

local function resolveArtwork(player, artUrl)
  player.artUrl = artUrl

  if artworkRequestUrl ~= "" and artworkRequestUrl ~= artUrl then
    artworkGeneration += 1
    artworkRequestUrl = ""
  end
  if artworkRetryUrl ~= "" and artworkRetryUrl ~= artUrl then
    artworkRetryUrl = ""
    artworkRetryAtMs = 0
  end

  if artUrl == "" then
    player.artPath = ""
    publish(player)
    return
  end

  if string.sub(artUrl, 1, 7) == "file://" then
    player.artPath = noctalia.string.urlDecode(string.sub(artUrl, 8))
    publish(player)
    return
  end

  if string.sub(artUrl, 1, 7) ~= "http://" and string.sub(artUrl, 1, 8) ~= "https://" then
    player.artPath = ""
    publish(player)
    return
  end

  if artworkResolvedUrl == artUrl
      and artworkResolvedPath ~= ""
      and noctalia.fileExists(artworkResolvedPath) then
    player.artPath = artworkResolvedPath
    publish(player)
    return
  end

  player.artPath = ""
  publish(player)
  if artworkRequestUrl == artUrl then
    return
  end
  if artworkRetryUrl == artUrl and nowMs() < artworkRetryAtMs then
    return
  end

  local dataDir = noctalia.pluginDataDir()
  if dataDir == nil then
    return
  end

  artworkGeneration += 1
  local generation = artworkGeneration
  artworkRequestUrl = artUrl
  local destination = dataDir .. "/artwork-" .. tostring(generation % 2) .. ".img"
  noctalia.download(artUrl, destination, function(success)
    if generation ~= artworkGeneration then
      return
    end
    artworkRequestUrl = ""
    if not success then
      artworkRetryUrl = artUrl
      artworkRetryAtMs = nowMs() + 30000
      return
    end
    if type(currentPlayer) ~= "table" or currentPlayer.artUrl ~= artUrl then
      return
    end
    artworkRetryUrl = ""
    artworkRetryAtMs = 0
    artworkResolvedUrl = artUrl
    artworkResolvedPath = destination
    currentPlayer.artPath = destination
    publish(currentPlayer)
  end)
  if not accepted then
    artworkRequestUrl = ""
    artworkRetryUrl = artUrl
    artworkRetryAtMs = nowMs() + 30000
  end
end

local function clearPlayer()
  currentPlayer = nil
  previousPlaying = false
  previousTrackKey = ""
  observedPlayer = true
  publish(nil)
end

local function handleQuery(result)
  queryPending = false
  if result.exitCode ~= 0 then
    clearPlayer()
    return
  end

  local decoded = noctalia.json.decode(result.stdout)
  if type(decoded) ~= "table" or type(decoded.data) ~= "table" or decoded.data[1] ~= true then
    clearPlayer()
    return
  end

  local fields = decoded.data[2]
  if type(fields) ~= "table" then
    clearPlayer()
    return
  end

  local artists = field(fields, "artists", {})
  local artist = ""
  if type(artists) == "table" then
    artist = table.concat(artists, ", ")
  elseif type(artists) == "string" then
    artist = artists
  end

  local busName = tostring(field(fields, "bus_name", ""))
  local trackId = tostring(field(fields, "track_id", ""))
  local title = tostring(field(fields, "title", ""))
  local album = tostring(field(fields, "album", ""))
  local lengthUs = tonumber(field(fields, "length_us", 0)) or 0
  local status = tostring(field(fields, "playback_status", ""))
  local playing = status == "Playing"
  local trackKey = table.concat({ busName, trackId, title, artist, album, tostring(lengthUs) }, "\31")

  local shouldPreview = observedPlayer
      and playing
      and ((not previousPlaying) or trackKey ~= previousTrackKey)

  local player = {
    busName = busName,
    trackId = trackId,
    trackKey = trackKey,
    title = title,
    artist = artist,
    album = album,
    status = status,
    playing = playing,
    positionUs = tonumber(field(fields, "position_us", 0)) or 0,
    lengthUs = lengthUs,
    canGoPrevious = field(fields, "can_go_previous", true) == true,
    canGoNext = field(fields, "can_go_next", true) == true,
    artPath = "",
  }

  currentPlayer = player
  observedPlayer = true
  previousPlaying = playing
  previousTrackKey = trackKey

  local artUrl = field(fields, "art_url", "")
  resolveArtwork(player, type(artUrl) == "string" and artUrl or "")

  if shouldPreview then
    showPreview()
  end
end

local MEDIA_METHODS = {
  previous = "PreviousActive",
  toggle = "PlayPauseActive",
  next = "NextActive",
}

local function runMediaCommand(action)
  local method = MEDIA_METHODS[action]
  if method == nil then
    return
  end
  noctalia.runAsync({
    "busctl",
    "--user",
    "call",
    "dev.noctalia.Mpris",
    "/dev/noctalia/Mpris",
    "dev.noctalia.Mpris",
    method,
  })
end

local function handleCommand(command)
  if type(command) ~= "table" then
    return
  end
  local action = command.action
  if action == "toggle-panel" then
    panelCloseAtMs = 0
    if panelOpen then
      closePanel()
    else
      openPanel()
    end
  elseif action == "close-panel" then
    closePanel()
  else
    runMediaCommand(action)
  end
end

noctalia.state.watch("panel-open", function(value)
  panelOpen = value == true
  if not panelOpen then
    panelCloseAtMs = 0
  end
end)

noctalia.state.watch("command", handleCommand)

function update()
  noctalia.setUpdateInterval(500)

  if panelCloseAtMs > 0 and nowMs() >= panelCloseAtMs then
    closePanel()
  end

  if queryPending then
    return
  end
  queryPending = noctalia.runAsync(GET_ACTIVE_PLAYER, handleQuery)
end

function onIpc(event)
  if event == "show" then
    panelCloseAtMs = 0
    openPanel()
  elseif event == "hide" then
    closePanel()
  elseif event == "toggle-panel" then
    handleCommand({ action = "toggle-panel" })
  else
    runMediaCommand(event)
  end
end

function onConfigChanged()
  if noctalia.getConfig("auto_show") == false and panelCloseAtMs > 0 then
    closePanel()
  end
end
