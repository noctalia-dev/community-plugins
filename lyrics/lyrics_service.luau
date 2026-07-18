--!nonstrict
-- Lyrics — headless service.
-- Polls MPRIS metadata via playerctl, fetches lyrics from NetEase Cloud Music
-- via /api endpoints, publishes state. No polling delay.

local updateIntervalMs = 100
noctalia.setUpdateInterval(updateIntervalMs)

local cache = {}
local coverCache = {}
local lastTrackKey = ""
local inFlight = nil
local fetchGeneration = 0
local pollInFlight = false
local coverInFlight = nil
local pluginDir = noctalia.pluginDir() or "/tmp"
local cacheDir = pluginDir .. "/.cache"
noctalia.mkdirAll(cacheDir)
local requestDir = cacheDir .. "/requests"
noctalia.mkdirAll(requestDir)
local krcTmp = cacheDir .. "/krc.tmp"
local lyricsSource = noctalia.getConfig("lyrics_source") or "auto"
local lyricsSources = noctalia.getConfig("lyrics_sources") or {
  "lrclib", "netease", "qqmusic", "kugou", "qishui", "apple_music", "spotify", "musixmatch"
}
local customUrl = noctalia.getConfig("custom_url") or ""
local customJsonField = noctalia.getConfig("custom_json_field") or "syncedLyrics"
local pollIntervalMs = tonumber(noctalia.getConfig("poll_interval_ms")) or 500
local lyricsOffsetMs = tonumber(noctalia.getConfig("lyrics_offset_ms")) or 0
local displayMode = noctalia.getConfig("display_mode") or "toggle"
local credentialSignature = ""
local currentTrack = nil
local currentEmbeddedLyrics = ""
local currentPlayerInstance = ""
local currentArtUrl = ""

for _, name in ipairs(noctalia.listDir(requestDir) or {}) do
  if name:match("^source_request_.*%.json$") then noctalia.removeFile(requestDir .. "/" .. name) end
end

local function normalizePatterns(value)
  if type(value) ~= "table" then return {} end
  local patterns = {}
  for _, pattern in ipairs(value) do
    pattern = tostring(pattern):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if pattern ~= "" then patterns[#patterns + 1] = pattern end
  end
  table.sort(patterns)
  return patterns
end

local playerAllowlist = normalizePatterns(noctalia.getConfig("player_allowlist"))
local playerBlocklist = normalizePatterns(noctalia.getConfig("player_blocklist"))

local function trackKey(track)
  return (track.playerInstance or "") .. "|" .. track.title .. "|" .. track.artist .. "|" .. track.album
end

local function patternMatches(value, pattern)
  local luaPattern = "^" .. pattern:gsub("([%%%^%$%(%)%.%[%]%+%-%?])", "%%%1"):gsub("%*", ".*") .. "$"
  return value:lower():match(luaPattern) ~= nil
end

local function matchesAny(player, patterns)
  for _, pattern in ipairs(patterns) do
    if patternMatches(player.name, pattern) or patternMatches(player.instance, pattern) then return true end
  end
  return false
end

local function playerAllowed(player)
  if #playerAllowlist > 0 and not matchesAny(player, playerAllowlist) then return false end
  return not matchesAny(player, playerBlocklist)
end

local function selectPlayer(players)
  local best = nil
  local bestRank = -1
  for _, player in ipairs(players) do
    if playerAllowed(player) then
      local rank = player.status == "playing" and 2 or (player.status == "paused" and 1 or 0)
      if rank > bestRank or (rank == bestRank and player.instance == currentPlayerInstance) then
        best = player
        bestRank = rank
      end
    end
  end
  return best
end

local function clearPlayerState()
  fetchGeneration = fetchGeneration + 1
  currentPlayerInstance = ""
  currentTrack = nil
  currentEmbeddedLyrics = ""
  currentArtUrl = ""
  lastTrackKey = ""
  inFlight = nil
  coverInFlight = nil
  noctalia.state.set("player_instance", nil)
  noctalia.state.set("player_name", nil)
  noctalia.state.set("track", nil)
  noctalia.state.set("lyrics", nil)
  noctalia.state.set("cover", nil)
  noctalia.state.set("playing", false)
end

local function stableHash(value)
  local hash = 5381
  for index = 1, #value do hash = (hash * 33 + value:byte(index)) % 4294967296 end
  return string.format("%08x", hash)
end

local function coverPathFor(track, artUrl)
  return cacheDir .. "/cover_" .. stableHash(trackKey(track) .. "|" .. (artUrl or "")) .. ".jpg"
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function parseLRC(lrcText)
  local lines = {}
  for line in lrcText:gmatch("[^\n]+") do
    local mins, secs = line:match("%[(%d+):(%d+%.?%d*)%]")
    if mins and secs then
      local ms = math.floor(tonumber(mins) * 60000 + tonumber(secs) * 1000)
      local text = line:gsub("%[%d+:%d+%.?%d*%]", ""):gsub("^%s+", ""):gsub("%s+$", "")
      if text ~= "" then
        local isMeta = ms < 5000 and (text:find(":") or text:find("："))
        if not isMeta then
          lines[#lines + 1] = { time = ms, text = text }
        end
      end
    end
  end
  if #lines == 0 then return nil end
  return lines
end

local function parsePlain(text)
  local lines = {}
  local seenLyric = false
  for line in text:gmatch("[^\n]+") do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then
      if seenLyric then
        lines[#lines + 1] = { time = -1, text = trimmed }
      elseif trimmed:find(":") or trimmed:find("：") then
        -- skip metadata header line
      else
        seenLyric = true
        lines[#lines + 1] = { time = -1, text = trimmed }
      end
    end
  end
  if #lines == 0 then return nil end
  return lines
end

local function credentialsFor(source)
  if source == "spotify" then
    return {
      spotify_sp_dc = noctalia.getConfig("spotify_sp_dc") or "",
      spotify_access_token = noctalia.getConfig("spotify_access_token") or "",
    }
  elseif source == "apple_music" then
    return {
      apple_developer_token = noctalia.getConfig("apple_developer_token") or "",
      apple_user_token = noctalia.getConfig("apple_user_token") or "",
      apple_storefront = noctalia.getConfig("apple_storefront") or "us",
    }
  elseif source == "musixmatch" then
    return { musixmatch_token = noctalia.getConfig("musixmatch_token") or "" }
  elseif source == "qishui" then
    return {
      qishui_token = noctalia.getConfig("qishui_token") or "",
      qishui_api_url = noctalia.getConfig("qishui_api_url") or "",
    }
  end
  return {}
end

local function normalizedSources()
  if lyricsSource ~= "auto" then return { lyricsSource } end
  local result = {}
  local seen = {}
  if type(lyricsSources) == "table" then
    for _, source in ipairs(lyricsSources) do
      source = tostring(source):lower():gsub("^%s+", ""):gsub("%s+$", "")
      if source ~= "" and not seen[source] then
        result[#result + 1] = source
        seen[source] = true
      end
    end
  end
  if #result == 0 then result = { "lrclib", "netease" } end
  return result
end

local function evictCache()
  local keys = {}
  for k, _ in pairs(cache) do keys[#keys + 1] = k end
  if #keys > 30 then
    table.sort(keys)
    for i = 1, #keys - 30 do cache[keys[i]] = nil end
  end
end

local function fetchLyricsNetEase(track, embeddedLyrics)
  local tk = trackKey(track)
  fetchGeneration = fetchGeneration + 1
  local flight = tk .. "|" .. tostring(fetchGeneration)
  inFlight = flight

  local function tryFetch(query, fallback)
    local searchUrl = "https://music.163.com/api/search/get?type=1&s=" .. noctalia.string.urlEncode(query) .. "&limit=5"

    noctalia.http({ url = searchUrl, headers = { "Referer: https://music.163.com" } }, function(r1)
      if inFlight ~= flight then return end
      if tk ~= lastTrackKey then inFlight = nil; return end

      if not r1.ok or r1.status < 200 or r1.status >= 300 or not r1.body or #r1.body == 0 then
        if fallback then fallback()
        else inFlight = nil; noctalia.state.set("lyrics", nil) end
        return
      end

      local data = noctalia.json.decode(r1.body)
      if not data or not data.result or not data.result.songs or #data.result.songs == 0 then
        if fallback then fallback()
        else inFlight = nil; noctalia.state.set("lyrics", nil) end
        return
      end

      local function songArtist(s)
        if s.artists and #s.artists > 0 then
          return (s.artists[1].name or ""):lower()
        end
        return ""
      end

      local bestMatch = nil
      local trackArtist = track.artist:lower()
      for _, s in ipairs(data.result.songs) do
        if songArtist(s):find(trackArtist, 1, true) then
          bestMatch = s
          break
        end
      end
      if not bestMatch then
        bestMatch = data.result.songs[1]
      end

      local songId = tostring(bestMatch.id or "")
      if not songId:match("^%d+$") then
        if fallback then fallback()
        else inFlight = nil; noctalia.state.set("lyrics", nil) end
        return
      end
      local lyricUrl = "https://music.163.com/api/song/lyric?id=" .. noctalia.string.urlEncode(songId) .. "&lv=1&kv=1&tv=-1"

      noctalia.http({ url = lyricUrl, headers = { "Referer: https://music.163.com" } }, function(r2)
        if inFlight ~= flight then return end
        if tk ~= lastTrackKey then inFlight = nil; return end

    local lyrics = nil
    if r2.ok and r2.status >= 200 and r2.status < 300 and r2.body and #r2.body > 0 then
      local ldata = noctalia.json.decode(r2.body)
      local klyricStr = ""
      if ldata and ldata.klyric then
        local k = ldata.klyric
        if type(k) == "string" then
          klyricStr = k
        elseif type(k) == "table" then
          klyricStr = (k.lyric and type(k.lyric) == "string") and k.lyric or ""
        end
      end
      if klyricStr ~= "" then
        local ok = pcall(noctalia.writeFile, krcTmp, klyricStr)
        if not ok then klyricStr = "" end
      end
      if klyricStr ~= "" then
        local py = "python3 " .. shellQuote(pluginDir .. "/krc_decode.py") .. " " .. shellQuote(krcTmp)
        noctalia.runAsync(py, function(r3)
          if inFlight ~= flight then return end
          if tk ~= lastTrackKey then inFlight = nil; return end
          local ok, parsed = pcall(noctalia.json.decode, r3.stdout or "")
          if ok and parsed and parsed.type == "krc" and parsed.lines then
            cache[tk] = parsed.lines
            evictCache()
            inFlight = nil
            noctalia.state.set("lyrics", parsed.lines)
            return
          end
          local lrc = (ldata.lrc and ldata.lrc.lyric) or ""
          local lyr = parseLRC(lrc)
          if not lyr then lyr = parsePlain(lrc) end
          if lyr then
            cache[tk] = lyr
            evictCache()
            inFlight = nil
            noctalia.state.set("lyrics", lyr)
          elseif fallback then
            fallback()
          else
            inFlight = nil
            noctalia.state.set("lyrics", nil)
          end
        end)
        return
      end
      if ldata and ldata.lrc and ldata.lrc.lyric and ldata.lrc.lyric ~= "" then
        lyrics = parseLRC(ldata.lrc.lyric)
        if not lyrics then
          lyrics = parsePlain(ldata.lrc.lyric)
        end
      end
    end

    if lyrics then
      cache[tk] = lyrics
      evictCache()
      inFlight = nil
      noctalia.state.set("lyrics", lyrics)
    elseif fallback then
      fallback()
    else
      inFlight = nil
      noctalia.state.set("lyrics", nil)
    end
      end)
    end)
  end

  local query = track.title .. "\n" .. track.artist .. "\n" .. (track.album or "")
  local qTmp = cacheDir .. "/query.tmp"
  noctalia.writeFile(qTmp, query)
  local dir = noctalia.pluginDir() or "/tmp"

  local function applyParsed(parsed)
    if parsed and parsed.type == "krc" and parsed.lines then
      cache[tk] = parsed.lines
      evictCache()
      noctalia.state.set("lyrics", parsed.lines)
      return true
    end
    if parsed and parsed.type == "lrc" and parsed.lrc and parsed.lrc ~= "" then
      local lyr = parseLRC(parsed.lrc)
      if not lyr then lyr = parsePlain(parsed.lrc) end
      if lyr then
        cache[tk] = lyr
        evictCache()
        noctalia.state.set("lyrics", lyr)
        return true
      end
    end
    return false
  end

  local function runPy(script, cb)
    local py = "python3 " .. shellQuote(dir .. "/" .. script) .. " " .. shellQuote(qTmp)
    noctalia.runAsync(py, function(r)
      if inFlight ~= flight then return end
      if tk ~= lastTrackKey then inFlight = nil; return end
      local ok, parsed = pcall(noctalia.json.decode, r.stdout or "")
      cb(ok and parsed or nil)
    end)
  end

  local function applyText(text)
    if not text or text == "" then return false end
    local parsed = parseLRC(text)
    if not parsed then parsed = parsePlain(text) end
    if not parsed then return false end
    cache[tk] = parsed
    evictCache()
    noctalia.state.set("lyrics", parsed)
    return true
  end

  local function fetchCustom(fallback)
    if customUrl == "" then
      if fallback then fallback() else inFlight = nil; noctalia.state.set("lyrics", nil) end
      return
    end

    local replacements = {
      title = track.title,
      artist = track.artist,
      album = track.album,
      duration = tostring(math.floor((track.duration or 0) / 1000000)),
    }
    local url = customUrl:gsub("{([%w_]+)}", function(key)
      return noctalia.string.urlEncode(replacements[key] or "")
    end)

    noctalia.http({ url = url, headers = { "Accept: application/json, text/plain" } }, function(response)
      if inFlight ~= flight then return end
      if tk ~= lastTrackKey then inFlight = nil; return end
      local text = response.ok and response.body or ""
      if text ~= "" and customJsonField ~= "" then
        local decoded = noctalia.json.decode(text)
        for part in customJsonField:gmatch("[^.]+") do
          decoded = type(decoded) == "table" and decoded[part] or nil
        end
      if type(decoded) == "table" then
          cache[tk] = decoded
          evictCache()
          noctalia.state.set("lyrics", decoded)
          noctalia.state.set("lyrics_source_used", "custom")
          inFlight = nil
          return
        end
        text = type(decoded) == "string" and decoded or ""
      end
      if applyText(text) then
        noctalia.state.set("lyrics_source_used", "custom")
        inFlight = nil
      elseif fallback then
        fallback()
      else
        inFlight = nil
        noctalia.state.set("lyrics", nil)
      end
    end)
  end

  if lyricsSource == "external" then
    inFlight = nil
    return
  elseif lyricsSource == "mpris" then
    if applyText(embeddedLyrics) then noctalia.state.set("lyrics_source_used", "mpris") end
    inFlight = nil
    return
  elseif lyricsSource == "custom" then
    fetchCustom(nil)
    return
  end

  local requestPath = requestDir .. "/source_request_" .. tostring(fetchGeneration) .. ".json"
  local sources = normalizedSources()
  local request = {
    track = track,
    options = {
      translation_language = noctalia.getConfig("translation_language") or "zh-Hans",
    },
  }

  local function trySource(index)
    if inFlight ~= flight then return end
    local source = sources[index]
    if not source then
      inFlight = nil
      noctalia.state.set("lyrics", nil)
      noctalia.state.set("lyrics_source_used", nil)
      return
    end
    if source == "mpris" then
      if applyText(embeddedLyrics) then
        inFlight = nil
        noctalia.state.set("lyrics_source_used", "mpris")
      else
        trySource(index + 1)
      end
      return
    end
    if source == "custom" then
      fetchCustom(function() trySource(index + 1) end)
      return
    end
    request.source = source
    request.credentials = credentialsFor(source)
    local encoded = noctalia.json.encode(request)
    if not encoded then
      trySource(index + 1)
      return
    end

    -- Secure the containing directory before any credentials are written.
    local secured = noctalia.runAsync("chmod 700 " .. shellQuote(requestDir), function(chmodResult)
      if inFlight ~= flight or tk ~= lastTrackKey then return end
      if chmodResult.exitCode ~= 0 or not noctalia.writeFile(requestPath, encoded) then
        trySource(index + 1)
        return
      end

      local command = "python3 " .. shellQuote(pluginDir .. "/lyric_sources.py")
        .. " " .. shellQuote(requestPath)
      local started = noctalia.runAsync(command, function(result)
        noctalia.removeFile(requestPath)
        if inFlight ~= flight or tk ~= lastTrackKey then return end
        local parsed = noctalia.json.decode(result.stdout or "")
        if type(parsed) == "table" and parsed.type == "lyrics" and type(parsed.lines) == "table" and #parsed.lines > 0 then
          cache[tk] = parsed.lines
          evictCache()
          inFlight = nil
          noctalia.state.set("lyrics", parsed.lines)
          noctalia.state.set("lyrics_source_used", parsed.source or source)
        else
          trySource(index + 1)
        end
      end, 30000)
      if not started then
        noctalia.removeFile(requestPath)
        trySource(index + 1)
      end
    end, 5000)
    if not secured then
      trySource(index + 1)
    end
  end

  trySource(1)
end

local function fetchCover(track, artUrl)
  local tk = trackKey(track)
  local ck = tk .. "|" .. (artUrl or "")
  if coverInFlight == ck then return end
  coverInFlight = ck

  local dest = coverPathFor(track, artUrl)

  local apply = function(path)
    if coverInFlight ~= ck then return end
    coverInFlight = nil
    if tk ~= lastTrackKey then return end
    coverCache[ck] = path
    noctalia.state.set("cover", path)
  end

  if noctalia.fileExists(dest) then
    apply(dest)
    return
  end

  if not artUrl or artUrl == "" then
    noctalia.state.set("cover", nil)
    coverInFlight = nil
    return
  end

  if artUrl:sub(1, 7) == "file://" then
    local source = noctalia.string.urlDecode(artUrl:sub(8))
    if not noctalia.fileExists(source) then
      apply(nil)
      return
    end
    noctalia.runAsync("cp -- " .. shellQuote(source) .. " " .. shellQuote(dest), function(result)
      if result.exitCode == 0 then apply(dest) else apply(source) end
    end)
    return
  end

  local downloadUrl = artUrl
  local fallbackUrl = nil
  if artUrl:find("music%.126%.net", 1) then
    downloadUrl = artUrl:gsub("https?://p%d+%.music%.126%.net", "https://p1.music.126.net")
    if downloadUrl:find("[?&]param=%d+y%d+") then
      downloadUrl = downloadUrl:gsub("param=%d+y%d+", "param=400y400")
    else
      downloadUrl = downloadUrl .. (downloadUrl:find("?", 1, true) and "&" or "?") .. "param=400y400"
    end
    fallbackUrl = downloadUrl:gsub("https://p1%.music%.126%.net", "https://p3.music.126.net")
  end

  noctalia.download(downloadUrl, dest, function(ok)
    if ok then
      apply(dest)
    elseif fallbackUrl then
      noctalia.download(fallbackUrl, dest, function(fallbackOk)
        if fallbackOk then apply(dest) else apply(nil) end
      end)
    else
      apply(nil)
    end
  end)
end

local function poll()
  if pollInFlight then return end
  pollInFlight = true
  local cmd = [[playerctl --all-players metadata --format $'{{playerInstance}}\x1f{{playerName}}\x1f{{lc(status)}}\x1f{{title}}\x1f{{artist}}\x1f{{album}}\x1f{{position}}\x1f{{mpris:length}}\x1f{{mpris:artUrl}}\x1f{{xesam:asText}}\x1e' 2>/dev/null]]

  local started = noctalia.runAsync(cmd, function(r)
    pollInFlight = false
    if r.exitCode ~= 0 or not r.stdout or r.stdout == "" then
      clearPlayerState()
      return
    end

    local players = {}
    local fieldSeparator = string.char(31)
    local recordSeparator = string.char(30)
    for record in (r.stdout .. recordSeparator):gmatch("(.-)" .. recordSeparator) do
      if record ~= "" then
        local parts = {}
        for field in (record .. fieldSeparator):gmatch("(.-)" .. fieldSeparator) do
          parts[#parts + 1] = field:gsub("^%s+", ""):gsub("%s+$", "")
        end
        local player = {
          instance = parts[1] or "",
          name = parts[2] or "",
          status = parts[3] or "stopped",
          title = parts[4] or "",
          artist = parts[5] or "",
          album = parts[6] or "",
          position = tonumber(parts[7]) or 0,
          duration = tonumber(parts[8]) or 0,
          artUrl = parts[9] or "",
          embeddedLyrics = parts[10] or "",
        }
        if player.instance ~= "" or player.name ~= "" then players[#players + 1] = player end
      end
    end

    local selected = selectPlayer(players)
    if not selected then
      clearPlayerState()
      return
    end

    currentPlayerInstance = selected.instance
    noctalia.state.set("player_instance", selected.instance)
    noctalia.state.set("player_name", selected.name)

    if selected.title == "" and selected.artist == "" then
      noctalia.state.set("track", nil)
      noctalia.state.set("lyrics", nil)
      noctalia.state.set("playing", selected.status == "playing")
      return
    end

    local playing = selected.status == "playing"
    local t = {
      title = selected.title,
      artist = selected.artist,
      album = selected.album,
      status = selected.status,
      position = selected.position,
      duration = selected.duration,
      playerInstance = selected.instance,
    }
    local tk = trackKey(t)
    currentTrack = t
    currentEmbeddedLyrics = selected.embeddedLyrics
    local previousArtUrl = currentArtUrl
    currentArtUrl = selected.artUrl

    noctalia.state.set("position", t.position + lyricsOffsetMs * 1000)

    if tk ~= lastTrackKey then
      lastTrackKey = tk
      noctalia.state.set("track", t)
      noctalia.state.set("playing", playing)

      local cached = cache[tk]
      if displayMode == "track" then
        noctalia.state.set("lyrics", nil)
        noctalia.state.set("lyrics_source_used", nil)
      elseif cached then
        noctalia.state.set("lyrics", cached)
        noctalia.state.set("lyrics_source_used", "cache")
      else
        noctalia.state.set("lyrics", nil)
        fetchLyricsNetEase(t, selected.embeddedLyrics)
      end

      local coverKey = tk .. "|" .. selected.artUrl
      local cachedCover = coverCache[coverKey]
      if cachedCover then
        noctalia.state.set("cover", cachedCover)
      else
        noctalia.state.set("cover", nil)
        fetchCover(t, selected.artUrl)
      end
    else
      noctalia.state.set("track", t)
      noctalia.state.set("playing", playing)
      if selected.artUrl ~= previousArtUrl then
        noctalia.state.set("cover", nil)
        fetchCover(t, selected.artUrl)
      end
    end
  end)
  if not started then pollInFlight = false end
end

local pollElapsedMs = pollIntervalMs

function update()
  if lyricsSource == "external" then return end
  pollElapsedMs = pollElapsedMs + updateIntervalMs
  if pollElapsedMs >= pollIntervalMs then
    pollElapsedMs = 0
    poll()
  end

end

function onConfigChanged()
  local nextSource = noctalia.getConfig("lyrics_source") or "auto"
  local nextUrl = noctalia.getConfig("custom_url") or ""
  local nextField = noctalia.getConfig("custom_json_field") or "syncedLyrics"
  local nextSources = noctalia.getConfig("lyrics_sources") or lyricsSources
  local nextPollInterval = tonumber(noctalia.getConfig("poll_interval_ms")) or 500
  local nextOffset = tonumber(noctalia.getConfig("lyrics_offset_ms")) or 0
  local nextDisplayMode = noctalia.getConfig("display_mode") or "toggle"
  local nextCredentialSignature = table.concat({
    noctalia.getConfig("spotify_sp_dc") or "",
    noctalia.getConfig("spotify_access_token") or "",
    noctalia.getConfig("apple_developer_token") or "",
    noctalia.getConfig("apple_user_token") or "",
    noctalia.getConfig("apple_storefront") or "us",
    noctalia.getConfig("musixmatch_token") or "",
    noctalia.getConfig("qishui_token") or "",
    noctalia.getConfig("qishui_api_url") or "",
    noctalia.getConfig("translation_language") or "zh-Hans",
  }, "\0")
  local nextAllowlist = normalizePatterns(noctalia.getConfig("player_allowlist"))
  local nextBlocklist = normalizePatterns(noctalia.getConfig("player_blocklist"))
  local sourceChanged = nextSource ~= lyricsSource or nextUrl ~= customUrl or nextField ~= customJsonField
    or table.concat(nextSources, "\n") ~= table.concat(lyricsSources, "\n")
    or nextCredentialSignature ~= credentialSignature
    or nextDisplayMode ~= displayMode
  local playersChanged = table.concat(nextAllowlist, "\n") ~= table.concat(playerAllowlist, "\n")
    or table.concat(nextBlocklist, "\n") ~= table.concat(playerBlocklist, "\n")
  lyricsSource = nextSource
  customUrl = nextUrl
  customJsonField = nextField
  lyricsSources = nextSources
  pollIntervalMs = math.max(100, nextPollInterval)
  lyricsOffsetMs = nextOffset
  displayMode = nextDisplayMode
  credentialSignature = nextCredentialSignature
  playerAllowlist = nextAllowlist
  playerBlocklist = nextBlocklist
  if playersChanged then
    currentPlayerInstance = ""
    fetchGeneration = fetchGeneration + 1
    inFlight = nil
    poll()
  end
  if sourceChanged and currentTrack and not playersChanged then
    fetchGeneration = fetchGeneration + 1
    inFlight = nil
    cache = {}
    noctalia.state.set("lyrics", nil)
    if displayMode ~= "track" then fetchLyricsNetEase(currentTrack, currentEmbeddedLyrics) end
  end
end

local function applyPushedLyrics(payload)
  local decoded = noctalia.json.decode(payload or "")
  if type(decoded) == "table" then
    if decoded.track then
      currentTrack = decoded.track
      lastTrackKey = trackKey({
        playerInstance = decoded.track.playerInstance or "",
        title = decoded.track.title or "",
        artist = decoded.track.artist or "",
        album = decoded.track.album or "",
      })
      noctalia.state.set("track", decoded.track)
    end
    if decoded.lines then noctalia.state.set("lyrics", decoded.lines) end
    if decoded.lyrics then
      local parsed = parseLRC(decoded.lyrics) or parsePlain(decoded.lyrics)
      noctalia.state.set("lyrics", parsed)
    end
    if decoded.position ~= nil then noctalia.state.set("position", decoded.position + lyricsOffsetMs * 1000) end
    if decoded.playing ~= nil then noctalia.state.set("playing", decoded.playing == true) end
    if decoded.cover ~= nil then noctalia.state.set("cover", decoded.cover) end
    return true
  end
  return false
end

function onIpc(event, payload)
  if event == "push-lrc" then
    noctalia.state.set("lyrics", parseLRC(payload or "") or parsePlain(payload or ""))
  elseif event == "push-json" or event == "push-state" then
    applyPushedLyrics(payload)
  elseif event == "clear" then
    noctalia.state.set("lyrics", nil)
  end
end

if lyricsSource ~= "external" then poll() end
