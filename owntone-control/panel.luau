--!nonstrict
-- OwnTone Control — panel.luau
-- Displays now-playing artwork, track details, playback controls, master volume,
-- and multi-room audio output (speaker) selectors and volume sliders.

local STATUS_KEY = "owntone.status"

local status = noctalia.state.get(STATUS_KEY)
local draftVolume = nil
local draftOutputVolumes = {}
local currentArtworkPath = nil
local lastArtworkUrl = nil
local localProgressMs = 0
local lastProgressSyncMs = 0

-- Library browsing state
local view = "player" -- "player" | "library"
local libraryStack = {} -- breadcrumb frames: { screen, id, name, uri }
local libraryItems = nil
local libraryLoading = false
local libraryRequestId = 0

-- Library search state (screen == "search")
local searchQuery = ""
local searchResults = nil
local searchLoading = false
local searchRequestId = 0

local function baseUrl()
  local host = noctalia.getConfig("host") or "127.0.0.1:3689"
  return "http://" .. host
end

local function authedRequest(req)
  local user = noctalia.getConfig("username") or ""
  if user ~= "" then
    req.basic_username = user
    req.basic_password = noctalia.getConfig("password") or ""
  end
  return req
end

local function put(path, body)
  local headers = {}
  local req = authedRequest({
    url = baseUrl() .. path,
    method = "PUT",
    headers = headers
  })
  if body ~= nil then
    table.insert(headers, "Content-Type: application/json")
    req.body = noctalia.json.encode(body)
  end
  noctalia.http(req, function(_res)
    noctalia.state.set("owntone.refresh", noctalia.nowMs())
  end)
end

local function refresh()
  noctalia.state.set("owntone.refresh", noctalia.nowMs())
end

local function getJson(path, cb)
  local req = authedRequest({
    url = baseUrl() .. path,
    headers = { "Accept: application/json" }
  })
  noctalia.http(req, function(res)
    if res == nil or res.ok ~= true or res.body == nil or res.body == "" then
      cb(nil)
      return
    end
    local ok, decoded = pcall(noctalia.json.decode, res.body)
    cb(ok and decoded or nil)
  end)
end

-- Adds a track/album/artist/playlist (by its OwnTone `uri`) to the queue.
-- clear = replace the queue first, play = start playback immediately.
local function queueAction(uri, clear, play)
  local q = "?uris=" .. noctalia.string.urlEncode(uri)
  if clear then
    q = q .. "&clear=true"
  end
  if play then
    q = q .. "&playback=start"
  end
  local req = authedRequest({
    url = baseUrl() .. "/api/queue/items/add" .. q,
    method = "POST",
    headers = {}
  })
  noctalia.http(req, function(_res)
    noctalia.state.set("owntone.refresh", noctalia.nowMs())
  end)
end

local function libraryTop()
  return libraryStack[#libraryStack]
end

-- Fetches the items for the current top of libraryStack (or shows the root
-- menu when the stack is empty). Guards against stale responses when the
-- user navigates again before a previous request has returned.
local function loadLibrary()
  local top = libraryTop()
  if top == nil then
    libraryItems = nil
    libraryLoading = false
    render()
    return
  end

  libraryRequestId = libraryRequestId + 1
  local requestId = libraryRequestId
  libraryLoading = true
  libraryItems = nil
  render()

  local path = nil
  if top.screen == "artists" then
    path = "/api/library/artists?limit=200"
  elseif top.screen == "albums" then
    path = "/api/library/albums?media_kind=music&limit=500"
  elseif top.screen == "genres" then
    path = "/api/search?type=genres&limit=300&expression=" .. noctalia.string.urlEncode("media_kind is music")
  elseif top.screen == "genre_albums" then
    path = "/api/search?type=albums&limit=500&expression="
      .. noctalia.string.urlEncode('genre is "' .. tostring(top.name or "") .. '" and media_kind is music')
  elseif top.screen == "radio" then
    -- Radio stations are OwnTone tracks with data_kind "url" and no known length,
    -- exactly the query the official OwnTone web client uses for its Radio tab.
    path = "/api/search?type=tracks&media_kind=music&limit=200&expression="
      .. noctalia.string.urlEncode("data_kind is url and song_length = 0")
  elseif top.screen == "artist_albums" then
    path = "/api/library/artists/" .. tostring(top.id) .. "/albums?limit=200"
  elseif top.screen == "album_tracks" then
    path = "/api/library/albums/" .. tostring(top.id) .. "/tracks?limit=500"
  elseif top.screen == "playlists" then
    path = "/api/library/playlists?limit=200"
  elseif top.screen == "playlist_tracks" then
    path = "/api/library/playlists/" .. tostring(top.id) .. "/tracks?limit=500"
  end

  if path == nil then
    libraryLoading = false
    render()
    return
  end

  getJson(path, function(data)
    if requestId ~= libraryRequestId then
      return -- a newer navigation happened, discard this stale response
    end
    libraryLoading = false
    if data == nil then
      libraryItems = nil
    elseif top.screen == "genres" then
      libraryItems = (data.genres and data.genres.items) or {}
    elseif top.screen == "genre_albums" then
      libraryItems = (data.albums and data.albums.items) or {}
    elseif top.screen == "radio" then
      libraryItems = (data.tracks and data.tracks.items) or {}
    elseif top.screen == "playlists" then
      -- Single-station m3u files show up as ordinary "playlists" (item_count 1,
      -- stream_count 1). Those are exactly the entries the Radio screen now
      -- shows properly, so hide them here to avoid listing radio twice under
      -- a confusing "playlist" label.
      local filtered = {}
      for _, pl in ipairs(data.items or {}) do
        if (pl.stream_count or 0) == 0 then
          table.insert(filtered, pl)
        end
      end
      libraryItems = filtered
    elseif data.items ~= nil then
      libraryItems = data.items
    elseif type(data) == "table" then
      libraryItems = data
    else
      libraryItems = nil
    end
    render()
  end)
end

local function libraryPush(screen, id, name, uri)
  table.insert(libraryStack, { screen = screen, id = id, name = name, uri = uri })
  loadLibrary()
end

local function libraryPop()
  table.remove(libraryStack)
  loadLibrary()
end

local function openLibrary()
  view = "library"
  render()
end

local function closeLibrary()
  view = "player"
  render()
end

local function libraryRow(label, onOpen, onQuickAction, quickGlyph, quickTooltip)
  return ui.row({ gap = 4, align = "center" }, {
    ui.button({
      text = label,
      variant = "ghost",
      controlSize = "md",
      flexGrow = 1,
      onClick = onOpen
    }),
    ui.button({
      glyph = quickGlyph,
      variant = "ghost",
      controlSize = "sm",
      tooltip = quickTooltip,
      onClick = onQuickAction
    })
  })
end

-- A row with a single action (navigate, or play), used where there is no
-- separate "quick action" (genres, radio stations, search results).
local function libraryNavRow(label, glyph, onClick)
  return ui.button({
    glyph = glyph,
    text = label,
    variant = "ghost",
    controlSize = "md",
    onClick = onClick
  })
end

local function performSearch()
  local q = (searchQuery or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if q == "" then
    searchResults = nil
    render()
    return
  end

  searchRequestId = searchRequestId + 1
  local requestId = searchRequestId
  searchLoading = true
  render()

  local path = "/api/search?type=artist,album&media_kind=music&limit=40&query=" .. noctalia.string.urlEncode(q)
  getJson(path, function(data)
    if requestId ~= searchRequestId then
      return
    end
    searchLoading = false
    if data == nil then
      searchResults = nil
    else
      searchResults = {
        artists = (data.artists and data.artists.items) or {},
        albums = (data.albums and data.albums.items) or {}
      }
    end
    render()
  end)
end

local function searchScreenContent()
  local children = {
    ui.row({ gap = 4, align = "center" }, {
      ui.input({
        key = "library-search",
        value = searchQuery,
        placeholder = noctalia.tr("panel.search_placeholder"),
        controlSize = "sm",
        flexGrow = 1,
        focus = true,
        onChange = function(v) searchQuery = v end,
        onSubmit = performSearch
      }),
      ui.button({
        glyph = "search",
        variant = "secondary",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.search"),
        onClick = performSearch
      })
    })
  }

  if searchLoading then
    table.insert(children, ui.row({ align = "center", justify = "center", flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("panel.loading"), fontSize = 12, color = "on_surface_variant" })
    }))
    return children
  end

  if searchResults == nil then
    table.insert(children, ui.row({ align = "center", justify = "center", flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("panel.search_hint"), fontSize = 12, color = "on_surface_variant" })
    }))
    return children
  end

  local rows = {}
  if #searchResults.artists > 0 then
    table.insert(rows, ui.label({ text = noctalia.tr("panel.library_artists"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }))
    for _, item in ipairs(searchResults.artists) do
      table.insert(rows, libraryNavRow(item.name or "?", "user", function()
        libraryPush("artist_albums", item.id, item.name, item.uri)
      end))
    end
  end
  if #searchResults.albums > 0 then
    table.insert(rows, ui.label({ text = noctalia.tr("panel.library_albums"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }))
    for _, item in ipairs(searchResults.albums) do
      local label = item.name or "?"
      if item.artist ~= nil and item.artist ~= "" then
        label = label .. " — " .. item.artist
      end
      table.insert(rows, libraryNavRow(label, "disc", function()
        libraryPush("album_tracks", item.id, item.name, item.uri)
      end))
    end
  end
  if #rows == 0 then
    table.insert(rows, ui.label({ text = noctalia.tr("panel.library_empty"), fontSize = 12, color = "on_surface_variant" }))
  end

  table.insert(children, ui.scroll({ key = "search-results", flexGrow = 1, gap = 4, align = "stretch" }, rows))
  return children
end

local function libraryHeaderRow()
  local top = libraryTop()
  if top == nil then
    return ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "library", size = 15, color = "on_surface" }),
      ui.label({ text = noctalia.tr("panel.library_title"), fontSize = 12, fontWeight = "bold" })
    })
  end
  return ui.row({ gap = 4, align = "center" }, {
    ui.button({
      glyph = "chevron-left",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.back"),
      onClick = libraryPop
    }),
    ui.label({
      text = top.name or noctalia.tr("panel.library_title"),
      fontSize = 12,
      fontWeight = "bold",
      flexGrow = 1,
      maxLines = 2
    })
  })
end

local function libraryContent()
  local children = { libraryHeaderRow() }
  local top = libraryTop()

  if top == nil then
    table.insert(children, ui.column({ gap = 8, align = "stretch" }, {
      ui.button({
        glyph = "user",
        text = noctalia.tr("panel.library_artists"),
        variant = "secondary",
        controlSize = "md",
        onClick = function() libraryPush("artists", nil, noctalia.tr("panel.library_artists")) end
      }),
      ui.button({
        glyph = "disc",
        text = noctalia.tr("panel.library_albums"),
        variant = "secondary",
        controlSize = "md",
        onClick = function() libraryPush("albums", nil, noctalia.tr("panel.library_albums")) end
      }),
      ui.button({
        glyph = "tag",
        text = noctalia.tr("panel.library_genres"),
        variant = "secondary",
        controlSize = "md",
        onClick = function() libraryPush("genres", nil, noctalia.tr("panel.library_genres")) end
      }),
      ui.button({
        glyph = "playlist",
        text = noctalia.tr("panel.library_playlists"),
        variant = "secondary",
        controlSize = "md",
        onClick = function() libraryPush("playlists", nil, noctalia.tr("panel.library_playlists")) end
      }),
      ui.button({
        glyph = "radio",
        text = noctalia.tr("panel.library_radio"),
        variant = "secondary",
        controlSize = "md",
        onClick = function() libraryPush("radio", nil, noctalia.tr("panel.library_radio")) end
      }),
      ui.button({
        glyph = "search",
        text = noctalia.tr("panel.library_search"),
        variant = "secondary",
        controlSize = "md",
        onClick = function()
          searchQuery = ""
          searchResults = nil
          libraryPush("search", nil, noctalia.tr("panel.library_search"))
        end
      })
    }))
    return children
  end

  if top.screen == "search" then
    for _, child in ipairs(searchScreenContent()) do
      table.insert(children, child)
    end
    return children
  end

  if libraryLoading then
    table.insert(children, ui.row({ align = "center", justify = "center", flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("panel.loading"), fontSize = 12, color = "on_surface_variant" })
    }))
    return children
  end

  if libraryItems == nil then
    table.insert(children, ui.column({ gap = 8, align = "center", justify = "center", flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("panel.library_error"), fontSize = 12, color = "error" }),
      ui.button({ glyph = "refresh", text = noctalia.tr("panel.refresh"), variant = "secondary", onClick = loadLibrary })
    }))
    return children
  end

  if #libraryItems == 0 then
    table.insert(children, ui.row({ align = "center", justify = "center", flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("panel.library_empty"), fontSize = 12, color = "on_surface_variant" })
    }))
    return children
  end

  local rows = {}
  for _, item in ipairs(libraryItems) do
    if top.screen == "artists" then
      table.insert(rows, libraryRow(
        item.name or "?",
        function() libraryPush("artist_albums", item.id, item.name, item.uri) end,
        function() queueAction(item.uri, true, true) end,
        "player-play-filled",
        noctalia.tr("panel.play_now")
      ))
    elseif top.screen == "playlists" then
      table.insert(rows, libraryRow(
        item.name or "?",
        function() libraryPush("playlist_tracks", item.id, item.name, item.uri) end,
        function() queueAction(item.uri, true, true) end,
        "player-play-filled",
        noctalia.tr("panel.play_now")
      ))
    elseif top.screen == "artist_albums" or top.screen == "albums" or top.screen == "genre_albums" then
      table.insert(rows, libraryRow(
        item.name or "?",
        function() libraryPush("album_tracks", item.id, item.name, item.uri) end,
        function() queueAction(item.uri, true, true) end,
        "player-play-filled",
        noctalia.tr("panel.play_now")
      ))
    elseif top.screen == "genres" then
      local label = item.name or "?"
      if item.track_count ~= nil then
        label = label .. "  ·  " .. tostring(item.track_count)
      end
      table.insert(rows, libraryNavRow(label, "chevron-right", function()
        libraryPush("genre_albums", nil, item.name, nil)
      end))
    elseif top.screen == "radio" then
      table.insert(rows, libraryNavRow(
        item.title or item.artist or "?",
        "radio",
        function() queueAction(item.uri, true, true) end
      ))
    else -- album_tracks / playlist_tracks
      local label = item.title or "?"
      if item.artist ~= nil and item.artist ~= "" then
        label = label .. " — " .. item.artist
      end
      table.insert(rows, libraryRow(
        label,
        function() queueAction(item.uri, true, true) end,
        function() queueAction(item.uri, false, false) end,
        "plus",
        noctalia.tr("panel.add_to_queue")
      ))
    end
  end

  table.insert(children, ui.scroll({
    key = "library-" .. top.screen .. "-" .. tostring(top.id or "root"),
    flexGrow = 1,
    gap = 4,
    align = "stretch"
  }, rows))

  return children
end

local function formatTime(ms)
  local totalSec = math.floor((ms or 0) / 1000)
  local mins = math.floor(totalSec / 60)
  local secs = totalSec % 60
  return string.format("%d:%02d", mins, secs)
end

local function ensureArtwork(artUrl)
  if artUrl == nil or artUrl == "" then
    currentArtworkPath = nil
    lastArtworkUrl = nil
    return
  end
  if artUrl == lastArtworkUrl and currentArtworkPath ~= nil and noctalia.fileInfo(currentArtworkPath) ~= nil then
    return
  end

  local fullUrl = artUrl
  if not fullUrl:match("^https?://") then
    local cleaned = artUrl:gsub("^%./", "")
    if not cleaned:match("^/") then
      cleaned = "/" .. cleaned
    end
    local host = noctalia.getConfig("host") or "127.0.0.1:3689"
    local user = noctalia.getConfig("username") or ""
    local auth = ""
    if user ~= "" then
      local pass = noctalia.getConfig("password") or ""
      auth = noctalia.string.urlEncode(user) .. ":" .. noctalia.string.urlEncode(pass) .. "@"
    end
    fullUrl = "http://" .. auth .. host .. cleaned
  end

  local dir = noctalia.pluginDataDir()
  noctalia.mkdirAll(dir)
  local dest = dir .. "/nowplaying.jpg"

  lastArtworkUrl = artUrl
  noctalia.download(fullUrl, dest, function(ok)
    if ok and noctalia.fileInfo(dest) ~= nil then
      currentArtworkPath = dest
    else
      currentArtworkPath = nil
    end
    render()
  end)
end

local function togglePlayback()
  put("/api/player/toggle")
  if status ~= nil and status.state ~= nil then
    status.state = (status.state == "play") and "pause" or "play"
    render()
  end
end

local function prevTrack()
  put("/api/player/previous")
end

local function nextTrack()
  put("/api/player/next")
end

local function stopPlayback()
  put("/api/player/stop")
  if status ~= nil then
    status.state = "stop"
    render()
  end
end

local function toggleShuffle()
  local newVal = not (status and status.shuffle)
  put("/api/player/shuffle?state=" .. tostring(newVal))
  if status ~= nil then
    status.shuffle = newVal
    render()
  end
end

local function cycleRepeat()
  local current = (status and status.repeat_mode) or "off"
  local nextMode = "off"
  if current == "off" then
    nextMode = "all"
  elseif current == "all" then
    nextMode = "single"
  else
    nextMode = "off"
  end
  put("/api/player/repeat?state=" .. nextMode)
  if status ~= nil then
    status.repeat_mode = nextMode
    render()
  end
end

local function commitMasterVolume()
  if draftVolume ~= nil then
    put(string.format("/api/player/volume?volume=%d", draftVolume))
    if status ~= nil then
      status.volume = draftVolume
    end
    draftVolume = nil
  end
end

local function toggleMute()
  local cur = draftVolume or (status and status.volume) or 0
  if cur == 0 then
    put("/api/player/volume?volume=25")
    if status ~= nil then
      status.volume = 25
    end
  else
    put("/api/player/volume?volume=0")
    if status ~= nil then
      status.volume = 0
    end
  end
  draftVolume = nil
  render()
end

local function toggleOutput(id)
  put("/api/outputs/" .. tostring(id) .. "/toggle")
  if status ~= nil and status.outputs ~= nil then
    for _, out in ipairs(status.outputs) do
      if tostring(out.id) == tostring(id) then
        out.selected = not out.selected
        break
      end
    end
    render()
  end
end

local function commitOutputVolume(id)
  local vol = draftOutputVolumes[id]
  if vol ~= nil then
    put("/api/outputs/" .. tostring(id), { volume = vol })
    if status ~= nil and status.outputs ~= nil then
      for _, out in ipairs(status.outputs) do
        if tostring(out.id) == tostring(id) then
          out.volume = vol
          break
        end
      end
    end
    draftOutputVolumes[id] = nil
  end
end

function render()
  local rootChildren = {}

  -- Header
  local header = ui.row({ align = "center", justify = "space_between" }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "disc", size = 18, color = "primary" }),
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 15, fontWeight = "bold" })
    }),
    ui.row({ gap = 4, align = "center" }, {
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.refresh"),
        onClick = refresh
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.close"),
        onClick = function() panel.close() end
      })
    })
  })
  table.insert(rootChildren, header)

  -- Unreachable state
  if status == nil or status.reachable ~= true then
    table.insert(rootChildren, ui.column({
      gap = 12,
      padding = 24,
      align = "center",
      justify = "center",
      flexGrow = 1
    }, {
      ui.glyph({ name = "music-off", size = 44, color = "error" }),
      ui.label({
        text = noctalia.tr("unreachable"),
        fontSize = 14,
        fontWeight = "bold",
        color = "error"
      }),
      ui.label({
        text = "Host: " .. baseUrl(),
        fontSize = 11,
        color = "on_surface_variant"
      }),
      ui.button({
        glyph = "refresh",
        text = noctalia.tr("panel.refresh"),
        variant = "secondary",
        onClick = refresh
      })
    }))
    panel.render(ui.column({ gap = 12, padding = 14, flexGrow = 1, align = "stretch" }, rootChildren))
    return
  end

  -- Player / Library tabs
  local tabsRow = ui.row({ gap = 6, align = "center" }, {
    ui.button({
      glyph = "disc",
      text = noctalia.tr("panel.tab_player"),
      variant = (view == "player") and "secondary" or "ghost",
      controlSize = "sm",
      flexGrow = 1,
      onClick = closeLibrary
    }),
    ui.button({
      glyph = "library",
      text = noctalia.tr("panel.tab_library"),
      variant = (view == "library") and "secondary" or "ghost",
      controlSize = "sm",
      flexGrow = 1,
      onClick = openLibrary
    })
  })
  table.insert(rootChildren, tabsRow)

  if view == "library" then
    for _, child in ipairs(libraryContent()) do
      table.insert(rootChildren, child)
    end
    panel.render(ui.column({ gap = 10, padding = 12, flexGrow = 1, align = "stretch" }, rootChildren))
    return
  end

  local isPlaying = status.state == "play"
  local lengthMs = status.item_length_ms or 0
  local hasDuration = lengthMs > 0
  local title = status.title or ""
  local artist = status.artist or ""
  local album = status.album or ""
  local curMasterVol = draftVolume or status.volume or 0
  local repeatMode = status.repeat_mode or "off"

  -- Artwork or music glyph
  local artComponent = nil
  if currentArtworkPath ~= nil and noctalia.fileInfo(currentArtworkPath) ~= nil then
    artComponent = ui.image({ path = currentArtworkPath, width = 64, height = 64, radius = 8 })
  else
    artComponent = ui.row({
      width = 64,
      height = 64,
      align = "center",
      justify = "center",
      fill = "surface_variant/0.5",
      radius = 8
    }, {
      ui.glyph({ name = "music", size = 30, color = "primary" })
    })
  end

  -- Track metadata column
  local metaColumn = ui.column({ gap = 2, flexGrow = 1 }, {
    ui.label({
      text = title ~= "" and title or noctalia.tr("panel.no_track"),
      fontSize = 13,
      fontWeight = "bold",
      maxLines = 2
    }),
    artist ~= "" and ui.label({
      text = artist,
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 1
    }) or ui.spacer({ height = 0 }),
    album ~= "" and ui.label({
      text = album,
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 1
    }) or ui.spacer({ height = 0 })
  })

  local trackRow = ui.row({ gap = 12, align = "center" }, {
    artComponent,
    metaColumn
  })

  -- Progress / Stream indicator
  local progressBlock = nil
  if hasDuration then
    local progressFraction = math.min(1, math.max(0, localProgressMs / lengthMs))
    progressBlock = ui.column({ gap = 4, align = "stretch" }, {
      ui.progress({ progress = progressFraction, flexGrow = 1, height = 4 }),
      ui.row({ justify = "space_between", align = "center" }, {
        ui.label({ text = formatTime(localProgressMs), fontSize = 10, color = "on_surface_variant" }),
        ui.label({ text = formatTime(lengthMs), fontSize = 10, color = "on_surface_variant" })
      })
    })
  elseif isPlaying then
    progressBlock = ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "radio", size = 12, color = "primary" }),
      ui.label({ text = noctalia.tr("panel.live_stream"), fontSize = 10, color = "primary" })
    })
  else
    progressBlock = ui.spacer({ height = 2 })
  end

  -- Playback controls row
  local controlsRow = ui.row({ justify = "space_between", align = "center" }, {
    ui.button({
      glyph = "arrows-shuffle",
      variant = "ghost",
      controlSize = "sm",
      selected = status.shuffle,
      tooltip = noctalia.tr("panel.shuffle"),
      onClick = toggleShuffle
    }),
    ui.button({
      glyph = "player-skip-back",
      variant = "ghost",
      controlSize = "md",
      tooltip = noctalia.tr("panel.prev"),
      onClick = prevTrack
    }),
    ui.button({
      glyph = isPlaying and "player-pause-filled" or "player-play-filled",
      variant = "primary",
      controlSize = "md",
      tooltip = isPlaying and noctalia.tr("panel.pause") or noctalia.tr("panel.play"),
      onClick = togglePlayback
    }),
    ui.button({
      glyph = "player-stop",
      variant = "ghost",
      controlSize = "md",
      tooltip = noctalia.tr("panel.stop"),
      onClick = stopPlayback
    }),
    ui.button({
      glyph = "player-skip-forward",
      variant = "ghost",
      controlSize = "md",
      tooltip = noctalia.tr("panel.next"),
      onClick = nextTrack
    }),
    ui.button({
      glyph = (repeatMode == "single") and "repeat-once" or "repeat",
      variant = "ghost",
      controlSize = "sm",
      selected = (repeatMode ~= "off"),
      tooltip = noctalia.tr("panel.repeat"),
      onClick = cycleRepeat
    })
  })

  -- Master volume row
  local masterVolRow = ui.row({ gap = 8, align = "center" }, {
    ui.button({
      glyph = (curMasterVol == 0) and "volume-off" or "volume-2",
      variant = "ghost",
      controlSize = "sm",
      tooltip = (curMasterVol == 0) and noctalia.tr("panel.unmute") or noctalia.tr("panel.mute"),
      onClick = toggleMute
    }),
    ui.slider({
      min = 0,
      max = 100,
      step = 1,
      value = curMasterVol,
      flexGrow = 1,
      controlSize = "sm",
      onChange = function(v)
        draftVolume = math.floor(tonumber(v) or 0)
        render()
      end,
      onDragEnd = commitMasterVolume
    }),
    ui.label({
      text = tostring(curMasterVol) .. "%",
      fontSize = 11,
      width = 36,
      textAlign = "end"
    })
  })

  -- Now Playing Card
  local playerCard = ui.column({
    gap = 10,
    fill = "surface_variant/0.3",
    radius = 12,
    padding = 12,
    align = "stretch"
  }, {
    trackRow,
    progressBlock,
    controlsRow,
    masterVolRow
  })
  table.insert(rootChildren, playerCard)

  table.insert(rootChildren, ui.separator({}))

  -- Speakers / Outputs section
  local outputs = status.outputs or {}
  local activeCount = 0
  for _, out in ipairs(outputs) do
    if out.selected == true then
      activeCount = activeCount + 1
    end
  end

  local speakersHeader = ui.row({ justify = "space_between", align = "center" }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "device-speaker", size = 15, color = "on_surface" }),
      ui.label({
        text = noctalia.tr("panel.speakers_title"),
        fontSize = 12,
        fontWeight = "bold"
      })
    }),
    ui.label({
      text = tostring(activeCount) .. " " .. (activeCount == 1 and noctalia.tr("panel.active_one") or noctalia.tr("panel.active_many")),
      fontSize = 11,
      color = "on_surface_variant"
    })
  })
  table.insert(rootChildren, speakersHeader)

  local speakerCards = {}
  for _, out in ipairs(outputs) do
    local isSelected = out.selected == true
    local outVol = draftOutputVolumes[out.id] or out.volume or 0

    local cardChildren = {
      ui.row({ gap = 8, align = "center" }, {
        ui.button({
          glyph = isSelected and "circle-check" or "circle",
          variant = isSelected and "primary" or "ghost",
          controlSize = "sm",
          tooltip = isSelected and noctalia.tr("panel.deactivate") or noctalia.tr("panel.activate"),
          onClick = function() toggleOutput(out.id) end
        }),
        ui.column({ gap = 1, flexGrow = 1 }, {
          ui.label({
            text = out.name or noctalia.tr("panel.speaker_fallback"),
            fontSize = 12,
            fontWeight = isSelected and "bold" or "normal"
          }),
          ui.label({
            text = out.type or "",
            fontSize = 10,
            color = "on_surface_variant"
          })
        }),
        isSelected and ui.label({
          text = tostring(outVol) .. "%",
          fontSize = 11,
          color = "on_surface_variant",
          width = 36,
          textAlign = "end"
        }) or ui.spacer({ width = 0 })
      })
    }

    if isSelected then
      table.insert(cardChildren, ui.row({ gap = 8, align = "center", paddingH = 4 }, {
        ui.glyph({ name = "volume-2", size = 13, color = "on_surface_variant" }),
        ui.slider({
          min = 0,
          max = 100,
          step = 1,
          value = outVol,
          flexGrow = 1,
          controlSize = "sm",
          onChange = function(v)
            draftOutputVolumes[out.id] = math.floor(tonumber(v) or 0)
            render()
          end,
          onDragEnd = function()
            commitOutputVolume(out.id)
          end
        })
      }))
    end

    table.insert(speakerCards, ui.column({
      gap = 4,
      fill = isSelected and "surface_variant/0.25" or "surface_variant/0.1",
      radius = 8,
      padding = 8,
      align = "stretch"
    }, cardChildren))
  end

  local speakersScroll = ui.scroll({
    key = "speakers-list",
    flexGrow = 1,
    gap = 6,
    align = "stretch"
  }, speakerCards)
  table.insert(rootChildren, speakersScroll)

  panel.render(ui.column({
    gap = 10,
    padding = 12,
    flexGrow = 1,
    align = "stretch"
  }, rootChildren))
end

-- Watch state updates from service.luau
noctalia.state.watch(STATUS_KEY, function(value)
  status = value
  if status ~= nil then
    localProgressMs = status.item_progress_ms or 0
    lastProgressSyncMs = noctalia.nowMs()
    if status.artwork_url ~= nil and status.artwork_url ~= "" then
      ensureArtwork(status.artwork_url)
    else
      currentArtworkPath = nil
      lastArtworkUrl = nil
    end
  end
  render()
end)

function onOpen(_context)
  status = noctalia.state.get(STATUS_KEY)
  draftVolume = nil
  draftOutputVolumes = {}
  view = "player"
  libraryStack = {}
  libraryItems = nil
  searchQuery = ""
  searchResults = nil
  refresh()
  render()
end

-- Tick every second for smooth progress updates while playing
panel.setWantsSecondTicks(true)

function update()
  if status ~= nil and status.state == "play" and status.item_length_ms and status.item_length_ms > 0 then
    localProgressMs = math.min(status.item_length_ms, localProgressMs + 1000)
    render()
  end
end

render()
