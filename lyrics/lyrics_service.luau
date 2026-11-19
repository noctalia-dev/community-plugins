--!nonstrict
-- Lyrics — headless service.
-- Polls MPRIS metadata via playerctl, fetches lyrics from bounded sources,
-- and publishes state.

local updateIntervalMs = 100
noctalia.setUpdateInterval(updateIntervalMs)

local cache = {}
local coverCache = {}
local sourceCoverCache = {}
local candidateCache = {}
local selectedCandidateCache = {}
local selectedCandidateSourceCache = {}
local appliedFormatCache = {}
local appliedSyncCache = {}
local lastTrackKey = ""
local inFlight = nil
local lyricsLoading = false
local retryRemainingMs = 0
local retryFailures = 0
local retryTrackKey = ""
local emptyPollCount = 0
local emptyTrackCount = 0
noctalia.state.set("lyrics_loading", false)
local fetchGeneration = 0
local pollInFlight = false
local coverInFlight = nil
local coverFetchGeneration = 0
local maxCoverFiles = 80
local pluginDir = noctalia.pluginDir() or "/tmp"
local dataDir = assert(noctalia.pluginDataDir())
local cacheDir = dataDir .. "/cache"
noctalia.mkdirAll(cacheDir)
local offsetPath = dataDir .. "/lyrics-offsets.json"
local trackOffsets = {}
local savedOffsets = noctalia.readFile(offsetPath)
if savedOffsets then
  local decodedOffsets = noctalia.json.decode(savedOffsets)
  if type(decodedOffsets) == "table" then
    for key, value in pairs(decodedOffsets) do
      local offset = tonumber(value)
      if type(key) == "string" and offset and offset == offset and math.abs(offset) <= 2147483647 then
        trackOffsets[key] = math.floor(offset)
      end
    end
  end
end
local requestDir = cacheDir .. "/requests"
noctalia.mkdirAll(requestDir)
local krcTmp = cacheDir .. "/krc.tmp"
local lyricsSource = noctalia.getConfig("lyrics_source") or "auto"
local lyricsSources = noctalia.getConfig("lyrics_sources") or {
  "splayer_next", "netease", "lrclib", "splayer", "qqmusic", "kugou", "qishui", "apple_music", "spotify"
}
local candidateMode = noctalia.getConfig("candidate_mode") or "choose"

local formatPriority = {}
local sourceFormatPriority = {}
local autoSourceRouting = true
local customUrl = noctalia.getConfig("custom_url") or ""
local customJsonField = noctalia.getConfig("custom_json_field") or "syncedLyrics"
local pollIntervalMs = tonumber(noctalia.getConfig("poll_interval_ms")) or 500
local lyricsOffsetMs = tonumber(noctalia.getConfig("lyrics_offset_ms")) or 0
local currentLyricsOffsetMs = 0
local lyricsStatus = "idle"
noctalia.state.set("lyrics_status", lyricsStatus)
noctalia.state.set("lyrics_offset_ms", currentLyricsOffsetMs)
local credentialSignature = ""
local offlineMode = noctalia.getSetting("shell.offline_mode") == true
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
  local durationSeconds = math.floor((tonumber(track.duration) or 0) / 1000000)
  return (track.playerInstance or "") .. "|" .. (track.trackId or "") .. "|"
    .. (track.title or "") .. "|" .. (track.artist or "") .. "|" .. (track.album or "")
    .. "|" .. tostring(durationSeconds)
end

local function trackOffsetKey(track)
  if type(track) ~= "table" then return "" end
  local durationSeconds = math.floor((tonumber(track.duration) or 0) / 1000000)
  local url = tostring(track.mediaUrl or "")
  if url ~= "" then return "url|" .. url end
  -- Some MPRIS players assign a new track ID for every playback.
  return noctalia.json.encode({ tostring(track.title or ""), tostring(track.artist or ""),
    tostring(track.album or ""), durationSeconds }) or ""
end

local function setLyricsStatus(status)
  if status ~= "ready" and status ~= "loading" and status ~= "not_found"
    and status ~= "error" and status ~= "dependency_missing" and status ~= "waiting" and status ~= "offline" then
    status = "idle"
  end
  if lyricsStatus ~= status then
    lyricsStatus = status
    noctalia.state.set("lyrics_status", status)
  end
end

local function publishLyrics(lines)
  noctalia.state.set("lyrics", lines)
  if type(lines) == "table" and #lines > 0 then setLyricsStatus("ready") end
end

local function persistTrackOffsets()
  local encoded = noctalia.json.encode(trackOffsets)
  if encoded then noctalia.writeFile(offsetPath, encoded) end
end

local function setCurrentTrackOffset(track)
  currentLyricsOffsetMs = trackOffsets[trackOffsetKey(track)] or 0
  noctalia.state.set("lyrics_offset_ms", currentLyricsOffsetMs)
end

local function saveTrackOffset(tk, offset)
  if not tk or tk == "" or not currentTrack then return false end
  offset = math.floor(tonumber(offset) or 0)
  offset = math.max(-600000, math.min(600000, offset))
  local key = trackOffsetKey(currentTrack)
  if offset == 0 then trackOffsets[key] = nil else trackOffsets[key] = offset end
  persistTrackOffsets()
  if tk == lastTrackKey then
    currentLyricsOffsetMs = offset
    noctalia.state.set("lyrics_offset_ms", currentLyricsOffsetMs)
    noctalia.state.set("position", (tonumber(currentTrack.position) or 0)
      + (lyricsOffsetMs + currentLyricsOffsetMs) * 1000)
  end
  return true
end

local function publishCandidates(tk, loading, selectionError, pendingCandidateId)
  noctalia.state.set("lyrics_candidate_state", {
    track_key = tk or "",
    candidates = candidateCache[tk] or {},
    selected_id = selectedCandidateCache[tk],
    selected_source = selectedCandidateSourceCache[tk] or "",
    applied_format = appliedFormatCache[tk] or "",
    applied_sync = appliedSyncCache[tk] or "",
    loading = loading == true,
    error = selectionError,
    pending_id = pendingCandidateId,
  })
end

local function setLyricsLoading(value)
  if lyricsLoading == value then
    if value then setLyricsStatus("loading") end
    return
  end
  lyricsLoading = value
  noctalia.state.set("lyrics_loading", value)
  if value then setLyricsStatus("loading") end
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
  retryRemainingMs = 0
  retryFailures = 0
  retryTrackKey = ""
  emptyPollCount = 0
  emptyTrackCount = 0
  setLyricsLoading(false)
  setLyricsStatus("idle")
  setCurrentTrackOffset(nil)
  coverInFlight = nil
  noctalia.state.set("player_instance", nil)
  noctalia.state.set("player_name", nil)
  noctalia.state.set("track", nil)
  noctalia.state.set("lyrics", nil)
  publishCandidates("")
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
  elseif source == "splayer_next" then
    return { splayer_next_api_url = noctalia.getConfig("splayer_next_api_url") or "http://127.0.0.1:14558" }
  end
  return {}
end

local function canonicalSource(source)
  if source == "splayer-next" or source == "splayer next" then return "splayer_next" end
  return source
end

-- Explicitly saved source lists are authoritative; routing may only reorder them.
local function normalizedSources()
  if lyricsSource ~= "auto" then return { canonicalSource(lyricsSource) } end
  local result = {}
  local seen = {}
  if type(lyricsSources) == "table" then
    for _, source in ipairs(lyricsSources) do
      source = canonicalSource(tostring(source):lower():gsub("^%s+", ""):gsub("%s+$", ""))
      if source ~= "" and not seen[source] then
        result[#result + 1] = source
        seen[source] = true
      end
    end
  end
  return result
end

local function needsEmbeddedLyrics()
  if lyricsSource == "mpris" then return true end
  if lyricsSource ~= "auto" then return false end
  for _, source in ipairs(normalizedSources()) do
    if source == "mpris" then return true end
  end
  return false
end

local function normalizeFormatPriority(value)
  local result = {}
  if type(value) ~= "table" then return result end
  local seen = {}
  for _, raw in ipairs(value) do
    local name = tostring(raw):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if name ~= "" and not seen[name] then
      seen[name] = true
      result[#result + 1] = name
    end
  end
  return result
end

local function normalizeSourceFormatPriority(value)
  local result = {}
  if type(value) ~= "table" then return result end
  for _, raw in ipairs(value) do
    local source, formats = tostring(raw):match("^%s*([%w_%-]+)%s*=%s*(.+)$")
    if source and formats then
      local list = {}
      for name in formats:gmatch("[^,%s]+") do
        name = name:lower()
        if name ~= "" then list[#list + 1] = name end
      end
      if #list > 0 then result[source:lower()] = list end
    end
  end
  return result
end

local function listSignature(value)
  return type(value) == "table" and table.concat(value, ",") or ""
end

local function mapSignature(value)
  if type(value) ~= "table" then return "" end
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = tostring(key) end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = key .. "=" .. listSignature(value[key])
  end
  return table.concat(parts, ";")
end

-- Map the player or media URL to the source that can actually provide
-- word-level lyrics for it. This only reorders requests; it never adds one.
local function preferredSource(track)
  if not autoSourceRouting or lyricsSource ~= "auto" or type(track) ~= "table" then return nil end
  local url = tostring(track.mediaUrl or ""):lower()
  local player = (tostring(track.playerName or "") .. " " .. tostring(track.playerInstance or "")):lower()
  if url:find("music.163.com", 1, true) or url:find("orpheus://", 1, true)
    or player:find("netease", 1, true) or player:find("网易云", 1, true) then
    return "netease"
  end
  if url:find("y.qq.com", 1, true) or url:find("qqmusic", 1, true)
    or player:find("qqmusic", 1, true) or player:find("qq音乐", 1, true) then
    return "qqmusic"
  end
  if url:find("kugou", 1, true) or player:find("kugou", 1, true)
    or player:find("酷狗", 1, true) or player:find("moekoe", 1, true) then
    return "kugou"
  end
  if player:find("splayer-next", 1, true) or player:find("splayer next", 1, true)
    or player:find("splayer_next", 1, true) then
    return "splayer_next"
  end
  if player:find("splayer", 1, true) then return "splayer" end
  if player:find("spotify", 1, true) then return "spotify" end
  return nil
end

local function routedSources(track)
  local sources = normalizedSources()
  local preferred = preferredSource(track)
  if not preferred or #sources == 0 then return sources end
  local hasPreferred = false
  for _, source in ipairs(sources) do
    if source == preferred then hasPreferred = true; break end
  end
  if not hasPreferred then return sources end
  local result = { preferred }
  for _, source in ipairs(sources) do
    if source ~= preferred then result[#result + 1] = source end
  end
  return result
end

formatPriority = normalizeFormatPriority(noctalia.getConfig("format_priority"))
sourceFormatPriority = normalizeSourceFormatPriority(noctalia.getConfig("source_format_priority"))
autoSourceRouting = noctalia.getConfig("auto_source_routing")
if autoSourceRouting == nil then autoSourceRouting = true end

local function splitMetadata(value, separator)
  local fields = {}
  local start = 1
  while true do
    local finish = value:find(separator, start, true)
    if not finish then
      fields[#fields + 1] = value:sub(start)
      break
    end
    fields[#fields + 1] = value:sub(start, finish - 1)
    start = finish + #separator
  end
  return fields
end

local function trimMetadataField(value)
  if #value > 16384 then return "" end
  return value:gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalizeMetadataField(value)
  value = value:gsub("%c", " ")
  return value:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function evictCache()
  local keys = {}
  for k, _ in pairs(cache) do keys[#keys + 1] = k end
  if #keys > 30 then
    table.sort(keys)
    for i = 1, #keys - 30 do
      local evicted = keys[i]
      cache[evicted] = nil
      sourceCoverCache[evicted] = nil
      candidateCache[evicted] = nil
      selectedCandidateCache[evicted] = nil
      selectedCandidateSourceCache[evicted] = nil
      appliedFormatCache[evicted] = nil
      appliedSyncCache[evicted] = nil
    end
  end
end

local function fetchLyricsNetEase(track, embeddedLyrics, requestedCandidateId, requestedCandidateSource)
  local tk = trackKey(track)
  requestedCandidateId = tostring(requestedCandidateId or "")
  local manualSelection = requestedCandidateId ~= ""
  local candidateSource = tostring(requestedCandidateSource or "lrclib")
  if retryTrackKey ~= tk then retryFailures = 0 end
  retryTrackKey = tk
  retryRemainingMs = 0
  fetchGeneration = fetchGeneration + 1
  local flight = tk .. "|" .. tostring(fetchGeneration)
  inFlight = flight
  setLyricsLoading(true)
  publishCandidates(tk, manualSelection, nil, manualSelection and requestedCandidateId or nil)

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
            retryFailures = 0
            retryRemainingMs = 0
            publishLyrics(parsed.lines)
            noctalia.state.set("lyrics_source_used", "netease")
            return
          end
          local lrc = (ldata.lrc and ldata.lrc.lyric) or ""
          local lyr = parseLRC(lrc)
          if not lyr then lyr = parsePlain(lrc) end
          if lyr then
            cache[tk] = lyr
            evictCache()
            inFlight = nil
            retryFailures = 0
            retryRemainingMs = 0
            publishLyrics(lyr)
            noctalia.state.set("lyrics_source_used", "netease")
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
      retryFailures = 0
      retryRemainingMs = 0
      publishLyrics(lyrics)
      noctalia.state.set("lyrics_source_used", "netease")
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
      publishLyrics(parsed.lines)
      return true
    end
    if parsed and parsed.type == "lrc" and parsed.lrc and parsed.lrc ~= "" then
      local lyr = parseLRC(parsed.lrc)
      if not lyr then lyr = parsePlain(parsed.lrc) end
      if lyr then
        cache[tk] = lyr
        evictCache()
        publishLyrics(lyr)
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
    publishLyrics(parsed)
    return true
  end

  local function finishLookup(status)
    inFlight = nil
    setLyricsLoading(false)
    setLyricsStatus(status)
  end

  if not manualSelection and lyricsSource == "auto" then
    local url = tostring(track.mediaUrl or "")
    local path = url:match("^file://(/.*)$") or url:match("^file://localhost(/.*)$")
    if path then
      path = path:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
      local stem = path:match("^(.*/[^/]+)%.[^/%.]+$")
      local sidecar = not path:find("\0", 1, true) and (stem or path) .. ".lrc" or nil
      local info = sidecar and noctalia.fileInfo(sidecar)
      if info and not info.isDir and info.size > 0 and info.size <= 262144
        and applyText(noctalia.readFile(sidecar)) then
        noctalia.state.set("lyrics_source_used", "sidecar")
        finishLookup("ready")
        return
      end
    end
  end

  local function fetchCustom(fallback)
    if customUrl == "" then
      if fallback then fallback() else finishLookup("error") end
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
        if type(decoded) == "table" and #decoded > 0 then
          cache[tk] = decoded
          evictCache()
          publishLyrics(decoded)
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
        finishLookup(response.ok and "not_found" or "error")
      end
    end)
  end

  if not manualSelection then
    if lyricsSource == "external" then
      inFlight = nil
      setLyricsLoading(false)
      setLyricsStatus("waiting")
      return
    elseif lyricsSource == "mpris" then
      if applyText(embeddedLyrics) then noctalia.state.set("lyrics_source_used", "mpris")
      else setLyricsStatus("not_found") end
      inFlight = nil
      return
    elseif lyricsSource == "custom" then
      if noctalia.getSetting("shell.offline_mode") == true then finishLookup("offline")
      else fetchCustom(nil) end
      return
    end
  end

  local requestPath = requestDir .. "/source_request_" .. tostring(fetchGeneration) .. ".json"
  local sources = manualSelection and { candidateSource } or routedSources(track)
  local request = {
    track = track,
    options = {
      translation_language = noctalia.getConfig("translation_language") or "zh-Hans",
      lyrics_candidate_id = manualSelection and requestedCandidateId or nil,
      collect_candidates = candidateMode ~= "best",
      format_priority = formatPriority,
      source_format_priority = sourceFormatPriority,
    },
  }

  local plainFallback = nil
  local offlineSkipped = false
  local dependencyMissing = false
  local lookupError = false

  local function applyResult(parsed, sourceName)
    cache[tk] = parsed.lines
    if candidateMode == "best" then
      candidateCache[tk] = nil
      selectedCandidateCache[tk] = nil
      selectedCandidateSourceCache[tk] = nil
    else
      candidateCache[tk] = type(parsed.candidates) == "table" and parsed.candidates or {}
      selectedCandidateCache[tk] = tostring(parsed.selected_candidate_id or "")
      selectedCandidateSourceCache[tk] = selectedCandidateCache[tk] ~= ""
        and tostring(parsed.source or sourceName) or ""
    end
    evictCache()
    inFlight = nil
    retryFailures = 0
    retryRemainingMs = 0
    local sync = type(parsed.sync) == "string" and parsed.sync or "plain"
    local formatName = type(parsed.format) == "string" and parsed.format or "lrc"
    appliedFormatCache[tk] = formatName
    appliedSyncCache[tk] = sync
    publishLyrics(parsed.lines)
    noctalia.state.set("lyrics_source_used", parsed.source or sourceName)
    publishCandidates(tk)
    local coverage = tonumber(parsed.coverage) or 0
    noctalia.log("lyrics source " .. tostring(parsed.source or sourceName) .. ": "
      .. formatName .. " " .. sync .. " " .. tostring(#parsed.lines) .. " lines ("
      .. tostring(math.floor(coverage * 100 + 0.5)) .. "%)")
    if type(parsed.cover) == "string" and parsed.cover ~= "" then
      sourceCoverCache[tk] = parsed.cover
      maybeApplyCover(track, parsed.cover)
    end
  end

  local function trySource(index)
    if inFlight ~= flight then return end
    local source = sources[index]
    if not source then
      inFlight = nil
      if manualSelection then
        publishCandidates(tk, false, "selection_failed")
        noctalia.log("lyrics candidate selection failed; falling back to the best match")
        fetchLyricsNetEase(currentTrack, currentEmbeddedLyrics)
      elseif plainFallback then
        applyResult(plainFallback, plainFallback.source or "")
      else
        if not noctalia.state.get("lyrics") then noctalia.state.set("lyrics_source_used", nil) end
        setLyricsLoading(false)
        setLyricsStatus(dependencyMissing and "dependency_missing"
          or (lookupError and "error" or (offlineSkipped and "offline" or "not_found")))
        -- Preserve candidate state while the next lookup is pending so the
        -- selector never loses its last actionable list.
        publishCandidates(tk)
        retryFailures = retryFailures + 1
        retryRemainingMs = offlineSkipped and 0 or math.min(60000, 2000 * 2 ^ math.min(retryFailures - 1, 5))
        noctalia.log("lyrics unavailable for " .. tostring(track.title) .. "; retrying in "
          .. tostring(math.floor(retryRemainingMs / 1000)) .. "s")
      end
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
    if noctalia.getSetting("shell.offline_mode") == true then
      offlineSkipped = true
      trySource(index + 1)
      return
    end
    if source == "custom" then
      fetchCustom(function() trySource(index + 1) end)
      return
    end
    if not noctalia.commandExists("python3") or not noctalia.commandExists("chmod") then
      dependencyMissing = true
      trySource(index + 1)
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
        lookupError = true
        trySource(index + 1)
        return
      end

      local command = "python3 " .. shellQuote(pluginDir .. "/lyric_sources.py")
        .. " " .. shellQuote(requestPath)
      local started = noctalia.runAsync(command, function(result)
        noctalia.removeFile(requestPath)
        if inFlight ~= flight or tk ~= lastTrackKey then return end
        if result.exitCode ~= 0 then
          lookupError = true
          if tostring(result.stderr or ""):find("not found", 1, true) then dependencyMissing = true end
          noctalia.log("lyrics source " .. source .. " process failed (exit "
            .. tostring(result.exitCode) .. "); is python3 on PATH?")
        end
        local parsed = noctalia.json.decode(result.stdout or "")
        if type(parsed) == "table" and parsed.type == "lyrics" and type(parsed.lines) == "table" and #parsed.lines > 0 then
          -- Plain (untimed) lyrics are kept only as a last resort: continue to
          -- the next source so a timed result is preferred. Word/line results
          -- are accepted immediately, so no timing latency is added.
          if parsed.sync == "plain" and sources[index + 1] and not manualSelection then
            plainFallback = parsed
            trySource(index + 1)
            return
          end
          applyResult(parsed, source)
        else
          local diag = type(parsed) == "table" and type(parsed.diag) == "table"
            and table.concat(parsed.diag, "; ") or ""
          if diag:find("missing ssl module", 1, true) or diag:find("python3 on PATH", 1, true) then
            dependencyMissing = true
          elseif diag ~= "" and not diag:find("no match", 1, true)
            and not diag:find("lyrics unavailable", 1, true)
            and not diag:find("requested match unavailable", 1, true) then
            lookupError = true
          end
          noctalia.log("lyrics source " .. source .. " unavailable"
            .. (diag ~= "" and (": " .. diag) or ""))
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
  if pollInFlight or lyricsSource == "external" then return end
  if not noctalia.commandExists("playerctl") or not noctalia.commandExists("timeout") then
    clearPlayerState()
    setLyricsStatus("dependency_missing")
    return
  end
  pollInFlight = true
  -- xesam:asText can contain an entire lyric file. Only request it when it
  -- is configured as a lyric source; otherwise it needlessly inflates every
  -- poll result and can exhaust the async callback CPU budget.
  local embeddedFormat = needsEmbeddedLyrics() and "{{xesam:asText}}" or ""
  local cmd = [[timeout 3s playerctl --all-players metadata --format "$(printf '{{playerInstance}}\037{{playerName}}\037{{lc(status)}}\037{{title}}\037{{artist}}\037{{album}}\037{{position}}\037{{mpris:length}}\037{{mpris:artUrl}}\037{{mpris:trackid}}\037{{xesam:url}}\037]]
    .. embeddedFormat .. [[\036')" 2>/dev/null]]

  local function handleEmptyPoll()
    emptyPollCount = emptyPollCount + 1
    if emptyPollCount >= 2 then clearPlayerState() end
  end

  local started = noctalia.runAsync(cmd, function(r)
    pollInFlight = false
    if lyricsSource == "external" then return end
    if r.exitCode ~= 0 or not r.stdout or r.stdout == "" then
      handleEmptyPoll()
      return
    end
    if #r.stdout > 131072 then
      handleEmptyPoll()
      return
    end
    emptyPollCount = 0

    local players = {}
    local fieldSeparator = string.char(31)
    local recordSeparator = string.char(30)
    for _, record in ipairs(splitMetadata(r.stdout, recordSeparator)) do
      if record ~= "" then
        local parts = splitMetadata(record, fieldSeparator)
        for index, field in ipairs(parts) do
          parts[index] = trimMetadataField(field)
        end
        for index = 4, 6 do
          if parts[index] then parts[index] = normalizeMetadataField(parts[index]) end
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
      handleEmptyPoll()
      return
    end

    currentPlayerInstance = selected.instance
    noctalia.state.set("player_instance", selected.instance)
    noctalia.state.set("player_name", selected.name)

    if selected.title == "" and selected.artist == "" then
      emptyTrackCount = emptyTrackCount + 1
      noctalia.state.set("playing", selected.status == "playing")
      if emptyTrackCount >= 2 then
        fetchGeneration = fetchGeneration + 1
        inFlight = nil
        currentTrack = nil
        currentEmbeddedLyrics = ""
        lastTrackKey = ""
        setLyricsLoading(false)
        setLyricsStatus("idle")
        setCurrentTrackOffset(nil)
        noctalia.state.set("track", nil)
        noctalia.state.set("lyrics", nil)
        noctalia.state.set("lyrics_source_used", nil)
        publishCandidates("")
      end
      return
    end
    emptyTrackCount = 0

    local playing = selected.status == "playing"
    local t = {
      title = selected.title,
      artist = selected.artist,
      album = selected.album,
      status = selected.status,
      position = selected.position,
      duration = selected.duration,
      playerInstance = selected.instance,
      playerName = selected.name,
      trackId = selected.trackId,
      mediaUrl = selected.mediaUrl,
    }
    local tk = trackKey(t)
    currentTrack = t
    currentEmbeddedLyrics = selected.embeddedLyrics
    local previousArtUrl = currentArtUrl
    currentArtUrl = selected.artUrl

    local trackChanged = tk ~= lastTrackKey
    if trackChanged then
      lastTrackKey = tk
      setCurrentTrackOffset(t)
    end
    noctalia.state.set("position", t.position + (lyricsOffsetMs + currentLyricsOffsetMs) * 1000)

    if trackChanged then
      currentCoverUrl = ""
      pendingSourceCoverUrl = ""
      mprisCoverFailed = false
      coverFetchGeneration = coverFetchGeneration + 1
      coverInFlight = nil
      noctalia.state.set("track", t)
      noctalia.state.set("playing", playing)

      local cached = cache[tk]
      if cached then
        inFlight = nil
        setLyricsLoading(false)
        publishLyrics(cached)
        noctalia.state.set("lyrics_source_used", "cache")
        publishCandidates(tk)
      else
        setLyricsLoading(true)
        noctalia.state.set("lyrics", nil)
        publishCandidates(tk)
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
  if lyricsLoading and inFlight == nil then setLyricsLoading(false) end
  if lyricsSource == "external" then return end
  if retryRemainingMs > 0 then
    retryRemainingMs = retryRemainingMs - updateIntervalMs
    if retryRemainingMs <= 0 then
      retryRemainingMs = 0
      if inFlight == nil and currentTrack and lastTrackKey == retryTrackKey
        and noctalia.state.get("lyrics") == nil then
        fetchLyricsNetEase(currentTrack, currentEmbeddedLyrics)
      end
    end
  end
  pollElapsedMs = pollElapsedMs + updateIntervalMs
  if pollElapsedMs >= pollIntervalMs then
    pollElapsedMs = 0
    poll()
  end

end

function onConfigChanged()
  local nextSource = noctalia.getConfig("lyrics_source") or "auto"
  local nextCandidateMode = noctalia.getConfig("candidate_mode") or "choose"
  local nextUrl = noctalia.getConfig("custom_url") or ""
  local nextField = noctalia.getConfig("custom_json_field") or "syncedLyrics"
  local nextSources = noctalia.getConfig("lyrics_sources") or lyricsSources
  local nextPollInterval = tonumber(noctalia.getConfig("poll_interval_ms")) or 500
  local nextOffset = tonumber(noctalia.getConfig("lyrics_offset_ms")) or 0
  local nextFormatPriority = normalizeFormatPriority(noctalia.getConfig("format_priority"))
  local nextSourceFormatPriority = normalizeSourceFormatPriority(noctalia.getConfig("source_format_priority"))
  local nextAutoSourceRouting = noctalia.getConfig("auto_source_routing")
  if nextAutoSourceRouting == nil then nextAutoSourceRouting = true end
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
    noctalia.getConfig("splayer_next_api_url") or "http://127.0.0.1:14558",
    noctalia.getConfig("translation_language") or "zh-Hans",
  }, "\0")
  local nextAllowlist = normalizePatterns(noctalia.getConfig("player_allowlist"))
  local nextBlocklist = normalizePatterns(noctalia.getConfig("player_blocklist"))
  local priorityChanged = listSignature(nextFormatPriority) ~= listSignature(formatPriority)
    or mapSignature(nextSourceFormatPriority) ~= mapSignature(sourceFormatPriority)
    or nextAutoSourceRouting ~= autoSourceRouting
  local candidateModeChanged = nextCandidateMode ~= candidateMode
  local nextOffline = noctalia.getSetting("shell.offline_mode") == true
  local sourceChanged = nextOffline ~= offlineMode or nextSource ~= lyricsSource or nextUrl ~= customUrl or nextField ~= customJsonField
    or table.concat(nextSources, "\n") ~= table.concat(lyricsSources, "\n")
    or nextCredentialSignature ~= credentialSignature
    or priorityChanged or candidateModeChanged
  local playersChanged = table.concat(nextAllowlist, "\n") ~= table.concat(playerAllowlist, "\n")
    or table.concat(nextBlocklist, "\n") ~= table.concat(playerBlocklist, "\n")
  offlineMode = nextOffline
  lyricsSource = nextSource
  candidateMode = nextCandidateMode
  customUrl = nextUrl
  customJsonField = nextField
  lyricsSources = nextSources
  pollIntervalMs = math.max(100, nextPollInterval)
  lyricsOffsetMs = nextOffset
  formatPriority = nextFormatPriority
  sourceFormatPriority = nextSourceFormatPriority
  autoSourceRouting = nextAutoSourceRouting
  credentialSignature = nextCredentialSignature
  playerAllowlist = nextAllowlist
  playerBlocklist = nextBlocklist
  if sourceChanged then
    fetchGeneration = fetchGeneration + 1
    inFlight = nil
    cache = {}
    sourceCoverCache = {}
    candidateCache = {}
    selectedCandidateCache = {}
    selectedCandidateSourceCache = {}
    appliedFormatCache = {}
    appliedSyncCache = {}
    retryRemainingMs = 0
    retryFailures = 0
    noctalia.state.set("lyrics", nil)
    noctalia.state.set("lyrics_source_used", nil)
    publishCandidates(lastTrackKey)
  end
  if playersChanged then
    fetchGeneration = fetchGeneration + 1
    inFlight = nil
  end
  if lyricsSource ~= "external" and (playersChanged or sourceChanged) then
    -- Let the next completed poll choose a player and re-fetch with the new settings.
    lastTrackKey = ""
    poll()
  elseif sourceChanged then
    setLyricsLoading(false)
    setLyricsStatus("waiting")
  end
end

local function retryLyrics()
  if not currentTrack or inFlight or lyricsSource == "external" then return end
  fetchLyricsNetEase(currentTrack, currentEmbeddedLyrics)
end

local function changeOffset(action)
  action = tostring(action or "")
  if action == "reset" then
    saveTrackOffset(lastTrackKey, 0)
  elseif action:match("^[+-]%d+$") then
    saveTrackOffset(lastTrackKey, currentLyricsOffsetMs + tonumber(action))
  end
end

local function watchTrackRequest(key, handler)
  local lastRequest = ""
  noctalia.state.watch(key, function(request)
    if type(request) ~= "table" or not currentTrack or request.track_key ~= lastTrackKey then return end
    local id = tostring(request.request_id or "")
    if id == "" or id == lastRequest then return end
    lastRequest = id
    handler(request.action)
  end)
end

watchTrackRequest("lyrics_offset_request", changeOffset)
watchTrackRequest("lyrics_retry_request", retryLyrics)

local lastCandidateRequest = ""
noctalia.state.watch("lyrics_candidate_request", function(request)
  if type(request) ~= "table" or not currentTrack or candidateMode == "best" or inFlight then return end
  local requestId = tostring(request.request_id or "")
  if requestId == "" or requestId == lastCandidateRequest then return end
  lastCandidateRequest = requestId
  local candidateId = tostring(request.candidate_id or "")
  local tk = trackKey(currentTrack)
  if tostring(request.track_key or "") ~= tk then return end
  if candidateId == "" then
    inFlight = nil
    fetchLyricsNetEase(currentTrack, currentEmbeddedLyrics)
    return
  end
  local candidateSource = tostring(request.source or "lrclib")
  local known = false
  for _, candidate in ipairs(candidateCache[tk] or {}) do
    if tostring(candidate.id or "") == candidateId
      and tostring(candidate.source or "lrclib") == candidateSource then
      known = true
      break
    end
  end
  if not known or (candidateId == tostring(selectedCandidateCache[tk] or "")
      and candidateSource == tostring(selectedCandidateSourceCache[tk] or "")) then
    return
  end
  inFlight = nil
  fetchLyricsNetEase(currentTrack, currentEmbeddedLyrics, candidateId, candidateSource)
end)

local function applyPushedLyrics(payload)
  local decoded = noctalia.json.decode(payload or "")
  if type(decoded) == "table" then
    if decoded.track then
      currentTrack = decoded.track
      lastTrackKey = trackKey(decoded.track)
      setCurrentTrackOffset(currentTrack)
      noctalia.state.set("track", decoded.track)
    end
    local tk = currentTrack and trackKey(currentTrack) or ""
    candidateCache[tk] = nil
    selectedCandidateCache[tk] = nil
    selectedCandidateSourceCache[tk] = nil
    appliedFormatCache[tk] = nil
    appliedSyncCache[tk] = nil
    publishCandidates(tk)
    if decoded.lines then publishLyrics(decoded.lines) end
    if decoded.lyrics then
      local parsed = parseLRC(decoded.lyrics) or parsePlain(decoded.lyrics)
      publishLyrics(parsed)
    end
    setLyricsLoading(false)
    if decoded.position ~= nil and currentTrack then currentTrack.position = tonumber(decoded.position) or 0 end
    if decoded.position ~= nil then
      noctalia.state.set("position", (tonumber(decoded.position) or 0) + (lyricsOffsetMs + currentLyricsOffsetMs) * 1000)
    end
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

local function controlPlayer(action, onSuccess)
  if currentPlayerInstance == "" then return end
  noctalia.runAsync("playerctl --player " .. shellQuote(currentPlayerInstance) .. " " .. action, function(result)
    if result.exitCode ~= 0 then return end
    if onSuccess then onSuccess() end
    poll()
  end)
end

function onIpc(event, payload)
  if event == "offset" then
    changeOffset(payload)
  elseif event == "retry" then
    retryLyrics()
  elseif event == "toggle-playback" then
    local wasPlaying = noctalia.state.get("playing") == true
    controlPlayer("play-pause", function()
      noctalia.state.set("playing", not wasPlaying)
    end)
  elseif event == "next" then
    controlPlayer("next")
  elseif event == "previous" then
    controlPlayer("previous")
  elseif event == "push-lrc" then
    local tk = currentTrack and trackKey(currentTrack) or ""
    candidateCache[tk] = nil
    selectedCandidateCache[tk] = nil
    selectedCandidateSourceCache[tk] = nil
    appliedFormatCache[tk] = nil
    appliedSyncCache[tk] = nil
    publishCandidates(tk)
    publishLyrics(parseLRC(payload or "") or parsePlain(payload or ""))
    setLyricsLoading(false)
  elseif event == "push-json" or event == "push-state" then
    applyPushedLyrics(payload)
  elseif event == "clear" then
    local tk = currentTrack and trackKey(currentTrack) or ""
    candidateCache[tk] = nil
    selectedCandidateCache[tk] = nil
    selectedCandidateSourceCache[tk] = nil
    publishCandidates(tk)
    noctalia.state.set("lyrics", nil)
    setLyricsLoading(false)
    setLyricsStatus(lyricsSource == "external" and "waiting" or "not_found")
  end
end

if lyricsSource ~= "external" then poll() else setLyricsStatus("waiting") end
