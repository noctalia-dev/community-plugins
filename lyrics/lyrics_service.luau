--!nonstrict
-- Lyrics — headless service.
-- Polls MPRIS metadata via playerctl, fetches lyrics from NetEase Cloud Music
-- via /api endpoints, publishes state. No polling delay.

local updateIntervalMs = 100
noctalia.setUpdateInterval(updateIntervalMs)

local cache = {}
local coverCache = {}
local sourceCoverCache = {}
local lastTrackKey = ""
local inFlight = nil
local fetchGeneration = 0
local pollInFlight = false
local coverInFlight = nil
local coverFetchGeneration = 0
local maxCoverFiles = 80
local pluginDir = noctalia.pluginDir() or "/tmp"
local cacheDir = pluginDir .. "/.cache"
noctalia.mkdirAll(cacheDir)
local requestDir = cacheDir .. "/requests"
noctalia.mkdirAll(requestDir)
local krcTmp = cacheDir .. "/krc.tmp"
local lyricsSource = noctalia.getConfig("lyrics_source") or "auto"
local lyricsSources = noctalia.getConfig("lyrics_sources") or {
  "lrclib", "netease", "splayer", "qqmusic", "kugou", "qishui", "apple_music", "spotify", "musixmatch"
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
local currentCoverUrl = ""
local pendingSourceCoverUrl = ""
local mprisCoverFailed = false
local maybeApplyCover

for _, name in ipairs(noctalia.listDir(requestDir) or {}) do
  if name:match("^source_request_.*%.json$") then noctalia.removeFile(requestDir .. "/" .. name) end
end

local pruneCoverCache

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
  return (track.playerInstance or "") .. "|" .. (track.trackId or "") .. "|"
    .. track.title .. "|" .. track.artist .. "|" .. track.album
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
  coverFetchGeneration = coverFetchGeneration + 1
  currentPlayerInstance = ""
  currentTrack = nil
  currentEmbeddedLyrics = ""
  currentArtUrl = ""
  currentCoverUrl = ""
  pendingSourceCoverUrl = ""
  mprisCoverFailed = false
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

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function coverStem(track, artUrl)
  return "cover_" .. stableHash(trackKey(track) .. "|" .. (artUrl or ""))
end

local function coverExtensionFromUrl(artUrl)
  local path = tostring(artUrl or ""):match("^[^?#]+") or ""
  local ext = path:match("%.([A-Za-z0-9]+)$")
  if not ext then return "" end
  ext = ext:lower()
  if ext == "jpeg" then return "jpg" end
  if ext == "jpg" or ext == "png" or ext == "webp" or ext == "gif" or ext == "bmp" then return ext end
  return ""
end

local function coverExtensionFromFile(path)
  local contents = noctalia.readFile(path)
  local header = contents and contents:sub(1, 16) or ""
  if header:sub(1, 3) == "\255\216\255" then return "jpg" end
  if header:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
  if header:sub(1, 4) == "RIFF" and header:sub(9, 12) == "WEBP" then return "webp" end
  if header:sub(1, 6) == "GIF87a" or header:sub(1, 6) == "GIF89a" then return "gif" end
  if header:sub(1, 2) == "BM" then return "bmp" end
  return ""
end

local function findCachedCover(track, artUrl)
  local stem = coverStem(track, artUrl)
  local function correctedPath(path)
    if not noctalia.fileExists(path) then return nil end
    local actualExtension = coverExtensionFromFile(path)
    local storedExtension = path:match("%.([^.]+)$")
    if actualExtension == "" or actualExtension == storedExtension then return path end
    local corrected = path:gsub("%.[^.]+$", "." .. actualExtension)
    if noctalia.fileExists(corrected) then
      noctalia.removeFile(path)
      return corrected
    end
    local renamed = noctalia.renameFile(path, corrected)
    return renamed and corrected or path
  end
  local preferred = coverExtensionFromUrl(artUrl)
  if preferred ~= "" then
    local path = cacheDir .. "/" .. stem .. "." .. preferred
    local corrected = correctedPath(path)
    if corrected then return corrected end
  end
  for _, ext in ipairs({ "jpg", "png", "webp", "gif", "bmp" }) do
    local path = cacheDir .. "/" .. stem .. "." .. ext
    local corrected = correctedPath(path)
    if corrected then return corrected end
  end
  return nil
end

local function coverPathFor(track, artUrl, ext)
  local extension = ext or coverExtensionFromUrl(artUrl)
  if extension == "" then extension = "jpg" end
  return cacheDir .. "/" .. coverStem(track, artUrl) .. "." .. extension
end

pruneCoverCache = function()
  local names = noctalia.listDir(cacheDir) or {}
  local files = {}
  for _, name in ipairs(names) do
    if name:match("^cover_.+%.%w+$") then
      local path = cacheDir .. "/" .. name
      local info = noctalia.fileInfo(path)
      files[#files + 1] = { path = path, mtime = info and info.mtime or 0 }
    end
  end
  if #files > maxCoverFiles then
    table.sort(files, function(a, b) return a.mtime < b.mtime end)
    for index = 1, #files - maxCoverFiles do
      noctalia.removeFile(files[index].path)
      files[index].removed = true
    end
  end
  local keep = {}
  for key, path in pairs(coverCache) do
    if type(path) == "string" and noctalia.fileExists(path) then
      keep[key] = path
    end
  end
  coverCache = keep
end

pruneCoverCache()

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
  elseif source == "splayer" then
    return { splayer_api_url = noctalia.getConfig("splayer_api_url") or "http://127.0.0.1:25884" }
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
    for i = 1, #keys - 30 do
      cache[keys[i]] = nil
      sourceCoverCache[keys[i]] = nil
    end
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
          if type(parsed.cover) == "string" and parsed.cover ~= "" then
            sourceCoverCache[tk] = parsed.cover
            maybeApplyCover(track, parsed.cover)
          end
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

local function finalizeCoverFile(tempPath, track, artUrl)
  if not tempPath or tempPath == "" or not noctalia.fileExists(tempPath) then return nil end
  local ext = coverExtensionFromFile(tempPath)
  if ext == "" then
    noctalia.removeFile(tempPath)
    return nil
  end
  local dest = coverPathFor(track, artUrl, ext)
  if tempPath == dest then return dest end
  noctalia.removeFile(dest)
  local ok = noctalia.renameFile(tempPath, dest)
  if ok or noctalia.fileExists(dest) then return dest end
  if noctalia.fileExists(tempPath) then return tempPath end
  return nil
end

local function fetchCover(track, artUrl)
  local tk = trackKey(track)
  local url = tostring(artUrl or "")
  if url == "" then return end
  local ck = tk .. "|" .. url
  if coverInFlight == ck then return end
  if coverCache[ck] and noctalia.fileExists(coverCache[ck]) then
    if tk == lastTrackKey then
      currentCoverUrl = url
      noctalia.state.set("cover", coverCache[ck])
    end
    return
  end
  local cached = findCachedCover(track, url)
  if cached then
    coverCache[ck] = cached
    if tk == lastTrackKey then
      currentCoverUrl = url
      noctalia.state.set("cover", cached)
    end
    return
  end

  coverFetchGeneration = coverFetchGeneration + 1
  local generation = coverFetchGeneration
  coverInFlight = ck

  local apply = function(path)
    if coverInFlight ~= ck or generation ~= coverFetchGeneration then return end
    coverInFlight = nil
    if tk ~= lastTrackKey then return end
    if path then
      coverCache[ck] = path
      currentCoverUrl = url
      if url == currentArtUrl then
        mprisCoverFailed = false
        pendingSourceCoverUrl = ""
      end
      noctalia.state.set("cover", path)
      pruneCoverCache()
    elseif url == currentArtUrl then
      mprisCoverFailed = true
      local fallbackUrl = pendingSourceCoverUrl
      pendingSourceCoverUrl = ""
      if fallbackUrl ~= "" then fetchCover(track, fallbackUrl) end
    end
  end

  if url:sub(1, 7) == "file://" then
    local source = noctalia.string.urlDecode(url:sub(8))
    if not noctalia.fileExists(source) then
      apply(nil)
      return
    end
    local ext = coverExtensionFromUrl(source)
    if ext == "" then ext = coverExtensionFromFile(source) end
    local dest = coverPathFor(track, url, ext ~= "" and ext or "img")
    noctalia.runAsync("cp -- " .. shellQuote(source) .. " " .. shellQuote(dest), function(result)
      if generation ~= coverFetchGeneration then return end
      if result.exitCode == 0 then
        apply(finalizeCoverFile(dest, track, url) or dest)
      else
        apply(source)
      end
    end)
    return
  end

  local downloadUrl = url
  local fallbackUrl = nil
  if url:find("music%.126%.net", 1) then
    downloadUrl = url:gsub("https?://p%d+%.music%.126%.net", "https://p1.music.126.net")
    if downloadUrl:find("[?&]param=%d+y%d+") then
      downloadUrl = downloadUrl:gsub("param=%d+y%d+", "param=400y400")
    else
      downloadUrl = downloadUrl .. (downloadUrl:find("?", 1, true) and "&" or "?") .. "param=400y400"
    end
    fallbackUrl = downloadUrl:gsub("https://p1%.music%.126%.net", "https://p3.music.126.net")
  end

  local tempDest = coverPathFor(track, url, coverExtensionFromUrl(url) ~= "" and coverExtensionFromUrl(url) or "img")
  noctalia.download(downloadUrl, tempDest, function(ok)
    if generation ~= coverFetchGeneration then return end
    if ok then
      apply(finalizeCoverFile(tempDest, track, url))
    elseif fallbackUrl then
      noctalia.download(fallbackUrl, tempDest, function(fallbackOk)
        if generation ~= coverFetchGeneration then return end
        if fallbackOk then apply(finalizeCoverFile(tempDest, track, url)) else apply(nil) end
      end)
    else
      apply(nil)
    end
  end)
end

maybeApplyCover = function(track, artUrl)
  if not track or not artUrl or artUrl == "" then return end
  if currentCoverUrl ~= "" and currentCoverUrl == artUrl then return end
  if currentArtUrl ~= "" and not mprisCoverFailed then
    pendingSourceCoverUrl = artUrl
    return
  end
  fetchCover(track, artUrl)
end

local function poll()
  if pollInFlight then return end
  pollInFlight = true
  local cmd = [[playerctl --all-players metadata --format $'{{playerInstance}}\x1f{{playerName}}\x1f{{lc(status)}}\x1f{{title}}\x1f{{artist}}\x1f{{album}}\x1f{{position}}\x1f{{mpris:length}}\x1f{{mpris:artUrl}}\x1f{{mpris:trackid}}\x1f{{xesam:url}}\x1f{{xesam:asText}}\x1e' 2>/dev/null]]

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
          trackId = parts[10] or "",
          mediaUrl = parts[11] or "",
          embeddedLyrics = parts[12] or "",
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
      trackId = selected.trackId,
      mediaUrl = selected.mediaUrl,
    }
    local tk = trackKey(t)
    currentTrack = t
    currentEmbeddedLyrics = selected.embeddedLyrics
    local previousArtUrl = currentArtUrl
    currentArtUrl = selected.artUrl

    noctalia.state.set("position", t.position + lyricsOffsetMs * 1000)

    if tk ~= lastTrackKey then
      lastTrackKey = tk
      currentCoverUrl = ""
      pendingSourceCoverUrl = ""
      mprisCoverFailed = false
      coverFetchGeneration = coverFetchGeneration + 1
      coverInFlight = nil
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

      noctalia.state.set("cover", nil)
      if selected.artUrl ~= "" then
        pendingSourceCoverUrl = sourceCoverCache[tk] or ""
        fetchCover(t, selected.artUrl)
      elseif sourceCoverCache[tk] then
        maybeApplyCover(t, sourceCoverCache[tk])
      end
    else
      noctalia.state.set("track", t)
      noctalia.state.set("playing", playing)
      if selected.artUrl ~= previousArtUrl and selected.artUrl ~= "" then
        mprisCoverFailed = false
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
    noctalia.getConfig("splayer_api_url") or "http://127.0.0.1:25884",
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
    sourceCoverCache = {}
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
        trackId = decoded.track.trackId or "",
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
    if type(decoded.cover) == "string" and decoded.cover ~= "" then
      if decoded.cover:sub(1, 1) == "/" or decoded.cover:sub(1, 7) == "file://" then
        currentCoverUrl = decoded.cover
        noctalia.state.set("cover", decoded.cover:gsub("^file://", ""))
      else
        maybeApplyCover(currentTrack, decoded.cover)
      end
    end
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
