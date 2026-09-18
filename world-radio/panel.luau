-- panel.luau
-- World Radio: dashboard of countries, genres, station lists, favorites,
-- and local playback through mpv (falls back to ffplay).

local COUNTRIES_CACHE_AGE = 4 * 3600
local STATIONS_PAGE = 100
local COUNTRIES_PAGE = 50
local TOP_COUNTRIES = 12
local SEARCH_DEBOUNCE_MS = 350
local FAV_ANIM_MS = 500
local API_BASE = "https://de1.api.radio-browser.info"
local USER_AGENT = "nilsonlinux/world-radio/1.0.0"

local GENRES = {
  { name = "Rock",      icon = "guitar-pick", tag = "rock" },
  { name = "Pop",       icon = "star",        tag = "pop" },
  { name = "Jazz",      icon = "music",       tag = "jazz" },
  { name = "Classical", icon = "piano",       tag = "classical" },
  { name = "Electronic",icon = "disc",        tag = "electronic" },
  { name = "News",      icon = "news",        tag = "news" },
  { name = "Hip Hop",   icon = "microphone",  tag = "hiphop" },
  { name = "R&B",       icon = "headphones",  tag = "rnb" },
  { name = "Country",   icon = "flag",        tag = "country" },
  { name = "Folk",      icon = "leaf",        tag = "folk" },
  { name = "Reggae",    icon = "sunset",      tag = "reggae" },
  { name = "Metal",     icon = "flame",       tag = "metal" },
  { name = "Blues",     icon = "cloud-rain",  tag = "blues" },
  { name = "Punk",      icon = "bolt",        tag = "punk" },
  { name = "Latin",     icon = "sun",         tag = "latin" },
  { name = "Ambient",   icon = "cloud",       tag = "ambient" },
  { name = "Talk",      icon = "message-circle", tag = "talk" },
  { name = "Sports",    icon = "activity",    tag = "sports" },
  { name = "Dance",     icon = "music-bolt",  tag = "dance" },
  { name = "Alternative", icon = "refresh",   tag = "alternative" },
}

local DECADES = {
  { name = "50s",   icon = "disc", tag = "50s",   kind = "decade" },
  { name = "60s",   icon = "disc", tag = "60s",   kind = "decade" },
  { name = "70s",   icon = "disc", tag = "70s",   kind = "decade" },
  { name = "80s",   icon = "disc", tag = "80s",   kind = "decade" },
  { name = "90s",   icon = "disc", tag = "90s",   kind = "decade" },
  { name = "2000s", icon = "disc", tag = "2000s", kind = "decade" },
  { name = "2010s", icon = "disc", tag = "2010s", kind = "decade" },
  { name = "2020s", icon = "disc", tag = "2020s", kind = "decade" },
}

local playingStation = nil

local DECADE_ALIASES = {
  ["50s"]   = { "50s", "1950s", "50" },
  ["60s"]   = { "60s", "1960s", "60" },
  ["70s"]   = { "70s", "1970s", "70" },
  ["80s"]   = { "80s", "1980s", "80" },
  ["90s"]   = { "90s", "1990s", "90" },
  ["2000s"] = { "2000s", "00s", "2000" },
  ["2010s"] = { "2010s", "10s", "2010" },
  ["2020s"] = { "2020s", "20s", "2020" },
}

local function normalizeTag(s)
  return tostring(s or ""):lower():gsub("[^%w]", "")
end

local function stationMatchesChip(station, tag, isDecade)
  if station == nil or station.tags == nil then
    return false
  end
  for part in tostring(station.tags):gmatch("[^,;&%|/]+") do
    local t = normalizeTag(part)
    if t ~= "" then
      if isDecade then
        local aliases = DECADE_ALIASES[tag]
        if aliases ~= nil then
          for _, a in ipairs(aliases) do
            if t == normalizeTag(a) then
              return true
            end
          end
        end
      elseif t == normalizeTag(tag) then
        return true
      end
    end
  end
  return false
end

local function chipForPlayingStation()
  if playingStation == nil then
    return nil
  end
  for _, g in ipairs(GENRES) do
    if stationMatchesChip(playingStation, g.tag, false) then
      return g
    end
  end
  for _, d in ipairs(DECADES) do
    if stationMatchesChip(playingStation, d.tag, true) then
      return d
    end
  end
  return nil
end

local dataDir
local function getDataDir()
  if dataDir == nil then
    local ok, dir = pcall(noctalia.pluginDataDir)
    dataDir = (ok and type(dir) == "string" and dir ~= "") and dir or nil
  end
  if dataDir == nil then
    local ok, dir = pcall(noctalia.pluginDir)
    dataDir = (ok and dir) or "."
  end
  return dataDir
end

local view = "dashboard"
local countries = nil
local stats = nil
local query = ""
local queryKey = 0
local stationQuery = ""
local stationQueryKey = 0

local selectedCode = nil
local selectedName = ""
local stations = nil
local stationsOffset = 0
local stationsDone = false
local stationsErr = false

local genreStations = nil
local genreOffset = 0
local genreDone = false
local genreErr = false
local genreQuery = ""
local genreQueryKey = 0
local selectedGenre = nil

local function chipActive(g)
  if selectedGenre ~= nil and selectedGenre.tag == g.tag then
    return true
  end
  return stationMatchesChip(playingStation, g.tag, g.kind == "decade")
end

local genreLoading = false

local countriesExpanded = false
local countriesShown = COUNTRIES_PAGE
local genresExpanded = false
local decadesExpanded = false

local globalSearch = ""
local globalSearchKey = 0
local globalResults = nil
local globalOffset = 0
local globalDone = false
local globalErr = false
local globalLoading = false
local globalSearchNonce = 0

local loading = false
local errorMessage = ""

local allStations = nil
local allOffset = 0
local allDone = false
local allErr = false
local allLoading = false
local allCountryShown = COUNTRIES_PAGE

local playingUuid = nil
local playingName = ""
local playingUrl = ""
local playQueue = nil
local playQueueView = nil
local playQueueDone = true
local playQueueOffset = 0
local revealNonce = 0
local favorites = {}
local thumbs = {}
local thumbPending = {}
local failedFavicons = {}
local customStations = {}
local customFormName = ""
local customFormUrl = ""
local customFormCover = ""
local customFormIndex = nil
local currentSongTitle = ""
local lastSongPoll = 0
local SONG_POLL_INTERVAL = 3000
local MARQUEE_SPEED = 6

local hoveredKey = nil
local favAnimUuid = nil
local favAnimStart = 0

local LIVE_GREEN = "#22c55e"

local function startLivePulse()
  panel.setNeedsFrameTick(true)
end

local function stopLivePulse()
  if favAnimUuid == nil then
    panel.setNeedsFrameTick(false)
  end
end

local PULSE_MS = 900
local pulseStart = -1

local function easeOutCubic(p)
  return 1 - (1 - p) ^ 3
end

local function beginStatsPulse()
  pulseStart = noctalia.nowMs()
  panel.setNeedsFrameTick(true)
end

local function totalStationsNumber()
  if stats ~= nil and stats.stations ~= nil then
    return tonumber(stats.stations) or 0
  end
  if countries ~= nil then
    local sum = 0
    for _, c in ipairs(countries) do
      sum = sum + (tonumber(c.count) or 0)
    end
    return sum
  end
  return nil
end

local function totalCountriesNumber()
  if stats ~= nil and stats.countries ~= nil then
    return tonumber(stats.countries) or 0
  end
  if countries ~= nil then
    return #countries
  end
  return nil
end

local render
local renderDashboard
local renderCountry
local renderGenre
local renderFavorites
local renderCustom
local renderAddCustom
local renderMiniPlayer
local renderGlobalSearch
local renderCountrySearch
local renderAllStations
local renderAllCountries

local savePlayingState
local clearPlayingState
local playerAlive
local restorePlayingState
local ensureStationCountry

local function tr(key, subst)
  if subst == nil then
    return noctalia.tr(key)
  end
  return noctalia.tr(key, subst)
end

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local playerName = noctalia.commandExists("mpv") and "mpv" or "ffplay"
local playerArgs = playerName == "mpv" and "--no-video --no-terminal --volume=85" or "-nodisp -loglevel quiet -autoexit -volume 85"

local FLAG_EMOJIS = {}
do
  local letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  for i = 1, #letters do
    local letter = letters:sub(i, i)
    local cp = 127397 + letter:byte()
    local b0 = 0xF0 + math.floor(cp / 0x40000)
    local b1 = 0x80 + math.floor(math.floor(cp / 0x1000) % 0x40)
    local b2 = 0x80 + math.floor(math.floor(cp / 0x40) % 0x40)
    local b3 = 0x80 + (cp % 0x40)
    FLAG_EMOJIS[letter] = string.char(b0, b1, b2, b3)
  end
end

local function flagEmoji(code)
  code = tostring(code or ""):upper()
  local e1, e2 = FLAG_EMOJIS[code:sub(1, 1)], FLAG_EMOJIS[code:sub(2, 2)]
  if e1 == nil or e2 == nil then
    return ""
  end
  return e1 .. e2
end

local function readCachedJson(name, maxAge)
  local path = getDataDir() .. "/" .. name
  local info = noctalia.fileInfo(path)
  if info == nil or info.mtime == nil then
    return nil
  end
  if os.time() - info.mtime > maxAge then
    return nil
  end
  local raw = noctalia.readFile(path)
  if raw == nil then
    return nil
  end
  local ok, val = pcall(noctalia.json.decode, raw)
  if ok then
    return val
  end
  return nil
end

local function writeCachedJson(name, value)
  local ok, encoded = pcall(noctalia.json.encode, value)
  if ok and encoded ~= nil then
    noctalia.writeFile(getDataDir() .. "/" .. name, encoded)
  end
end

local function httpJson(url, cb)
  noctalia.http({
    url = url,
    headers = { "Accept: application/json", "User-Agent: " .. USER_AGENT },
  }, function(res)
    if res == nil or res.ok ~= true then
      cb(nil)
      return
    end
    local ok, decoded = pcall(noctalia.json.decode, res.body)
    if ok then
      cb(decoded)
    else
      cb(nil)
    end
  end)
end

local function genreTag(name)
  for _, g in ipairs(GENRES) do
    if g.name == name then
      return g.tag
    end
  end
  return nil
end

local function fetchStats()
  httpJson(API_BASE .. "/json/stats", function(data)
    if data ~= nil then
      stats = {
        stations = tonumber(data.stations) or 0,
        countries = tonumber(data.countries) or 0,
      }
      writeCachedJson("stats.json", stats)
    end
    render()
  end)
end

local function sanitizeCountries(rawList)
  if type(rawList) ~= "table" then
    return nil
  end
  local list = {}
  local byIso = {}
  for _, c in ipairs(rawList) do
    local name = tostring(c.name or "")
    local iso = tostring(c.iso or ""):upper()
    local count = tonumber(c.count) or 0
    if name ~= "" and iso ~= "" then
      local prev = byIso[iso]
      if prev == nil then
        prev = { name = name, iso = iso, count = count }
        byIso[iso] = prev
        table.insert(list, prev)
      elseif count > prev.count then
        prev.count = count
        prev.name = name
      end
    end
  end
  table.sort(list, function(a, b) return a.count > b.count end)
  return list
end

local function fetchCountries()
  loading = true
  errorMessage = ""
  render()
  httpJson(API_BASE .. "/json/countries", function(data)
    if data == nil then
      if countries == nil then
        errorMessage = tr("panel.error_network")
      end
      loading = false
      render()
      return
    end
    local list = {}
    local byIso = {}
    for _, c in ipairs(data) do
      local name = tostring(c.name or c.country or "")
      local iso = tostring(c.iso_3166_1 or c.countrycode or "")
      if name ~= "" and iso ~= "" then
        local prev = byIso[iso]
        local count = tonumber(c.stationcount) or 0
        if prev == nil then
          prev = { name = name, iso = iso, count = count }
          byIso[iso] = prev
          table.insert(list, prev)
        elseif count > prev.count then
          prev.count = count
          prev.name = name
        end
      end
    end
    table.sort(list, function(a, b) return a.count > b.count end)
    countries = list
    loading = false
    writeCachedJson("countries.json", list)
    render()
    fetchStats()
  end)
end

local function fetchStations(offset)
  loading = true
  errorMessage = ""
  render()
  local url = string.format(
    "%s/json/stations/search?countrycode=%s&order=votes&reverse=true&hidebroken=true&limit=%d&offset=%d",
    API_BASE, noctalia.string.urlEncode(selectedCode), STATIONS_PAGE, offset
  )
  httpJson(url, function(data)
    loading = false
    if data == nil then
      if stations == nil then
        stationsErr = true
      end
      render()
      return
    end
    stations = stations or {}
    for _, s in ipairs(data) do
      local playUrl = (s.url_resolved ~= nil and s.url_resolved ~= "") and s.url_resolved or (s.url or "")
      local name = tostring(s.name or "")
      if name ~= "" and playUrl ~= "" then
        table.insert(stations, {
          uuid = tostring(s.stationuuid or ("s" .. tostring(#stations + 1))),
          name = name,
          url = playUrl,
          favicon = tostring(s.favicon or ""),
          codec = tostring(s.codec or ""),
          bitrate = tonumber(s.bitrate) or 0,
          votes = tonumber(s.votes) or 0,
          tags = tostring(s.tags or ""),
          countrycode = tostring(s.countrycode or ""),
        })
      end
    end
    stationsOffset = offset + #data
    stationsDone = #data < STATIONS_PAGE
    render()
  end)
end

local function fetchGenreStations(offset)
  genreLoading = true
  errorMessage = ""
  render()
  local tag = selectedGenre and selectedGenre.tag or ""
  local url = string.format(
    "%s/json/stations/search?tag=%s&order=votes&reverse=true&hidebroken=true&limit=%d&offset=%d",
    API_BASE, noctalia.string.urlEncode(tag), STATIONS_PAGE, offset
  )
  httpJson(url, function(data)
    genreLoading = false
    if data == nil then
      if genreStations == nil then
        genreErr = true
      end
      render()
      return
    end
    genreStations = genreStations or {}
    for _, s in ipairs(data) do
      local playUrl = (s.url_resolved ~= nil and s.url_resolved ~= "") and s.url_resolved or (s.url or "")
      local name = tostring(s.name or "")
      if name ~= "" and playUrl ~= "" then
        table.insert(genreStations, {
          uuid = tostring(s.stationuuid or ("gs" .. tostring(#genreStations + 1))),
          name = name,
          url = playUrl,
          favicon = tostring(s.favicon or ""),
          codec = tostring(s.codec or ""),
          bitrate = tonumber(s.bitrate) or 0,
          votes = tonumber(s.votes) or 0,
          tags = tostring(s.tags or ""),
          countrycode = tostring(s.countrycode or ""),
        })
      end
    end
    genreOffset = offset + #data
    genreDone = #data < STATIONS_PAGE
    render()
  end)
end

local function fetchGlobalSearch(offset)
  globalLoading = true
  globalErr = false
  render()
  local q = noctalia.string.trim(globalSearch)
  local url = string.format(
    "%s/json/stations/search?name=%s&order=votes&reverse=true&hidebroken=true&limit=%d&offset=%d",
    API_BASE, noctalia.string.urlEncode(q), STATIONS_PAGE, offset
  )
  httpJson(url, function(data)
    globalLoading = false
    if data == nil then
      if globalResults == nil then
        globalErr = true
      end
      render()
      return
    end
    globalResults = globalResults or {}
    for _, s in ipairs(data) do
      local playUrl = (s.url_resolved ~= nil and s.url_resolved ~= "") and s.url_resolved or (s.url or "")
      local name = tostring(s.name or "")
      if name ~= "" and playUrl ~= "" then
        table.insert(globalResults, {
          uuid = tostring(s.stationuuid or ("gsr" .. tostring(#globalResults + 1))),
          name = name,
          url = playUrl,
          favicon = tostring(s.favicon or ""),
          codec = tostring(s.codec or ""),
          bitrate = tonumber(s.bitrate) or 0,
          votes = tonumber(s.votes) or 0,
          tags = tostring(s.tags or ""),
          countrycode = tostring(s.countrycode or ""),
        })
      end
    end
    globalOffset = offset + #data
    globalDone = #data < STATIONS_PAGE
    render()
  end)
end

local function fetchAllStations(offset)
  allLoading = true
  errorMessage = ""
  render()
  local url = string.format(
    "%s/json/stations/search?order=votes&reverse=true&hidebroken=true&limit=%d&offset=%d",
    API_BASE, STATIONS_PAGE, offset
  )
  httpJson(url, function(data)
    allLoading = false
    if data == nil then
      if allStations == nil then
        allErr = true
      end
      render()
      return
    end
    allStations = allStations or {}
    for _, s in ipairs(data) do
      local playUrl = (s.url_resolved ~= nil and s.url_resolved ~= "") and s.url_resolved or (s.url or "")
      local name = tostring(s.name or "")
      if name ~= "" and playUrl ~= "" then
        table.insert(allStations, {
          uuid = tostring(s.stationuuid or ("as" .. tostring(#allStations + 1))),
          name = name,
          url = playUrl,
          favicon = tostring(s.favicon or ""),
          codec = tostring(s.codec or ""),
          bitrate = tonumber(s.bitrate) or 0,
          votes = tonumber(s.votes) or 0,
          tags = tostring(s.tags or ""),
          countrycode = tostring(s.countrycode or ""),
        })
      end
    end
    allOffset = offset + #data
    allDone = #data < STATIONS_PAGE
    render()
  end)
end

local function selectCountry(code, name)
  view = "country"
  selectedCode = code
  selectedName = name
  stations = nil
  stationsOffset = 0
  stationsDone = false
  stationsErr = false
  stationQuery = ""
  stationQueryKey = stationQueryKey + 1
  loading = false
  errorMessage = ""
  hoveredKey = nil
  render()
  fetchStations(0)
end

local function selectGenre(genre)
  view = "genre"
  selectedGenre = genre
  genreStations = nil
  genreOffset = 0
  genreDone = false
  genreErr = false
  genreQuery = ""
  genreQueryKey = genreQueryKey + 1
  genreLoading = false
  errorMessage = ""
  hoveredKey = nil
  render()
  fetchGenreStations(0)
end

local function openAllStations()
  view = "all_stations"
  allStations = nil
  allOffset = 0
  allDone = false
  allErr = false
  allLoading = false
  errorMessage = ""
  hoveredKey = nil
  render()
  fetchAllStations(0)
end

local function openAllCountries()
  view = "all_countries"
  allCountryShown = COUNTRIES_PAGE
  errorMessage = ""
  hoveredKey = nil
  render()
end

local function publishPlaying()
  noctalia.state.set("playing", {
    name = playingName,
    uuid = playingUuid or "",
    url = playingUrl,
    flag = flagEmoji(playingStation ~= nil and playingStation.countrycode or nil),
  })
end

local playerctlAvailable = noctalia.commandExists("playerctl")

local function pollSongTitle()
  if playingUuid == nil or not playerctlAvailable then
    return
  end
  noctalia.runAsync({ "playerctl", "metadata", "--player", "mpv", "--format", "{{xesam:title}}" }, function(result)
    if result.exitCode ~= 0 then
      return
    end
    local title = noctalia.string.trim(result.stdout)
    if title ~= currentSongTitle then
      currentSongTitle = title
      render()
    end
  end)
end

local function stopPlayback()
  playingUuid = nil
  playingName = ""
  playingUrl = ""
  playingStation = nil
  currentSongTitle = ""
  playQueue = nil
  playQueueView = nil
  stopLivePulse()
  clearPlayingState()
  publishPlaying()
  noctalia.runAsync("kill $(cat " .. shellQuote(getDataDir() .. "/player.pid") .. " 2>/dev/null) 2>/dev/null")
  render()
end

local faviconJobs = {}

local function artSource(station)
  if station.favicon ~= "" then
    return station.favicon
  end
  return station.cover or ""
end

local function artDest(station)
  local src = artSource(station)
  if src == "" then
    return nil
  end
  local ext = src:match("%.([%w]+)$")
  if ext == "png" or ext == "gif" or ext == "bmp" or ext == "webp" then
    return getDataDir() .. "/thumbs/" .. station.uuid .. "." .. ext
  end
  return getDataDir() .. "/thumbs/" .. station.uuid .. ".jpg"
end

local function ensureFavicon(station, onDone)
  local dest = artDest(station)
  if dest == nil then
    onDone(nil)
    return
  end
  if failedFavicons[station.uuid] then
    onDone(nil)
    return
  end
  if noctalia.fileInfo(dest) ~= nil then
    thumbs[station.uuid] = thumbs[station.uuid] or dest
    onDone(dest)
    return
  end
  local list = faviconJobs[station.uuid]
  if list ~= nil then
    table.insert(list, onDone)
    return
  end
  list = { onDone }
  faviconJobs[station.uuid] = list
  thumbPending[station.uuid] = true
  noctalia.mkdirAll(getDataDir() .. "/thumbs")
  noctalia.download(artSource(station), dest, function(ok)
    thumbPending[station.uuid] = nil
    faviconJobs[station.uuid] = nil
    if ok then
      thumbs[station.uuid] = dest
    else
      failedFavicons[station.uuid] = true
    end
    render()
    for _, cb in ipairs(list) do
      cb(ok and dest or nil)
    end
  end)
end

local function loadFavicon(station)
  ensureFavicon(station, function() end)
end

local function clearArt(station)
  thumbs[station.uuid] = nil
  failedFavicons[station.uuid] = nil
  for _, ext in ipairs({ "jpg", "png", "gif", "bmp", "webp" }) do
    local path = getDataDir() .. "/thumbs/" .. station.uuid .. "." .. ext
    if noctalia.fileInfo(path) ~= nil then
      pcall(noctalia.removeFile, path)
    end
  end
end

local playingPath = function()
  return getDataDir() .. "/playing.json"
end

savePlayingState = function()
  if playingUuid == nil then
    return
  end
  local ok, encoded = pcall(noctalia.json.encode, {
    station = playingStation,
    queue = playQueue,
    queueView = playQueueView,
    queueDone = playQueueDone,
    queueOffset = playQueueOffset,
    countryCode = selectedCode,
    countryName = selectedName,
    genre = selectedGenre,
  })
  if ok and encoded ~= nil then
    noctalia.writeFile(playingPath(), encoded)
  end
end

clearPlayingState = function()
  noctalia.removeFile(playingPath())
end

playerAlive = function()
  local raw = noctalia.readFile(getDataDir() .. "/player.pid")
  local pid = tonumber((tostring(raw or ""):match("%d+")))
  if pid == nil or pid <= 0 then
    return false
  end
  return noctalia.fileExists("/proc/" .. tostring(pid))
end

restorePlayingState = function()
  if playingUuid ~= nil then
    return
  end
  if not playerAlive() then
    clearPlayingState()
    return
  end
  local raw = noctalia.readFile(playingPath())
  if raw == nil then
    return
  end
  local ok, val = pcall(noctalia.json.decode, raw)
  if not ok or type(val) ~= "table" or type(val.station) ~= "table" then
    return
  end
  local st = val.station
  if type(st.uuid) ~= "string" or type(st.url) ~= "string" then
    return
  end
  playingUuid = st.uuid
  playingName = tostring(st.name or "")
  playingUrl = st.url
  playingStation = st
  ensureStationCountry(st)
  if type(val.queue) == "table" then
    playQueue = val.queue
  end
  playQueueView = val.queueView
  playQueueDone = not not val.queueDone
  playQueueOffset = tonumber(val.queueOffset) or 0
  if type(val.countryCode) == "string" then
    selectedCode = val.countryCode
    selectedName = tostring(val.countryName or "")
  end
  if type(val.genre) == "table" then
    selectedGenre = val.genre
  end
  if type(st.favicon) == "string" and st.favicon ~= "" then
    ensureFavicon(st, function(dest)
      if dest ~= nil then
        thumbs[st.uuid] = dest
      end
      render()
    end)
  end
  publishPlaying()
  startLivePulse()
end

local function viewList(v)
  if v == "country" then
    return stations
  elseif v == "genre" then
    return genreStations
  elseif v == "favorites" then
    return favorites
  elseif v == "custom" then
    return customStations
  elseif v == "search" then
    return globalResults
  elseif v == "all_stations" then
    return allStations
  end
  return nil
end

local function playStation(station, sourceView)
  local pidFile = getDataDir() .. "/player.pid"
  playingUuid = station.uuid
  playingName = station.name
  playingUrl = station.url
  playingStation = station
  ensureStationCountry(station)
  currentSongTitle = ""
  lastSongPoll = 0
  startLivePulse()
  publishPlaying()
  if sourceView ~= nil then
    local src = viewList(sourceView)
    if src ~= nil and #src > 0 then
      playQueue = {}
      for i = 1, #src do
        playQueue[i] = src[i]
      end
      playQueueView = sourceView
      if sourceView == "country" then
        playQueueDone = stationsDone
        playQueueOffset = stationsOffset
      elseif sourceView == "genre" then
        playQueueDone = genreDone
        playQueueOffset = genreOffset
      elseif sourceView == "search" then
        playQueueDone = globalDone
        playQueueOffset = globalOffset
      else
        playQueueDone = true
        playQueueOffset = #src
      end
    end
  end
  render()
  savePlayingState()
  local cover = nil
  if playerName == "mpv" then
    local dest = artDest(station)
    if dest ~= nil and noctalia.fileInfo(dest) ~= nil then
      cover = dest
    end
  end
  local coverArg = ""
  if cover ~= nil then
    coverArg = " --cover-art-files=" .. shellQuote(cover)
  end
  local cmd = string.format(
    "kill $(cat %s 2>/dev/null) 2>/dev/null; %s %s%s %s >/dev/null 2>&1 & echo $! > %s",
    shellQuote(pidFile), playerName, playerArgs, coverArg, shellQuote(station.url), shellQuote(pidFile)
  )
  noctalia.runAsync(cmd)
  if cover == nil then
    loadFavicon(station)
  end
end

local function loadFavorites()
  local raw = noctalia.readFile(getDataDir() .. "/favorites.json")
  if raw == nil then
    return
  end
  local ok, val = pcall(noctalia.json.decode, raw)
  if ok and type(val) == "table" then
    favorites = val
  end
end

local function isFavorite(uuid)
  for _, f in ipairs(favorites) do
    if f.uuid == uuid then
      return true
    end
  end
  return false
end

local function saveFavorites()
  local ok, encoded = pcall(noctalia.json.encode, favorites)
  if ok and encoded ~= nil then
    noctalia.writeFile(getDataDir() .. "/favorites.json", encoded)
  end
end

local countryPending = {}
local countryFailed = {}

ensureStationCountry = function(station)
  if station == nil or station.uuid == nil then
    return
  end
  if station.countrycode ~= nil and station.countrycode ~= "" then
    return
  end
  if countryPending[station.uuid] or countryFailed[station.uuid] then
    return
  end
  countryPending[station.uuid] = true
  local url = string.format("%s/json/stations/byuuid?uuids=%s", API_BASE, noctalia.string.urlEncode(station.uuid))
  httpJson(url, function(data)
    countryPending[station.uuid] = nil
    local cc = (data ~= nil and data[1] ~= nil) and tostring(data[1].countrycode or "") or ""
    if cc == "" then
      countryFailed[station.uuid] = true
      return
    end
    station.countrycode = cc
    local changed = false
    for _, f in ipairs(favorites) do
      if f.uuid == station.uuid then
        f.countrycode = cc
        changed = true
      end
    end
    if changed then
      saveFavorites()
    end
    if playingUuid == station.uuid then
      publishPlaying()
    end
    render()
  end)
end

local function toggleFavorite(station)
  for i, f in ipairs(favorites) do
    if f.uuid == station.uuid then
      table.remove(favorites, i)
      saveFavorites()
      render()
      return
    end
  end
  table.insert(favorites, station)
  favAnimUuid = station.uuid
  favAnimStart = os.clock() * 1000
  panel.setNeedsFrameTick(true)
  saveFavorites()
  render()
end

loadFavorites()

local function loadCustomStations()
  local raw = noctalia.readFile(getDataDir() .. "/custom-stations.json")
  if raw == nil then
    return
  end
  local ok, val = pcall(noctalia.json.decode, raw)
  if ok and type(val) == "table" then
    local clean = {}
    for _, s in ipairs(val) do
      if type(s) == "table" then
        table.insert(clean, s)
      end
    end
    customStations = clean
    for _, s in ipairs(customStations) do
      local dest = artDest(s)
      if dest ~= nil and noctalia.fileInfo(dest) ~= nil then
        thumbs[s.uuid] = thumbs[s.uuid] or dest
      end
    end
  end
end

local function saveCustomStations()
  local ok, encoded = pcall(noctalia.json.encode, customStations)
  if ok and encoded ~= nil then
    noctalia.writeFile(getDataDir() .. "/custom-stations.json", encoded)
  end
end

local function openCustom()
  view = "custom"
  errorMessage = ""
  customFormName = ""
  customFormUrl = ""
  customFormCover = ""
  customFormIndex = nil
  render()
end

local function openAddCustom()
  view = "add_custom"
  customFormName = ""
  customFormUrl = ""
  customFormCover = ""
  customFormIndex = nil
  render()
end

local function openEditCustom(index)
  local s = customStations[index]
  if s == nil then
    return
  end
  customFormIndex = index
  customFormName = s.name or ""
  customFormUrl = s.url or ""
  customFormCover = s.cover or ""
  view = "add_custom"
  render()
end

local function saveCustomStation()
  local url = noctalia.string.trim(customFormUrl)
  if url == "" then
    return
  end
  local name = noctalia.string.trim(customFormName)
  if name == "" then
    name = url:match("^%a+://([^/:]+)") or url
  end
  local cover = noctalia.string.trim(customFormCover)
  local edited = nil
  if customFormIndex ~= nil then
    local candidate = customStations[customFormIndex]
    if type(candidate) == "table" then
      edited = candidate
    end
  end
  if edited ~= nil then
    local oldCover = edited.cover or ""
    edited.name = name
    edited.url = url
    edited.cover = cover
    saveCustomStations()
    if oldCover ~= cover then
      clearArt(edited)
      if cover ~= "" then
        ensureFavicon(edited, function() end)
      end
    end
    if playingUuid == edited.uuid then
      savePlayingState()
    end
  else
    local station = {
      uuid = "custom-" .. tostring(os.time()) .. "-" .. tostring(#customStations + 1),
      name = name,
      url = url,
      favicon = "",
      cover = cover,
      codec = "",
      bitrate = 0,
      votes = 0,
    }
    table.insert(customStations, station)
    saveCustomStations()
    if cover ~= "" then
      ensureFavicon(station, function() end)
    end
  end
  customFormIndex = nil
  view = "custom"
  render()
end

local function removeCustomStation(index)
  table.remove(customStations, index)
  saveCustomStations()
  render()
end

loadCustomStations()

local function countryCount(code)
  if countries == nil then
    return 0
  end
  for _, c in ipairs(countries) do
    if c.iso == code then
      return c.count
    end
  end
  return 0
end

local function statCard(label, value, onClick)
  local key = "stat-" .. label
  local isHovered = onClick ~= nil and hoveredKey == key
  local props = {
    key      = key,
    gap      = 2,
    padding  = 10,
    radius   = 8,
    fill     = isHovered and "surface_variant/0.9" or "surface_variant/0.65",
    align    = "center",
    justify  = "center",
    flexGrow = 1,
  }
  if onClick ~= nil then
    props.onClick = onClick
    props.onHover = function(isHovering)
      hoveredKey = isHovering and key or nil
      render()
    end
  end
  return ui.column(props, {
    ui.label({ text = value, fontSize = 20, fontWeight = "bold", color = "primary" }),
    ui.label({ text = label, fontSize = 11, color = "outline" }),
  })
end

local function spinnerRow()
  return ui.row({ align = "center", justify = "center", gap = 8 }, {
    ui.glyph({ name = "loader-2", size = 18, color = "primary" }),
    ui.label({ text = tr("panel.loading"), fontSize = 12, color = "on_surface/0.7" }),
  })
end

local function centeredLabel(text, color)
  return ui.column({ flexGrow = 1, align = "center", justify = "center", padding = 32 }, {
    ui.label({ text = text, color = color or "outline", textAlign = "center" }),
  })
end

local function countryCard(c)
  local key = "country-card-" .. c.iso
  local flag = flagEmoji(c.iso)
  local flagInner = (flag ~= "")
    and ui.label({ text = flag, fontSize = 14 })
    or ui.glyph({ name = "world", size = 14, color = "outline" })
  local isHovered = (hoveredKey == key)
  return ui.column({
    key         = key,
    gap         = 4,
    padding     = 8,
    radius      = 8,
    fill        = isHovered and "surface_variant/0.9" or "surface_variant/0.5",
    align       = "center",
    justify     = "center",
    flexGrow    = 1,
    onClick     = function() selectCountry(c.iso, c.name) end,
    onHover     = function(isHovering)
      hoveredKey = isHovering and key or nil
      render()
    end,
  }, {
    ui.column({ width = 28, height = 28, radius = 7, fill = "surface_variant/0.65", align = "center", justify = "center" }, { flagInner }),
    ui.label({ text = c.name, fontSize = 10, maxLines = 1, textAlign = "center" }),
    ui.column({ paddingH = 6, paddingV = 1, radius = 8, fill = "primary/0.15" }, {
      ui.label({ text = tostring(c.count), fontSize = 9, fontWeight = "bold", color = "primary" }),
    }),
  })
end

local function countryRow(c)
  local key = "country-row-" .. c.iso
  local flag = flagEmoji(c.iso)
  local flagInner = (flag ~= "")
    and ui.label({ text = flag, fontSize = 12 })
    or ui.glyph({ name = "world", size = 13, color = "outline" })
  local flagWidget = ui.column({ width = 24, height = 24, radius = 6, fill = "surface_variant/0.65", align = "center", justify = "center" }, { flagInner })
  local isHovered = (hoveredKey == key)
  return ui.row({
    key     = key,
    gap     = 8,
    align   = "center",
    paddingH = 6,
    paddingV = 1,
    radius  = 6,
    fill        = "surface_variant/0.4",
    border      = "outline",
    borderWidth = isHovered and 1 or 0,
    onClick = function() selectCountry(c.iso, c.name) end,
    onHover = function(isHovering)
      hoveredKey = isHovering and key or nil
      render()
    end,
  }, {
    flagWidget,
    ui.label({ text = c.name, fontSize = 12, flexGrow = 1, maxLines = 1 }),
    ui.label({ text = tostring(c.count), fontSize = 12, fontWeight = "bold", color = "outline" }),
    ui.glyph({ name = "chevron-right", size = 13, color = "outline" }),
  })
end

local function genreChip(g)
  local key = "genre-" .. g.tag
  local isActive = chipActive(g)
  local isHovered = (hoveredKey == key)
  return ui.row({
    key     = key,
    gap     = 4,
    paddingH = 8,
    paddingV = 4,
    radius  = 14,
    align   = "center",
    fill    = isActive and "primary/0.2" or (isHovered and "surface_variant/0.8" or "surface_variant/0.55"),
    onClick = function() selectGenre(g) end,
    onHover = function(isHovering)
      hoveredKey = isHovering and key or nil
      render()
    end,
  }, {
    ui.glyph({ name = g.icon, size = 11, color = isActive and "primary" or "outline" }),
    ui.label({ text = g.name, fontSize = 10, color = isActive and "primary" or "on_surface" }),
  })
end

renderDashboard = function()
  local children = {}

  local totalStationsNum = totalStationsNumber()
  local totalCountriesNum = totalCountriesNumber()

  local t = 1
  if pulseStart >= 0 then
    t = math.min(1, (noctalia.nowMs() - pulseStart) / PULSE_MS)
    if t >= 1 then
      pulseStart = -1
      if playingUuid == nil and favAnimUuid == nil then
        panel.setNeedsFrameTick(false)
      end
    end
  end
  local eased = easeOutCubic(t)

  local totalStations
  if totalStationsNum ~= nil then
    totalStations = tostring(math.floor(eased * totalStationsNum))
  else
    totalStations = "..."
  end

  local totalCountries
  if totalCountriesNum ~= nil then
    totalCountries = tostring(math.floor(eased * totalCountriesNum))
  else
    totalCountries = "..."
  end

  table.insert(children, ui.row({ gap = 8 }, {
    ui.column({ flexGrow = 1, align = "stretch" }, { statCard(tr("panel.total_stations"), totalStations, openAllStations) }),
    ui.column({ flexGrow = 1, align = "stretch" }, { statCard(tr("panel.total_countries"), totalCountries, openAllCountries) }),
  }))

  table.insert(children, ui.input({
    key         = "global-search-" .. globalSearchKey,
    value       = globalSearch,
    controlSize = "sm",
    focused     = true,
    placeholder = tr("panel.search_global_placeholder"),
    onChange    = "onDashboardSearchRadio",
  }))

  local scrollChildren = {}

  if countries == nil and errorMessage ~= "" then
    table.insert(scrollChildren, centeredLabel(errorMessage, "on_surface/0.6"))
  elseif countries == nil and loading then
    table.insert(scrollChildren, ui.column({ flexGrow = 1, align = "center", justify = "center", padding = 24 }, { spinnerRow() }))
  elseif countries ~= nil then
    local q = noctalia.string.trim(query):lower()

    if q == "" then
      table.insert(scrollChildren, ui.row({
        key         = "genres-toggle",
        gap         = 6,
        align       = "center",
        paddingH    = 8,
        paddingV    = 6,
        radius      = 7,
        fill        = "surface_variant/0.5",
        onClick     = function()
          genresExpanded = not genresExpanded
          render()
        end,
      }, {
        ui.label({ text = tr("panel.genres_title"), fontSize = 12, fontWeight = "bold", flexGrow = 1 }),
        ui.glyph({ name = genresExpanded and "chevron-up" or "chevron-down", size = 14, color = "outline" }),
      }))
      if genresExpanded then
        local chipRows = {}
        for i = 1, #GENRES, 7 do
          local row = {}
          for j = i, math.min(i + 6, #GENRES) do
            table.insert(row, genreChip(GENRES[j]))
          end
          table.insert(chipRows, ui.row({ gap = 6, align = "center" }, row))
        end
        table.insert(scrollChildren, ui.column({ gap = 6 }, chipRows))
      end

      table.insert(scrollChildren, ui.row({
        key         = "decades-toggle",
        gap         = 6,
        align       = "center",
        paddingH    = 8,
        paddingV    = 6,
        radius      = 7,
        fill        = "surface_variant/0.5",
        onClick     = function()
          decadesExpanded = not decadesExpanded
          render()
        end,
      }, {
        ui.label({ text = tr("panel.decades_title"), fontSize = 12, fontWeight = "bold", flexGrow = 1 }),
        ui.glyph({ name = decadesExpanded and "chevron-up" or "chevron-down", size = 14, color = "outline" }),
      }))
      if decadesExpanded then
        local decadeRows = {}
        for i = 1, #DECADES, 7 do
          local row = {}
          for j = i, math.min(i + 6, #DECADES) do
            table.insert(row, genreChip(DECADES[j]))
          end
          table.insert(decadeRows, ui.row({ gap = 6, align = "center" }, row))
        end
        table.insert(scrollChildren, ui.column({ gap = 6 }, decadeRows))
      end

      if #countries > 0 then
        table.insert(scrollChildren, ui.separator({}))
        table.insert(scrollChildren, ui.label({ text = tr("panel.top_countries"), fontSize = 11, fontWeight = "bold", color = "outline" }))
        local topN = {}
        for i = 1, math.min(TOP_COUNTRIES, #countries) do
          table.insert(topN, countryCard(countries[i]))
        end
        local cardRows = {}
        for i = 1, #topN, 4 do
          local row = {}
          for j = i, math.min(i + 3, #topN) do
            table.insert(row, topN[j])
          end
          table.insert(cardRows, ui.row({ gap = 6, align = "stretch" }, row))
        end
        table.insert(scrollChildren, ui.column({ gap = 6 }, cardRows))

        if #countries > TOP_COUNTRIES then
          table.insert(scrollChildren, ui.separator({}))
          local remainingCount = #countries - TOP_COUNTRIES
          table.insert(scrollChildren, ui.row({
            key         = "all-countries-toggle",
            gap         = 6,
            align       = "center",
            paddingH    = 8,
            paddingV    = 6,
            radius      = 7,
            fill        = "surface_variant/0.5",
            onClick     = function()
              countriesExpanded = not countriesExpanded
              if countriesExpanded then
                countriesShown = COUNTRIES_PAGE
              end
              render()
            end,
          }, {
            ui.label({ text = tr("panel.all_countries", { count = tostring(remainingCount) }), fontSize = 12, fontWeight = "bold", flexGrow = 1 }),
            ui.glyph({ name = countriesExpanded and "chevron-up" or "chevron-down", size = 14, color = "outline" }),
          }))
          if countriesExpanded then
            local last = math.min(#countries, TOP_COUNTRIES + countriesShown)
            for i = TOP_COUNTRIES + 1, last do
              table.insert(scrollChildren, countryRow(countries[i]))
            end
            if last < #countries then
              table.insert(scrollChildren, ui.button({
                text         = tr("panel.load_more"),
                variant      = "secondary",
                controlSize  = "md",
                contentAlign = "center",
                onClick      = function()
                  countriesShown = countriesShown + COUNTRIES_PAGE
                  render()
                end,
              }))
            end
          end
        end
      end
    else
      local matches = {}
      for _, c in ipairs(countries) do
        if c.name:lower():find(q, 1, true) ~= nil then
          table.insert(matches, c)
        end
      end
      if #matches == 0 then
        table.insert(scrollChildren, centeredLabel(tr("panel.countries_empty")))
      else
        for _, c in ipairs(matches) do
          table.insert(scrollChildren, countryRow(c))
        end
      end
    end
  end

  table.insert(children, ui.scroll({ gap = 8, flexGrow = 1 }, scrollChildren))

  return children
end

local function stationRow(s, sourceView)
  loadFavicon(s)
  local isPlaying = playingUuid == s.uuid
  local thumb = thumbs[s.uuid]
  local showFlag = (sourceView == "all_stations" or sourceView == "favorites" or sourceView == "genre")
  if showFlag then
    ensureStationCountry(s)
  end
  local stationFlag = showFlag and flagEmoji(s.countrycode) or ""
  local meta = {}
  if stationFlag ~= "" then
    table.insert(meta, stationFlag)
  end
  if s.codec ~= "" then
    table.insert(meta, s.codec)
  end
  if s.bitrate > 0 then
    table.insert(meta, tostring(s.bitrate))
  end
  local metaText = table.concat(meta, " · ")

  local isFavAnim = favAnimUuid == s.uuid
  local key = "station-" .. s.uuid
  local isHovered = (hoveredKey == key)

  local parts = {}
  if thumb ~= nil then
    table.insert(parts, ui.image({ path = thumb, width = 26, height = 26, radius = 4 }))
  else
    table.insert(parts, ui.column({
      width   = 26,
      height  = 26,
      radius  = 4,
      fill    = "surface_variant/0.65",
      align   = "center",
      justify = "center",
    }, { ui.glyph({ name = "radio", size = 15, color = "outline" }) }))
  end

  local labels = {
    ui.label({
      text      = s.name,
      fontSize  = 12,
      maxLines  = 1,
      minWidth  = 0,
      textAlign = "left",
    }),
  }
  if metaText ~= "" then
    table.insert(labels, ui.label({ text = metaText, fontSize = 11, color = "outline" }))
  end
  table.insert(parts, ui.column({
    width = 0,
    flexGrow = 1,
    minWidth = 0,
    gap = 0,
    align = "start",
  }, labels))

  if s.votes > 0 then
    table.insert(parts, ui.label({ text = tostring(s.votes), fontSize = 11, color = "on_surface/0.45" }))
  end

  local faved = isFavorite(s.uuid)
  local starSize = isFavAnim and 17 or 13
  table.insert(parts, ui.button({
    glyph       = faved and "star-filled" or "star",
    glyphSize   = starSize,
    variant     = "ghost",
    controlSize = "sm",
    tooltip     = faved and tr("panel.unfavorite_tooltip") or tr("panel.favorite_tooltip"),
    onClick     = function() toggleFavorite(s) end,
  }))

  table.insert(parts, ui.button({
    glyph       = isPlaying and "square" or "player-play",
    variant     = isPlaying and "primary" or "ghost",
    controlSize = "sm",
    tooltip     = isPlaying and tr("panel.stop_tooltip") or tr("panel.play_tooltip"),
    onClick     = function()
      if isPlaying then
        stopPlayback()
      else
        playStation(s, sourceView)
      end
    end,
  }))

  return ui.row({
    key     = key,
    gap     = 6,
    align   = "center",
    paddingH = 6,
    paddingV = 1,
    radius  = 6,
    fill        = isPlaying and "primary/0.12" or (isHovered and "surface_variant/0.55" or "surface_variant/0.4"),
    border      = isPlaying and "primary/0.3" or "outline",
    borderWidth = (isHovered or isPlaying) and 1 or 0,
    onHover = function(isHovering)
      hoveredKey = isHovering and key or nil
      render()
    end,
  }, parts)
end

renderCountry = function()
  local children = {}

  local headerParts = {}
  local countryFlag = flagEmoji(selectedCode)
  if countryFlag ~= "" then
    table.insert(headerParts, ui.label({ text = countryFlag, fontSize = 20 }))
  end
  table.insert(headerParts, ui.column({ flexGrow = 1, gap = 0 }, {
    ui.label({ text = selectedName, fontSize = 15, fontWeight = "bold", maxLines = 1 }),
    ui.label({ text = tr("panel.station_count", { count = tostring(countryCount(selectedCode)) }), fontSize = 11, color = "outline" }),
  }))
  table.insert(children, ui.row({ gap = 8, align = "center" }, headerParts))

  if stations == nil and loading then
    table.insert(children, ui.column({ flexGrow = 1, align = "center", justify = "center" }, { spinnerRow() }))
  elseif stations == nil and stationsErr then
    table.insert(children, centeredLabel(tr("panel.error_network"), "on_surface/0.6"))
  elseif stations ~= nil then
    table.insert(children, ui.input({
      key         = "station-search-" .. stationQueryKey,
      value       = stationQuery,
      controlSize = "sm",
      placeholder = tr("panel.search_stations_placeholder"),
      onChange    = "onStationSearch",
    }))
    local q = noctalia.string.trim(stationQuery):lower()
    local visible = {}
    for _, s in ipairs(stations) do
      if q == "" or s.name:lower():find(q, 1, true) ~= nil then
        table.insert(visible, s)
      end
    end
    if #visible == 0 and #stations == 0 then
      table.insert(children, centeredLabel(tr("panel.stations_empty")))
    elseif #visible == 0 then
      table.insert(children, centeredLabel(tr("panel.stations_none_match")))
    else
      local rows = {}
      for _, s in ipairs(visible) do
        table.insert(rows, stationRow(s, "country"))
      end
      table.insert(children, ui.scroll({ key = "scroll-country-" .. revealNonce, gap = 2, flexGrow = 1 }, rows))
      if not stationsDone then
        table.insert(children, ui.button({
          text         = tr("panel.load_more"),
          variant      = "secondary",
          controlSize  = "md",
          contentAlign = "center",
          enabled      = not loading,
          onClick      = "onLoadMore",
        }))
      end
    end
  end

  return children
end

renderGenre = function()
  local children = {}

  if selectedGenre ~= nil then
    local genreIcon = ui.glyph({ name = selectedGenre.icon, size = 16, color = "primary" })
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      genreIcon,
      ui.column({ flexGrow = 1, gap = 0 }, {
        ui.label({ text = selectedGenre.name, fontSize = 15, fontWeight = "bold", maxLines = 1 }),
        ui.label({ text = tr(selectedGenre.kind == "decade" and "panel.decade_stations" or "panel.genre_stations"), fontSize = 11, color = "outline" }),
      }),
    }))
  end

  if genreStations == nil and genreLoading then
    table.insert(children, ui.column({ flexGrow = 1, align = "center", justify = "center" }, { spinnerRow() }))
  elseif genreStations == nil and genreErr then
    table.insert(children, centeredLabel(tr("panel.error_network"), "on_surface/0.6"))
  elseif genreStations ~= nil then
    table.insert(children, ui.input({
      key         = "genre-search-" .. genreQueryKey,
      value       = genreQuery,
      controlSize = "sm",
      placeholder = tr("panel.search_stations_placeholder"),
      onChange    = "onGenreSearch",
    }))
    local q = noctalia.string.trim(genreQuery):lower()
    local visible = {}
    for _, s in ipairs(genreStations) do
      if q == "" or s.name:lower():find(q, 1, true) ~= nil then
        table.insert(visible, s)
      end
    end
    if #visible == 0 and #genreStations == 0 then
      table.insert(children, centeredLabel(tr("panel.stations_empty")))
    elseif #visible == 0 then
      table.insert(children, centeredLabel(tr("panel.stations_none_match")))
    else
      local rows = {}
      for _, s in ipairs(visible) do
        table.insert(rows, stationRow(s, "genre"))
      end
      table.insert(children, ui.scroll({ key = "scroll-genre-" .. revealNonce, gap = 2, flexGrow = 1 }, rows))
      if not genreDone then
        table.insert(children, ui.button({
          text         = tr("panel.load_more"),
          variant      = "secondary",
          controlSize  = "md",
          contentAlign = "center",
          enabled      = not genreLoading,
          onClick      = "onLoadMoreGenre",
        }))
      end
    end
  end

  return children
end

renderGlobalSearch = function()
  local children = {}

  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "search", size = 16, color = "primary" }),
    ui.column({ flexGrow = 1, gap = 0 }, {
      ui.label({ text = tr("panel.search_title"), fontSize = 15, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = tr("panel.search_subtitle"), fontSize = 11, color = "outline" }),
    }),
  }))

  table.insert(children, ui.input({
    key         = "global-search-" .. globalSearchKey,
    value       = globalSearch,
    controlSize = "sm",
    focus       = true,
    placeholder = tr("panel.search_global_placeholder"),
    onChange    = "onGlobalSearchChanged",
  }))

  if globalResults == nil and globalLoading then
    table.insert(children, ui.column({ flexGrow = 1, align = "center", justify = "center" }, { spinnerRow() }))
  elseif globalResults == nil and globalErr then
    table.insert(children, centeredLabel(tr("panel.error_network"), "on_surface/0.6"))
  elseif globalResults == nil then
    table.insert(children, centeredLabel(tr("panel.search_hint")))
  elseif #globalResults == 0 then
    table.insert(children, centeredLabel(tr("panel.search_no_results")))
  else
    local rows = {}
for _, s in ipairs(globalResults) do
        table.insert(rows, stationRow(s, "search"))
      end
      table.insert(children, ui.scroll({ key = "scroll-search-" .. revealNonce, gap = 2, flexGrow = 1 }, rows))
      if not globalDone then
      table.insert(children, ui.button({
        text         = tr("panel.load_more"),
        variant      = "secondary",
        controlSize  = "md",
        contentAlign = "center",
        enabled      = not globalLoading,
        onClick      = "onLoadMoreGlobal",
      }))
    end
  end

  return children
end

renderCountrySearch = function()
  local children = {}

  table.insert(children, ui.input({
    key         = "country-search-" .. queryKey,
    value       = query,
    controlSize = "md",
    focused     = true,
    placeholder = tr("panel.search_countries_placeholder"),
    onChange    = "onSearchCountries",
  }))

  local scrollChildren = {}
  if countries == nil and errorMessage ~= "" then
    table.insert(scrollChildren, centeredLabel(errorMessage, "on_surface/0.6"))
  elseif countries == nil and loading then
    table.insert(scrollChildren, ui.column({ flexGrow = 1, align = "center", justify = "center", padding = 24 }, { spinnerRow() }))
  elseif countries ~= nil then
    local q = noctalia.string.trim(query):lower()
    if q == "" then
      table.insert(scrollChildren, centeredLabel(tr("panel.search_countries_hint"), "outline"))
    else
      local matches = {}
      for _, c in ipairs(countries) do
        if c.name:lower():find(q, 1, true) ~= nil then
          table.insert(matches, c)
        end
      end
      if #matches == 0 then
        table.insert(scrollChildren, centeredLabel(tr("panel.countries_empty")))
      else
        for _, c in ipairs(matches) do
          table.insert(scrollChildren, countryRow(c))
        end
      end
    end
  end
  table.insert(children, ui.scroll({ gap = 2, flexGrow = 1 }, scrollChildren))

  return children
end

renderAllStations = function()
  local children = {}

  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "radio", size = 16, color = "primary" }),
    ui.column({ flexGrow = 1, gap = 0 }, {
      ui.label({ text = tr("panel.all_stations_title"), fontSize = 15, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = tr("panel.station_count", { count = allStations ~= nil and tostring(#allStations) or "..." }), fontSize = 11, color = "outline" }),
    }),
  }))

  if allStations == nil and allLoading then
    table.insert(children, ui.column({ flexGrow = 1, align = "center", justify = "center" }, { spinnerRow() }))
  elseif allStations == nil and allErr then
    table.insert(children, centeredLabel(tr("panel.error_network"), "on_surface/0.6"))
  elseif allStations ~= nil then
    if #allStations == 0 then
      table.insert(children, centeredLabel(tr("panel.stations_empty")))
    else
      local rows = {}
      for _, s in ipairs(allStations) do
        table.insert(rows, stationRow(s, "all_stations"))
      end
      table.insert(children, ui.scroll({ key = "scroll-allstations-" .. revealNonce, gap = 2, flexGrow = 1 }, rows))
      if not allDone then
        table.insert(children, ui.button({
          text         = tr("panel.load_more"),
          variant      = "secondary",
          controlSize  = "md",
          contentAlign = "center",
          enabled      = not allLoading,
          onClick      = "onLoadMoreAllStations",
        }))
      end
    end
  end

  return children
end

renderAllCountries = function()
  local children = {}

  local total = (countries ~= nil) and #countries or 0
  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "world", size = 16, color = "primary" }),
    ui.column({ flexGrow = 1, gap = 0 }, {
      ui.label({ text = tr("panel.all_countries_title"), fontSize = 15, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = tr("panel.all_countries_subtitle", { shown = tostring(math.min(allCountryShown, total)), total = tostring(total) }), fontSize = 11, color = "outline" }),
    }),
  }))

  local scrollChildren = {}
  if countries == nil and errorMessage ~= "" then
    table.insert(scrollChildren, centeredLabel(errorMessage, "on_surface/0.6"))
  elseif countries == nil and loading then
    table.insert(scrollChildren, ui.column({ flexGrow = 1, align = "center", justify = "center", padding = 24 }, { spinnerRow() }))
  elseif countries ~= nil then
    if #countries == 0 then
      table.insert(scrollChildren, centeredLabel(tr("panel.countries_empty")))
    else
      for i = 1, math.min(allCountryShown, #countries) do
        table.insert(scrollChildren, countryRow(countries[i]))
      end
    end
  end
  table.insert(children, ui.scroll({ gap = 2, flexGrow = 1 }, scrollChildren))
  if countries ~= nil and allCountryShown < #countries then
    table.insert(children, ui.button({
      text         = tr("panel.load_more"),
      variant      = "secondary",
      controlSize  = "md",
      contentAlign = "center",
      onClick      = function()
        allCountryShown = math.min(#countries, allCountryShown + COUNTRIES_PAGE)
        render()
      end,
    }))
  end

  return children
end

renderFavorites = function()
  local children = {}

  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "star-filled", size = 16, color = "warning" }),
    ui.column({ flexGrow = 1, gap = 0 }, {
      ui.label({ text = tr("panel.favorites_title"), fontSize = 15, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = tr("panel.favorites_count", { count = tostring(#favorites) }), fontSize = 11, color = "outline" }),
    }),
  }))

  if #favorites == 0 then
    table.insert(children, centeredLabel(tr("panel.favorites_empty")))
  else
    local rows = {}
    for _, s in ipairs(favorites) do
      table.insert(rows, stationRow(s, "favorites"))
    end
    table.insert(children, ui.scroll({ key = "scroll-favorites-" .. revealNonce, gap = 2, flexGrow = 1 }, rows))
  end

  return children
end

local function customRow(s, index)
  local key = "custom-" .. s.uuid
  local isPlaying = playingUuid == s.uuid
  local isHovered = (hoveredKey == key)
  local labels = { ui.label({ text = s.name, fontSize = 12, maxLines = 1 }) }
  local art = thumbs[s.uuid]
  local parts = {
    art ~= nil
        and ui.image({ path = art, width = 22, height = 22, radius = 4 })
      or ui.column({
          width   = 22,
          height  = 22,
          radius  = 4,
          fill    = "surface_variant/0.65",
          align   = "center",
          justify = "center",
        }, { ui.glyph({ name = "radio", size = 13, color = "outline" }) }),
    ui.column({ flexGrow = 1, gap = 0 }, labels),
  }
  table.insert(parts, ui.button({
    glyph       = "pencil",
    variant     = "ghost",
    controlSize = "sm",
    tooltip     = tr("panel.edit_custom_tooltip"),
    onClick     = function() openEditCustom(index) end,
  }))
  table.insert(parts, ui.button({
    glyph       = "trash",
    variant     = "ghost",
    controlSize = "sm",
    tooltip     = tr("panel.remove_custom_tooltip"),
    onClick     = function() removeCustomStation(index) end,
  }))
  table.insert(parts, ui.button({
    glyph       = isPlaying and "square" or "player-play",
    variant     = isPlaying and "primary" or "ghost",
    controlSize = "sm",
    tooltip     = isPlaying and tr("panel.stop_tooltip") or tr("panel.play_tooltip"),
    onClick     = function()
      if isPlaying then
        stopPlayback()
      else
        playStation(s, "custom")
      end
    end,
  }))
  return ui.row({
    key     = key,
    gap     = 6,
    align   = "center",
    paddingH = 6,
    paddingV = 1,
    radius  = 6,
    fill        = isPlaying and "primary/0.12" or "surface_variant/0.4",
    border      = isPlaying and "primary/0.3" or "outline",
    borderWidth = (isHovered or isPlaying) and 1 or 0,
    onHover = function(isHovering)
      hoveredKey = isHovering and key or nil
      render()
    end,
  }, parts)
end

renderCustom = function()
  local children = {}

  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "broadcast", size = 16, color = "primary" }),
    ui.column({ flexGrow = 1, gap = 0 }, {
      ui.label({ text = tr("panel.custom_title"), fontSize = 15, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = tr("panel.custom_count", { count = tostring(#customStations) }), fontSize = 11, color = "outline" }),
    }),
    ui.button({
      glyph       = "plus",
      variant     = "secondary",
      controlSize = "md",
      tooltip     = tr("panel.add_custom_tooltip"),
      onClick     = openAddCustom,
    }),
  }))

  if #customStations == 0 then
    table.insert(children, ui.column({ gap = 10, align = "center", padding = 32, flexGrow = 1, justify = "center" }, {
      ui.glyph({ name = "broadcast", size = 32, color = "outline" }),
      ui.label({ text = tr("panel.custom_empty"), color = "outline", textAlign = "center" }),
    }))
  else
    local rows = {}
    for i, s in ipairs(customStations) do
      table.insert(rows, customRow(s, i))
    end
    table.insert(children, ui.scroll({ key = "scroll-custom-" .. revealNonce, gap = 2, flexGrow = 1 }, rows))
  end

  return children
end

renderAddCustom = function()
  local children = {}

  local isEdit = customFormIndex ~= nil
  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = isEdit and "pencil" or "plus", size = 16, color = "primary" }),
    ui.column({ flexGrow = 1, gap = 0 }, {
      ui.label({ text = isEdit and tr("panel.edit_custom_title") or tr("panel.add_custom_title"), fontSize = 15, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = tr("panel.add_custom_subtitle"), fontSize = 11, color = "outline" }),
    }),
  }))

  table.insert(children, ui.input({
    key         = "custom-name-input",
    value       = customFormName,
    controlSize = "md",
    placeholder = tr("panel.add_custom_name_placeholder"),
    onChange    = function(value) customFormName = value or "" end,
  }))

  table.insert(children, ui.input({
    key         = "custom-url-input",
    value       = customFormUrl,
    controlSize = "md",
    placeholder = tr("panel.add_custom_url_placeholder"),
    onChange    = function(value) customFormUrl = value or "" end,
  }))

  table.insert(children, ui.input({
    key         = "custom-cover-input",
    value       = customFormCover,
    controlSize = "md",
    placeholder = tr("panel.add_custom_cover_placeholder"),
    onChange    = function(value) customFormCover = value or "" end,
  }))

  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.button({
      text         = tr("panel.add_custom_save"),
      variant      = "primary",
      controlSize  = "md",
      contentAlign = "center",
      onClick      = saveCustomStation,
    }),
    ui.button({
      text         = tr("panel.add_custom_cancel"),
      variant      = "ghost",
      controlSize  = "md",
      contentAlign = "center",
      onClick      = openCustom,
    }),
  }))

  return children
end

local function queueIndex()
  if playQueue == nil or playingUuid == nil then
    return 0
  end
  for i, s in ipairs(playQueue) do
    if s.uuid == playingUuid then
      return i
    end
  end
  return 0
end

local function skipPlaying(dir)
  local n = playQueue and #playQueue or 0
  if n < 2 then
    return
  end
  local idx = queueIndex()
  if idx == 0 then
    return
  end
  playStation(playQueue[((idx - 1 + dir) % n) + 1], playQueueView)
end

local function playRandomStation()
  local n = playQueue and #playQueue or 0
  if n == 0 then
    return
  end
  local idx = math.random(1, n)
  if n > 1 and playQueue[idx].uuid == playingUuid then
    idx = idx % n + 1
  end
  playStation(playQueue[idx], playQueueView)
end

local function pinPlaying(list)
  if list == nil or playingUuid == nil then
    return
  end
  for i = 1, #list do
    if list[i].uuid == playingUuid then
      if i > 1 then
        local s = list[i]
        table.remove(list, i)
        table.insert(list, 1, s)
      end
      return
    end
  end
end

local function gotoPlayingStation()
  if playingUuid == nil then
    return
  end
  errorMessage = ""
  hoveredKey = nil
  revealNonce = revealNonce + 1
  if (playingUuid or ""):match("^custom%-") ~= nil then
    view = "custom"
    pinPlaying(customStations)
  elseif playQueueView == "country" and selectedCode ~= nil then
    view = "country"
    if stations == nil then
      stations = playQueue
      stationsDone = playQueueDone
      stationsOffset = playQueueOffset
    end
    stationQuery = ""
    stationQueryKey = stationQueryKey + 1
    pinPlaying(stations)
  elseif playQueueView == "genre" then
    view = "genre"
    if selectedGenre == nil then
      selectedGenre = chipForPlayingStation()
    end
    if genreStations == nil then
      genreStations = playQueue
      genreDone = playQueueDone
      genreOffset = playQueueOffset
    end
    genreQuery = ""
    genreQueryKey = genreQueryKey + 1
    pinPlaying(genreStations)
  elseif playQueueView == "search" then
    view = "search"
    if globalResults == nil then
      globalResults = playQueue
      globalDone = playQueueDone
      globalOffset = playQueueOffset
    end
    pinPlaying(globalResults)
  elseif playQueueView == "all_stations" then
    view = "all_stations"
    if allStations == nil then
      allStations = playQueue
      allDone = playQueueDone
      allOffset = playQueueOffset
    end
    pinPlaying(allStations)
  elseif playQueueView == "favorites" then
    view = "favorites"
    pinPlaying(favorites)
  elseif playQueueView == "custom" then
    view = "custom"
    pinPlaying(customStations)
  else
    return
  end
  render()
end

renderMiniPlayer = function()
  if playingUuid == nil then
    return nil
  end
  panel.setNeedsFrameTick(true)
  local thumb = thumbs[playingUuid]
  local parts = {}
  table.insert(parts, ui.glyph({ name = "volume-2", size = 11, color = "primary" }))
  if thumb ~= nil then
    table.insert(parts, ui.image({ path = thumb, width = 22, height = 22, radius = 4 }))
  end
  local now = noctalia.nowMs() / 1000
  local wave = (math.sin(now / 0.8 * math.pi) + 1) / 2
  local alpha = math.floor((0.20 + 0.80 * wave) * 255)
  local liveColor = LIVE_GREEN .. string.format("%02x", alpha)
  local nameColor = "on_surface"
  local infoParts = {}
  local stationLabel = playingName
  if #stationLabel > 35 then
    stationLabel = string.sub(stationLabel, 1, 35) .. "…"
  end
  local miniFlag = flagEmoji(playingStation ~= nil and playingStation.countrycode or nil)
  local nameRowParts = {}
  if miniFlag ~= "" then
    table.insert(nameRowParts, ui.label({ text = miniFlag, fontSize = 11 }))
  end
  table.insert(nameRowParts, ui.label({ text = stationLabel, fontSize = 11, maxLines = 1, maxWidth = 370, color = nameColor }))
  table.insert(nameRowParts, ui.glyph({ name = "access-point", size = 12, color = liveColor }))
  table.insert(infoParts, ui.row({ gap = 4, align = "center", minWidth = 0 }, nameRowParts))
  if currentSongTitle ~= "" then
    local MARQUEE_VIEW = 34
    local CHAR_PX = 4
    local MARQUEE_PAUSE = 2.5
    local len = #currentSongTitle
    local marqueeText = currentSongTitle
    local marqueePad = 0
    if len > MARQUEE_VIEW then
      local scrollT = len / MARQUEE_SPEED
      local cycle = scrollT + MARQUEE_PAUSE
      local t = now % cycle
      if t < scrollT then
        local progress = t * MARQUEE_SPEED
        local charIdx = math.floor(progress)
        local frac = progress - math.floor(progress)
        marqueePad = math.floor((1 - frac) * CHAR_PX)
        marqueeText = string.sub(currentSongTitle, charIdx + 1, math.min(charIdx + MARQUEE_VIEW, len))
      else
        marqueeText = string.sub(currentSongTitle, 1, math.min(MARQUEE_VIEW, len))
      end
    end
    table.insert(infoParts, ui.row({ align = "center", minWidth = 0, paddingH = marqueePad }, {
      ui.label({
        key      = "song-title-marquee",
        text     = marqueeText,
        fontSize = 10,
        maxLines = 1,
        maxWidth = 370,
        color    = "on_surface/0.65",
      }),
    }))
  end
  local infoCol = ui.column({ gap = 2, align = "start", flexGrow = 1, minWidth = 0 }, infoParts)
  table.insert(parts, infoCol)
  local hasQueue = (playQueue ~= nil and #playQueue > 1)
  table.insert(parts, ui.button({
    glyph       = "player-skip-back",
    variant     = "ghost",
    controlSize = "sm",
    tooltip     = tr("panel.prev_tooltip"),
    enabled     = hasQueue,
    onClick     = function() skipPlaying(-1) end,
  }))
  table.insert(parts, ui.button({
    glyph       = "dice",
    variant     = "ghost",
    controlSize = "sm",
    tooltip     = tr("panel.random_tooltip"),
    enabled     = hasQueue,
    onClick     = playRandomStation,
  }))
  table.insert(parts, ui.button({
    glyph       = "player-skip-forward",
    variant     = "ghost",
    controlSize = "sm",
    tooltip     = tr("panel.next_tooltip"),
    enabled     = hasQueue,
    onClick     = function() skipPlaying(1) end,
  }))
  local playingFaved = false
  if playingStation ~= nil then
    playingFaved = isFavorite(playingStation.uuid)
  end
  table.insert(parts, ui.button({
    glyph       = playingFaved and "star-filled" or "star",
    variant     = "ghost",
    controlSize = "sm",
    tooltip     = playingFaved and tr("panel.unfavorite_tooltip") or tr("panel.favorite_tooltip"),
    enabled     = (playingStation ~= nil),
    onClick     = function()
      if playingStation ~= nil then
        toggleFavorite(playingStation)
      end
    end,
  }))
  table.insert(parts, ui.button({
    glyph       = "playlist",
    variant     = "ghost",
    controlSize = "sm",
    tooltip     = tr("panel.goto_list_tooltip"),
    enabled     = (playQueue ~= nil),
    onClick     = gotoPlayingStation,
  }))
  table.insert(parts, ui.button({
    glyph       = "square",
    variant     = "primary",
    controlSize = "sm",
    tooltip     = tr("panel.stop_tooltip"),
    onClick     = stopPlayback,
  }))
  return ui.row({
    gap         = 6,
    align       = "center",
    paddingH    = 8,
    paddingV    = 6,
    radius      = 8,
    fill        = "primary/0.12",
    border      = "primary/0.25",
    borderWidth = 1,
  }, parts)
end

render = function()
  local children = {}

  local headerParts = {
    ui.glyph({ name = "radio", size = 18, color = "primary" }),
    ui.label({ text = tr("panel.title"), fontSize = 15, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
  }
  if view ~= "dashboard" then
    table.insert(headerParts, 2, ui.button({
      glyph       = "chevron-left",
      variant     = "ghost",
      controlSize = "md",
      tooltip     = tr("panel.back_tooltip"),
      onClick     = "onBack",
    }))
  end
  table.insert(headerParts, ui.button({
    glyph       = "search",
    variant     = "ghost",
    controlSize = "md",
    tooltip     = tr("panel.search_countries_placeholder"),
    onClick     = "onOpenCountrySearch",
  }))
  table.insert(headerParts, ui.button({
    glyph       = (#favorites > 0) and "star-filled" or "star",
    text        = (#favorites > 0) and tostring(#favorites) or nil,
    variant     = "outline",
    controlSize = "md",
    tooltip     = tr("panel.favorites_title"),
    onClick     = "onOpenFavorites",
  }))
  table.insert(headerParts, ui.button({
    glyph       = "broadcast",
    text        = (#customStations > 0) and tostring(#customStations) or nil,
    variant     = "outline",
    controlSize = "md",
    tooltip     = tr("panel.custom_title"),
    onClick     = openCustom,
  }))

  table.insert(children, ui.row({ gap = 6, align = "center" }, headerParts))
  table.insert(children, ui.separator({}))

  local body
  if view == "country" then
    body = renderCountry()
  elseif view == "genre" then
    body = renderGenre()
  elseif view == "favorites" then
    body = renderFavorites()
  elseif view == "custom" then
    body = renderCustom()
  elseif view == "add_custom" then
    body = renderAddCustom()
  elseif view == "search" then
    body = renderGlobalSearch()
  elseif view == "country_search" then
    body = renderCountrySearch()
  elseif view == "all_stations" then
    body = renderAllStations()
  elseif view == "all_countries" then
    body = renderAllCountries()
  else
    body = renderDashboard()
  end
  for _, el in ipairs(body) do
    table.insert(children, el)
  end

  local mini = renderMiniPlayer()
  if mini ~= nil then
    table.insert(children, ui.separator({}))
    table.insert(children, mini)
  end

  panel.render(ui.column({ key = "root-" .. view, gap = 8, padding = 12, flexGrow = 1, align = "stretch" }, children))
end

function onOpen(_context)
  restorePlayingState()
  local cachedCountries = readCachedJson("countries.json", COUNTRIES_CACHE_AGE)
  if cachedCountries ~= nil then
    countries = sanitizeCountries(cachedCountries)
  end
  local cachedStats = readCachedJson("stats.json", COUNTRIES_CACHE_AGE)
  if cachedStats ~= nil then
    stats = cachedStats
  end
  view = "dashboard"
  query = ""
  queryKey = queryKey + 1
  hoveredKey = nil
  beginStatsPulse()
  render()
  fetchCountries()
end

function onBack()
  if view == "add_custom" then
    customFormName = ""
    customFormUrl = ""
    customFormCover = ""
    customFormIndex = nil
    view = "custom"
  elseif view == "genre" then
    view = "dashboard"
    selectedGenre = nil
  elseif view == "search" then
    view = "dashboard"
    globalSearchNonce = globalSearchNonce + 1
    globalSearch = ""
    globalSearchKey = globalSearchKey + 1
    globalResults = nil
    globalOffset = 0
    globalDone = false
    globalErr = false
    globalLoading = false
  else
    view = "dashboard"
  end
  if view == "dashboard" then
    query = ""
    queryKey = queryKey + 1
    beginStatsPulse()
  end
  stations = nil
  genreStations = nil
  allStations = nil
  allOffset = 0
  allDone = false
  allErr = false
  allLoading = false
  allCountryShown = COUNTRIES_PAGE
  errorMessage = ""
  hoveredKey = nil
  render()
end

function onStop()
  stopPlayback()
end

function onOpenFavorites()
  view = "favorites"
  errorMessage = ""
  render()
end

function onSearchCountries(value)
  query = value or ""
  render()
end

function onStationSearch(value)
  stationQuery = value or ""
  render()
end

function onGenreSearch(value)
  genreQuery = value or ""
  render()
end

function onLoadMore()
  if stationsOffset > 0 then
    fetchStations(stationsOffset)
  end
end

function onOpenGlobalSearch()
  view = "search"
  errorMessage = ""
  globalSearch = ""
  globalSearchKey = globalSearchKey + 1
  globalResults = nil
  globalOffset = 0
  globalDone = false
  globalErr = false
  globalLoading = false
  globalSearchNonce = globalSearchNonce + 1
  render()
end

function onOpenCountrySearch()
  view = "country_search"
  errorMessage = ""
  query = ""
  queryKey = queryKey + 1
  render()
end

function onDashboardSearchRadio(value)
  view = "search"
  globalSearch = value or ""
  globalSearchKey = globalSearchKey + 1
  globalResults = nil
  globalOffset = 0
  globalDone = false
  globalErr = false
  globalLoading = false
  globalSearchNonce = globalSearchNonce + 1
  render()
  noctalia.runAsync(string.format("sleep %.3f", SEARCH_DEBOUNCE_MS / 1000), function()
    fetchGlobalSearch(0)
  end)
end

function onGlobalSearchChanged(value)
  globalSearch = value or ""
  local q = noctalia.string.trim(globalSearch)
  if #q < 2 then
    globalSearchNonce = globalSearchNonce + 1
    globalResults = nil
    globalOffset = 0
    globalDone = false
    globalErr = false
    globalLoading = false
    render()
    return
  end
  globalSearchNonce = globalSearchNonce + 1
  local nonce = globalSearchNonce
  render()
  noctalia.runAsync(string.format("sleep %.3f", SEARCH_DEBOUNCE_MS / 1000), function()
    if globalSearchNonce == nonce then
      fetchGlobalSearch(0)
    end
  end)
end

function onLoadMoreGlobal()
  if globalOffset > 0 then
    fetchGlobalSearch(globalOffset)
  end
end

function onLoadMoreGenre()
  if genreOffset > 0 then
    fetchGenreStations(genreOffset)
  end
end

function onLoadMoreAllStations()
  if allOffset > 0 then
    fetchAllStations(allOffset)
  end
end

function onFrameTick(_deltaMs)
  if playingUuid ~= nil then
    local nowMs = noctalia.nowMs()
    if nowMs - lastSongPoll >= SONG_POLL_INTERVAL then
      lastSongPoll = nowMs
      pollSongTitle()
    end
  end
  if favAnimUuid ~= nil then
    local elapsed = os.clock() * 1000 - favAnimStart
    if elapsed >= FAV_ANIM_MS then
      favAnimUuid = nil
    end
  end
  if pulseStart >= 0 and view ~= "dashboard" then
    pulseStart = -1
  end
  if favAnimUuid == nil and playingUuid == nil and pulseStart < 0 then
    panel.setNeedsFrameTick(false)
  end
  if favAnimUuid ~= nil or playingUuid ~= nil or pulseStart >= 0 then
    render()
  end
end

function onConfigChanged()
  render()
end
