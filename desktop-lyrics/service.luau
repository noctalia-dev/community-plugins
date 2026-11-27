--!nonstrict
-- Headless service: follows the shell's active MPRIS player, fetches synced
-- lyrics from LRCLIB, parses LRC and publishes everything to plugin state.
--
-- Network: lrclib.net only (/api/get plus a verified /api/search fallback).
-- Filesystem: <pluginDataDir>/cache/*.json when cache_enabled is on, plus
--   <pluginDataDir>/wallpaper.rgb while wallpaper-aware placement is on.
-- Processes: one short-lived magick/convert/ffmpeg per wallpaper change while
--   wallpaper-aware placement is on; nothing else is spawned.

local API_BASE = "https://lrclib.net/api"
local USER_AGENT = "Noctalia-Desktop-Lyrics/1.1 (https://github.com/alitura1/noctalia-lyrics-3d)"
local MAX_LOCAL_BYTES = 512 * 1024
local BUILTIN_DOMAINS = {
  "youtube.com",
  "youtu.be",
  "music.youtube.com",
  "open.spotify.com",
  "spotify.com",
  "soundcloud.com",
  "bandcamp.com",
  "deezer.com",
  "tidal.com",
  "music.apple.com",
  "music.163.com",
  "y.qq.com",
  "bilibili.com",
}

local currentTrack = nil -- { key, title, artist, album, lengthMs, url, identity }
local currentLines = nil -- { { t = ms, text = string }, ... }
local currentStatus = "idle"
local currentSource = ""
local requestInFlight = ""
local lastRefreshRequest = nil
local loadDeadlineMs = 0
local loadGeneration = 0
-- The playhead is dead-reckoned locally; MPRIS only supplies anchors.
local anchor = { ms = 0, wall = 0, status = "Stopped", rate = 1, grace = 0 }
local pausedSince = nil

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return value
end

local function normalize(value)
  return noctalia.string.trim(string.lower(value or ""))
end

-- One comparison form for hosts and configured domains: lower case, no
-- trailing DNS root dot. "example.com." and "example.com" are the same host.
local function hostKey(host)
  return (string.lower(host or ""):gsub("%.$", ""))
end

local function hostOf(url)
  if not url or url == "" then
    return ""
  end
  -- Only the host is filtered, so credentials and an explicit port are dropped.
  local authority = url:match("^[%w][%w+.-]*://([^/?#]+)")
  if not authority then
    return ""
  end
  authority = authority:gsub("^.*@", "")
  local host = authority:match("^%[([^%]]+)%]") or authority:match("^([^:]+)")
  return hostKey(host)
end

local function domainMatches(host, domain)
  local entry = hostKey(normalize(domain))
  if entry == "" or host == "" then
    return false
  end
  if host == entry then
    return true
  end
  local suffix = "." .. entry
  return #host > #suffix and string.sub(host, -#suffix) == suffix
end

local function listedIn(list, value)
  if type(list) ~= "table" then
    return false
  end
  for _, item in ipairs(list) do
    if domainMatches(value, item) then
      return true
    end
  end
  return false
end

local function playerAllowed(player)
  local blocked = cfg("disabled_players", {})
  if type(blocked) ~= "table" then
    return true
  end
  local identity = normalize(player.identity)
  local bus = normalize(player.busName)
  for _, item in ipairs(blocked) do
    local needle = normalize(item)
    if needle ~= "" and (identity == needle or bus:find(needle, 1, true) ~= nil) then
      return false
    end
  end
  return true
end

local function sourceAllowed(player)
  local host = hostOf(player.url)
  local blocked = cfg("disabled_domains", {})
  if type(blocked) == "table" and listedIn(blocked, host) then
    return false
  end
  if cfg("filter_mode", "allowAll") == "whitelist" then
    if host == "" then
      -- Browsers without xesam:url cannot be verified; local players keep working.
      return true
    end
    if listedIn(BUILTIN_DOMAINS, host) then
      return true
    end
    return listedIn(cfg("custom_domains", {}), host)
  end
  return true
end

local function hash(text)
  local value = 5381
  for index = 1, #text do
    value = (value * 33 + string.byte(text, index)) % 2147483647
  end
  return string.format("%08x", value)
end

local function cacheDir()
  local base = noctalia.pluginDataDir()
  if not base then
    return nil
  end
  local dir = base .. "/cache"
  noctalia.mkdirAll(dir)
  return dir
end

local function cachePath(key)
  local dir = cacheDir()
  if not dir then
    return nil
  end
  return dir .. "/" .. hash(key) .. ".json"
end

local cacheIndex = nil

-- index.json holds every cached track key -> file. It is read once and kept
-- in memory, so a track change costs one table lookup instead of a path hash
-- and a failed file probe.
local function loadCacheIndex()
  if cacheIndex ~= nil then
    return cacheIndex
  end
  cacheIndex = {}
  local dir = cacheDir()
  if not dir then
    return cacheIndex
  end
  local raw = noctalia.readFile(dir .. "/index.json")
  local decoded = raw and noctalia.json.decode(raw) or nil
  if type(decoded) == "table" then
    for key, entry in pairs(decoded) do
      if type(entry) == "table" then
        cacheIndex[key] = entry
      end
    end
  end
  return cacheIndex
end

local function saveCacheIndex()
  local dir = cacheDir()
  if not dir or cacheIndex == nil then
    return
  end
  noctalia.writeFile(dir .. "/index.json", noctalia.json.encode(cacheIndex))
end

local function readCache(key)
  if not cfg("cache_enabled", true) then
    return nil
  end
  local index = loadCacheIndex()
  if index[key] == nil then
    return nil
  end
  -- The index is only a hint that the key was cached; the file name is always
  -- derived from the key, never read back from the index.
  local path = cachePath(key)
  if not path then
    return nil
  end
  local contents = noctalia.readFile(path)
  if not contents or contents == "" then
    index[key] = nil
    saveCacheIndex()
    return nil
  end
  local decoded = noctalia.json.decode(contents)
  if type(decoded) ~= "table" or decoded.key ~= key then
    index[key] = nil
    saveCacheIndex()
    return nil
  end
  return decoded
end

local function writeCache(key, entry)
  if not cfg("cache_enabled", true) then
    return
  end
  local path = cachePath(key)
  if not path then
    return
  end
  entry.key = key
  entry.savedAt = os.time()
  noctalia.writeFile(path, noctalia.json.encode(entry))
  local index = loadCacheIndex()
  index[key] = { savedAt = os.time() }
  saveCacheIndex()
end

-- MPRIS exposes the playing file as xesam:url; only local paths can have a
-- sibling lyric file, so anything without one is left to LRCLIB.
local function pathFromUrl(url)
  if not url or url == "" then
    return nil
  end
  local path = url
  if path:match("^file://") then
    -- A file URL without an authority slash, or one naming a remote host, is
    -- not a local path and must not be read as one.
    local authority, rest = path:match("^file://([^/]*)(/.*)$")
    if not authority then
      return nil
    end
    if authority ~= "" and string.lower(authority) ~= "localhost" then
      return nil
    end
    path = rest:gsub("%%(%x%x)", function(hex)
      return string.char(tonumber(hex, 16))
    end)
    if path:find("\0", 1, true) then
      return nil
    end
  end
  if path:sub(1, 1) ~= "/" then
    return nil
  end
  return path
end

local function parseTimestamp(minutes, seconds, fraction)
  local value = tonumber(fraction) or 0
  local digits = #fraction
  if digits < 3 then
    value = value * (10 ^ (3 - digits))
  elseif digits > 3 then
    value = math.floor(value / (10 ^ (digits - 3)))
  end
  return tonumber(minutes) * 60000 + tonumber(seconds) * 1000 + value
end

-- Enhanced LRC puts a timestamp before every word: [00:12.34]<00:12.34>word.
-- Splitting them lets the playhead advance per word instead of filling the
-- whole line at a constant rate.
local function splitWordTags(text)
  local words = {}
  local chunks = {}
  local pos = 1
  local started = nil
  while true do
    local s, e, minutes, seconds, fraction = text:find("<(%d+):(%d+)%.(%d+)>", pos)
    if not s then
      break
    end
    local chunk = text:sub(pos, s - 1)
    if started ~= nil then
      -- Word text is trimmed because the displayed line is trimmed too; a raw
      -- trailing space would never be found in it and the last word would not
      -- get a span.
      local piece = noctalia.string.trim(chunk)
      if piece ~= "" then
        table.insert(words, { t = started, text = piece })
      end
    end
    if chunk ~= "" then
      table.insert(chunks, chunk)
    end
    started = parseTimestamp(minutes, seconds, fraction)
    pos = e + 1
  end
  if started == nil then
    return nil, nil
  end
  local tail = text:sub(pos)
  local tailPiece = noctalia.string.trim(tail)
  if tailPiece ~= "" then
    table.insert(words, { t = started, text = tailPiece })
  end
  table.insert(chunks, tail)

  local line = noctalia.string.trim(table.concat(chunks))
  -- ui.fillLabel takes 1-based inclusive byte spans into the displayed text, so
  -- locate every word in the assembled line instead of counting bytes in the
  -- raw LRC (which still holds the tags and the trimmed whitespace).
  local ranges = {}
  local from = 1
  for _, word in ipairs(words) do
    local first = line:find(word.text, from, true)
    if first then
      word.first = first
      word.last = first + #word.text - 1
      table.insert(ranges, first)
      table.insert(ranges, word.last)
      from = word.last + 1
    end
  end
  if #ranges == 0 then
    ranges = nil
  end
  return words, line, ranges
end

local function parseLrc(body)
  local lines = {}
  local offset = 0

  for raw in body:gmatch("[^\r\n]+") do
    local offsetTag = raw:match("^%[offset:([%-%+]?%d+)%]")
    if offsetTag then
      offset = tonumber(offsetTag) or 0
    end

    local rest = raw
    local stamps = {}
    while true do
      local minutes, seconds, fraction, tail = rest:match("^%s*%[(%d+):(%d+)%.(%d+)%](.*)$")
      if not minutes then
        break
      end
      table.insert(stamps, parseTimestamp(minutes, seconds, fraction))
      rest = tail
    end

    local words, text, ranges = splitWordTags(rest)
    if not words then
      text = noctalia.string.trim(rest)
    end
    if words then
      for _, word in ipairs(words) do
        word.t = word.t + offset
      end
    end
    if #stamps > 0 and text ~= "" then
      for _, stamp in ipairs(stamps) do
        table.insert(lines, { t = stamp + offset, text = text, words = words, ranges = ranges })
      end
    end
  end

  table.sort(lines, function(a, b)
    return a.t < b.t
  end)

  -- Drop exact duplicates that come from repeated timestamps on one line.
  local unique = {}
  for _, line in ipairs(lines) do
    local previous = unique[#unique]
    if not previous or previous.t ~= line.t or previous.text ~= line.text then
      table.insert(unique, line)
    end
  end

  return unique
end

-- Best-effort preflight: Luau's readFile has no open-with-limit variant, so the
-- type and size are checked right before the read and the result is capped
-- again afterwards. A FIFO or device node reports size 0 and is rejected
-- before the blocking read; a file swapped in after the check is not bounded
-- while that read is running.
local function readRegularFile(path)
  local info = noctalia.fileInfo and noctalia.fileInfo(path) or nil
  if type(info) ~= "table" or info.isDir then
    return nil
  end
  local size = tonumber(info.size) or 0
  if size <= 0 or size > MAX_LOCAL_BYTES then
    return nil
  end
  local contents = noctalia.readFile(path)
  if type(contents) ~= "string" or contents == "" or #contents > MAX_LOCAL_BYTES then
    return nil
  end
  return contents
end

-- A lyric file next to the audio file wins over the network: it is exact, it
-- works offline and it can carry word timings LRCLIB does not have.
local function readLocalLyrics(track)
  if not cfg("local_lyrics", true) then
    return nil
  end
  local path = pathFromUrl(track.url)
  if not path then
    return nil
  end
  local stem = path:gsub("%.[^./]+$", "")
  for _, extension in ipairs({ ".lrc", ".elrc" }) do
    local contents = readRegularFile(stem .. extension)
    if contents and #parseLrc(contents) > 0 then
      return {
        synced = contents,
        plain = "",
        instrumental = false,
        source = "Local " .. extension,
        localFile = true,
      }
    end
  end
  return nil
end

-- How many fillLabel segments have been sung: one per timed word, plus the
-- fraction of the word that is playing now. ui.fillLabel accepts this directly
-- as fillProgress, so a word boundary is never crossed early.
local function wordFill(words, position, endMs)
  local filled = 0
  for index, word in ipairs(words) do
    local startMs = word.t
    local finishMs = words[index + 1] and words[index + 1].t or endMs
    if position <= startMs then
      break
    end
    if position >= finishMs then
      filled = filled + 1
    else
      local span = finishMs - startMs
      local fraction = span > 0 and (position - startMs) / span or 1
      filled = filled + math.max(0, math.min(1, fraction))
      break
    end
  end
  return filled
end

local function publish(values)
  for key, value in pairs(values) do
    noctalia.state.set(key, value)
  end
  noctalia.state.set("tick", os.time())
end

local function publishEmpty(status, title, artist)
  publish({
    status = status,
    title = title or "",
    artist = artist or "",
    current = "",
    next = "",
    previous = "",
    progress = 0,
    word_ranges = {},
    word_progress = 0,
    track_progress = 0,
    count = 0,
  })
end

local function applyLyrics(entry)
  if entry and entry.synced and entry.synced ~= "" then
    local parsed = parseLrc(entry.synced)
    if #parsed > 0 then
      currentLines = parsed
      currentStatus = "synced"
      currentSource = entry.source or "LRCLIB"
      return
    end
  end

  if entry and entry.plain and entry.plain ~= "" then
    currentLines = nil
    currentStatus = "plain"
    currentSource = entry.source or "LRCLIB"
    publish({ plain = entry.plain, count = 0 })
    return
  end

  if entry and entry.instrumental then
    currentLines = nil
    currentStatus = "instrumental"
    return
  end

  currentLines = nil
  currentStatus = "notfound"
end

local finishLoad

function finishLoad(track, entry)
  if currentTrack and currentTrack.key ~= track.key then
    return
  end
  applyLyrics(entry)
  -- Local files are read on every track change, so caching them would only
  -- freeze a file the user is still editing.
  if entry and not entry.localFile then
    writeCache(track.key, {
      synced = entry.synced or "",
      plain = entry.plain or "",
      instrumental = entry.instrumental == true,
      source = entry.source or "LRCLIB",
      savedAt = os.time(),
    })
  end
end

-- LRCLIB search is loose: it matches titles, not recordings. A search hit is
-- therefore only accepted when its title, artist and duration describe the
-- track that is playing. /api/get is the exact lookup and wins outright; the
-- search answer is a verified fallback. Both share a 2.5 s deadline that
-- update() enforces.
-- Comparison form for titles, artists and albums: lower case, punctuation
-- folded to spaces, non-ASCII bytes kept so non-Latin titles still compare.
local function nameKey(value)
  local lower = string.lower(value or "")
  local kept = {}
  for index = 1, #lower do
    local byte = string.byte(lower, index)
    if byte >= 128 or (byte >= 48 and byte <= 57) or (byte >= 97 and byte <= 122) then
      kept[#kept + 1] = string.char(byte)
    else
      kept[#kept + 1] = " "
    end
  end
  local joined = table.concat(kept):gsub("%s+", " ")
  return noctalia.string.trim(joined)
end

-- The first credited artist, without a featured guest.
local function primaryArtist(value)
  local first = (value or ""):match("^([^,&]*)") or ""
  first = first:gsub("%s+[Ff][Ee][Aa][Tt]%.?%s.*$", "")
  return nameKey(first)
end

local function albumMatches(track, item)
  local want = nameKey(track.album)
  local got = nameKey(item.albumName)
  return want ~= "" and want == got
end

-- A search hit is a different recording unless its own metadata says it is
-- this one: the title must match exactly, the first artist must match, and a
-- duration must be present and close. "Home Again" can no longer stand in for
-- "Home", and a hit with no artist or duration is not accepted at all.
local function sameTrack(track, item)
  local wantTitle = nameKey(track.title)
  local gotTitle = nameKey(item.trackName)
  if wantTitle == "" or wantTitle ~= gotTitle then
    return false
  end

  local wantArtist = primaryArtist(track.artist)
  local gotArtist = primaryArtist(item.artistName)
  if gotArtist == "" or (wantArtist ~= "" and wantArtist ~= gotArtist) then
    return false
  end

  local gotDuration = tonumber(item.duration)
  if track.lengthMs > 0 then
    if not gotDuration or math.abs(gotDuration * 1000 - track.lengthMs) > 3000 then
      return false
    end
  end

  local wantAlbum = nameKey(track.album)
  local gotAlbum = nameKey(item.albumName)
  if wantAlbum ~= "" and gotAlbum ~= "" and wantAlbum ~= gotAlbum then
    return false
  end

  return true
end

local function entryFrom(item, source)
  if type(item) ~= "table" then
    return nil
  end
  local synced = item.syncedLyrics
  local plain = item.plainLyrics
  if item.instrumental == true then
    return { synced = "", plain = plain, instrumental = true, source = source }
  end
  if (not synced or synced == "") and (not plain or plain == "") then
    return nil
  end
  return { synced = synced or "", plain = plain, instrumental = false, source = source }
end

local function fetchLyrics(track)
  requestInFlight = track.key
  local generation = loadGeneration
  loadDeadlineMs = noctalia.nowMs() + 2500

  local pending = 2
  local settled = false
  local failures = 0
  local exactPlain = nil
  local searchSynced = nil
  local searchPlain = nil

  local function accept(entry)
    if settled or not entry or generation ~= loadGeneration then
      return false
    end
    settled = true
    loadDeadlineMs = 0
    finishLoad(track, entry)
    publish({ status = currentStatus, count = currentLines and #currentLines or 0 })
    return true
  end

  local function settle()
    if generation ~= loadGeneration or settled or pending > 0 then
      return
    end
    -- Timed lyrics from a verified search hit beat plain-only exact lyrics;
    -- nothing is cached until one of them has been matched to this track.
    if accept(searchSynced) or accept(exactPlain) or accept(searchPlain) then
      return
    end
    currentStatus = failures >= 2 and "error" or "notfound"
    publish({ status = currentStatus })
    loadDeadlineMs = 0
  end

  local function finishOne()
    pending = pending - 1
    settle()
  end

  local params = "?artist_name=" .. noctalia.string.urlEncode(track.artist)
    .. "&track_name=" .. noctalia.string.urlEncode(track.title)
  if track.album ~= "" then
    params = params .. "&album_name=" .. noctalia.string.urlEncode(track.album)
  end
  if track.lengthMs > 0 then
    params = params .. "&duration=" .. tostring(math.floor(track.lengthMs / 1000))
  end

  local getStarted = noctalia.http({
    url = API_BASE .. "/get" .. params,
    method = "GET",
    headers = { "User-Agent: " .. USER_AGENT },
  }, function(response)
    if generation ~= loadGeneration then
      return
    end
    if not response.ok or response.status ~= 200 then
      failures = failures + 1
      finishOne()
      return
    end
    local entry = entryFrom(noctalia.json.decode(response.body), "LRCLIB")
    if entry and (entry.instrumental or entry.synced ~= "") then
      accept(entry)
    elseif entry and entry.plain and entry.plain ~= "" then
      exactPlain = entry
    end
    finishOne()
  end)

  local searchStarted = noctalia.http({
    url = API_BASE .. "/search?q=" .. noctalia.string.urlEncode(track.artist .. " " .. track.title),
    method = "GET",
    headers = { "User-Agent: " .. USER_AGENT },
  }, function(response)
    if generation ~= loadGeneration then
      return
    end
    if not response.ok or response.status ~= 200 then
      failures = failures + 1
      finishOne()
      return
    end
    local results = noctalia.json.decode(response.body)
    if type(results) ~= "table" then
      finishOne()
      return
    end

    local syncedItem = nil
    local plainItem = nil
    for _, item in ipairs(results) do
      if type(item) == "table" and sameTrack(track, item) then
        if item.syncedLyrics and item.syncedLyrics ~= "" then
          if not syncedItem or (not albumMatches(track, syncedItem) and albumMatches(track, item)) then
            syncedItem = item
          end
        elseif not plainItem and item.plainLyrics and item.plainLyrics ~= "" then
          plainItem = item
        end
      end
    end
    if not searchSynced then
      searchSynced = entryFrom(syncedItem, "LRCLIB search")
    end
    if not searchPlain then
      searchPlain = entryFrom(plainItem, "LRCLIB search")
    end
    finishOne()
  end)

  if not getStarted then
    failures = failures + 1
    pending = pending - 1
  end
  if not searchStarted then
    failures = failures + 1
    pending = pending - 1
  end
  settle()
end

-- Local file, then cache, then LRCLIB. A track change uses the whole route; an
-- explicit refresh still rereads the sidecar but skips the network cache, so it
-- really asks LRCLIB again.
local function loadFor(track, forceNetwork)
  local localEntry = readLocalLyrics(track)
  if localEntry then
    finishLoad(track, localEntry)
    return
  end
  if not forceNetwork then
    local cached = readCache(track.key)
    if cached then
      finishLoad(track, cached)
      return
    end
  end
  fetchLyrics(track)
end

local function trackKey(player)
  return table.concat({
    player.title or "",
    player.artists and table.concat(player.artists, ", ") or "",
    player.album or "",
    tostring(math.floor((player.lengthMs or 0) / 1000)),
  }, "|")
end

local function updatePlayhead(position)
  if not currentLines then
    publish({
      status = currentStatus,
      current = "",
      next = "",
      previous = "",
      progress = 0,
      word_ranges = {},
      word_progress = 0,
      track_progress = 0,
      count = 0,
    })
    return
  end

  position = position + cfg("sync_offset", 0)
  local index = 1
  for i, line in ipairs(currentLines) do
    if line.t <= position then
      index = i
    else
      break
    end
  end

  local line = currentLines[index]
  local nextLine = currentLines[index + 1]
  local previousLine = index > 1 and currentLines[index - 1] or nil
  local endMs = nextLine and nextLine.t or (line.t + 4000)
  local duration = endMs - line.t
  local progress = 0
  local wordProgress = 0
  if line.ranges then
    -- One fillLabel segment per timed word; the fill follows the word spans
    -- instead of weighting the whole line by byte length.
    wordProgress = wordFill(line.words, position, endMs)
  elseif duration > 0 then
    progress = math.max(0, math.min(1, (position - line.t) / duration))
  end

  local trackProgress = 0
  local lengthMs = currentTrack and currentTrack.lengthMs or 0
  if lengthMs > 0 then
    trackProgress = math.max(0, math.min(1, position / lengthMs))
  end

  publish({
    status = currentStatus,
    current = line.text,
    next = nextLine and nextLine.text or "",
    previous = previousLine and previousLine.text or "",
    progress = progress,
    word_ranges = line.ranges or {},
    word_progress = wordProgress,
    track_progress = trackProgress,
    count = #currentLines,
    line_index = index,
    source = currentSource,
  })
end

local function refreshRequested()
  local request = noctalia.state.get("refresh_request")
  if request == nil or request == lastRefreshRequest then
    return false
  end
  lastRefreshRequest = request
  return true
end

-- ── wallpaper-aware overlay placement ───────────────────────────────────────
-- The wallpaper is analysed once per change: ImageMagick (magick/convert) or
-- ffmpeg scales it to a 48x27 RGB frame, every screen zone is scored by the
-- gradient energy under the type block, and the calm zones are published for
-- the overlay entry. Nothing runs while a track plays.

local WP_COLS, WP_ROWS = 48, 27
local WP_ZONES = {
  { name = "topLeft", x = 22, y = 18 },
  { name = "topCenter", x = 50, y = 18 },
  { name = "topRight", x = 78, y = 18 },
  { name = "centerLeft", x = 22, y = 50 },
  { name = "center", x = 50, y = 50 },
  { name = "centerRight", x = 78, y = 50 },
  { name = "bottomLeft", x = 22, y = 82 },
  { name = "bottomCenter", x = 50, y = 82 },
  { name = "bottomRight", x = 78, y = 82 },
}

local wpPath = ""
local wpCheckedAt = 0
local wpBusy = false
local wpTool = ""
local wpZonesSet = false
local overlayShown = false

local function wallpaperTool()
  if wpTool ~= "" then
    return wpTool ~= "none" and wpTool or nil
  end
  if noctalia.commandExists("magick") then
    wpTool = "magick"
  elseif noctalia.commandExists("convert") then
    wpTool = "convert"
  elseif noctalia.commandExists("ffmpeg") then
    wpTool = "ffmpeg"
  else
    wpTool = "none"
    noctalia.log("lyrics overlay: install ImageMagick or ffmpeg for wallpaper-aware placement")
  end
  return wpTool ~= "none" and wpTool or nil
end

local function focusedConnector()
  if type(noctalia.outputs) == "function" then
    local ok, list = pcall(noctalia.outputs)
    if ok and type(list) == "table" then
      for _, output in ipairs(list) do
        if output.focus == true and output.name then
          return output.name
        end
      end
      if list[1] and list[1].name then
        return list[1].name
      end
    end
  end
  if type(noctalia.focusedOutputName) == "function" then
    local ok, name = pcall(noctalia.focusedOutputName)
    if ok and type(name) == "string" and name ~= "" then
      return name
    end
  end
  return nil
end

local function currentWallpaperPath()
  local output = focusedConnector()
  if type(noctalia.wallpaperPath) == "function" then
    local ok, path = pcall(noctalia.wallpaperPath, output)
    if ok and type(path) == "string" and path ~= "" then
      return path
    end
  end
  if output then
    local path = noctalia.getSetting("wallpaper.monitors." .. output .. ".path")
    if type(path) == "string" and path ~= "" then
      return path
    end
  end
  return ""
end

local function publishCalmZones(raw)
  local lum = {}
  for index = 0, WP_COLS * WP_ROWS - 1 do
    local base = index * 3 + 1
    lum[index] = 0.2126 * string.byte(raw, base) + 0.7152 * string.byte(raw, base + 1)
      + 0.0722 * string.byte(raw, base + 2)
  end
  local energy = {}
  for y = 0, WP_ROWS - 1 do
    for x = 0, WP_COLS - 1 do
      local index = y * WP_COLS + x
      local dx = x > 0 and math.abs(lum[index] - lum[index - 1]) or 0
      local dy = y > 0 and math.abs(lum[index] - lum[index - WP_COLS]) or 0
      energy[index] = dx + dy
    end
  end

  local scored = {}
  for _, zone in ipairs(WP_ZONES) do
    local left = math.max(0, math.floor((zone.x - 27) / 100 * WP_COLS))
    local right = math.min(WP_COLS - 1, math.ceil((zone.x + 27) / 100 * WP_COLS) - 1)
    local top = math.max(0, math.floor((zone.y - 9) / 100 * WP_ROWS))
    local bottom = math.min(WP_ROWS - 1, math.ceil((zone.y + 9) / 100 * WP_ROWS) - 1)
    local sum, cells = 0, 0
    for y = top, bottom do
      for x = left, right do
        sum = sum + energy[y * WP_COLS + x]
        cells = cells + 1
      end
    end
    table.insert(scored, { name = zone.name, score = cells > 0 and sum / cells or 0 })
  end
  table.sort(scored, function(a, b)
    return a.score < b.score
  end)

  local best = scored[1] and scored[1].score or 0
  local limit = math.max(best * 1.6, best + 0.8)
  local calm = {}
  for _, zone in ipairs(scored) do
    if zone.score <= limit then
      table.insert(calm, zone.name)
    end
  end
  if #calm < 3 then
    calm = {}
    for index = 1, math.min(3, #scored) do
      table.insert(calm, scored[index].name)
    end
  end
  publish({ overlay_zones = calm })
  wpZonesSet = true
  noctalia.log("lyrics overlay: calm zones " .. table.concat(calm, ", "))
end

-- Zones describe one picture. Drop them when placement is off, the sampler is
-- missing or a sample fails, so the overlay falls back to the centre zone
-- instead of reusing another wallpaper's zones.
local function clearCalmZones()
  if not wpZonesSet then
    return
  end
  wpZonesSet = false
  noctalia.state.set("overlay_zones", {})
end

-- Called on every service tick, not only when the layer appears: a wallpaper
-- change while the layer stays visible must still trigger exactly one sample.
local function updateWallpaper()
  if cfg("overlay_enabled", false) ~= true or cfg("wallpaper_aware", true) ~= true then
    wpPath = ""
    clearCalmZones()
    return
  end
  local now = noctalia.nowMs()
  if wpBusy or now - wpCheckedAt < 4000 then
    return
  end
  wpCheckedAt = now
  local path = currentWallpaperPath()
  if path == "" then
    wpPath = ""
    clearCalmZones()
    return
  end
  if path == wpPath then
    return
  end
  local tool = wallpaperTool()
  local base = noctalia.pluginDataDir()
  if not tool or not base then
    wpPath = path
    clearCalmZones()
    return
  end
  noctalia.mkdirAll(base)
  local target = base .. "/wallpaper.rgb"
  local argv
  if tool == "ffmpeg" then
    argv = { "ffmpeg", "-v", "error", "-y", "-i", path, "-vf", "scale=48:27",
      "-pix_fmt", "rgb24", "-f", "rawvideo", target }
  else
    argv = { tool, path, "-resize", "48x27!", "-depth", "8", "rgb:" .. target }
  end
  wpBusy = true
  local launched = noctalia.runAsync(argv, function(result)
    wpBusy = false
    -- Record the attempt even on failure so a broken picture is not resampled
    -- every few seconds; a new wallpaper path is picked up on the next tick.
    wpPath = path
    if not result or result.exitCode ~= 0 then
      noctalia.log("lyrics overlay: wallpaper sampling failed for " .. path)
      clearCalmZones()
      return
    end
    local raw = noctalia.readFile(target)
    if not raw or #raw < WP_COLS * WP_ROWS * 3 then
      clearCalmZones()
      return
    end
    publishCalmZones(raw)
  end)
  if launched == false then
    -- The host rejects a launch when its shared async limit is reached and
    -- never calls back, so the busy flag must be released here: otherwise
    -- every later wallpaper change is ignored for the rest of the session.
    wpBusy = false
    wpPath = path
    noctalia.log("lyrics overlay: wallpaper sampler rejected for " .. path)
    clearCalmZones()
  end
end

-- The layer itself is lazy: it only exists while lyrics are actually shown.
local function syncOverlay()
  local want = false
  if cfg("overlay_enabled", false) == true
      and noctalia.state.get("lyrics_hidden") ~= true then
    local status = noctalia.state.get("status") or "idle"
    want = status == "synced" or status == "plain" or status == "loading"
    if want then
      local playing = noctalia.state.get("playing") == true
      local pausedSince = noctalia.state.get("paused_since") or 0
      if not playing and noctalia.state.get("hide_on_pause") ~= false
          and pausedSince > 0 and noctalia.nowMs() - pausedSince >= 1500 then
        want = false
      end
    end
  end
  if want == overlayShown then
    return
  end
  overlayShown = want
  if want then
    noctalia.layer.show("overlay")
  else
    noctalia.layer.hide("overlay")
  end
end

function update()
  noctalia.setUpdateInterval(250)
  syncOverlay()
  updateWallpaper()

  local enabled = cfg("enabled", true)
  local hidden = noctalia.state.get("lyrics_hidden") == true
  if not enabled then
    publishEmpty("off")
    currentTrack = nil
    currentLines = nil
    return
  end

  local player = noctalia.mediaPlayer()
  if not player or not player.title or player.title == "" then
    anchor = { ms = 0, wall = noctalia.nowMs(), status = "Stopped", rate = 1, grace = 0 }
    pausedSince = nil
    currentTrack = nil
    currentLines = nil
    publishEmpty("idle")
    return
  end

  local artists = player.artists and table.concat(player.artists, ", ") or ""
  local key = trackKey(player)
  local url = player.url or ""

  if not playerAllowed(player) or not sourceAllowed(player) then
    currentTrack = nil
    currentLines = nil
    publishEmpty("filtered", player.title, artists)
    return
  end

  local nowMs = noctalia.nowMs()
  local status = player.status or "Stopped"
  local rate = player.rate or 1
  local actual = player.positionMs or 0
  local expected = anchor.ms
  if anchor.status == "Playing" then
    expected = expected + math.max(0, nowMs - anchor.wall) * (anchor.rate or 1)
  end
  local drift = math.abs(actual - expected)
  local statusChanged = status ~= anchor.status
  local inGrace = nowMs < (anchor.grace or 0)
  if statusChanged and status == "Playing" then
    -- Stale MPRIS Position right after resume: keep the pause anchor and let
    -- the local clock continue from there.
    anchor.wall = nowMs
    anchor.status = status
    anchor.rate = rate
    anchor.grace = nowMs + 800
  elseif statusChanged or (not inGrace and (drift > 1200
      or (nowMs - anchor.wall >= 2000 and drift > 150))) then
    anchor.ms = actual
    anchor.wall = nowMs
    anchor.status = status
    anchor.rate = rate
    anchor.grace = 0
  end

  if status ~= "Playing" then
    if not pausedSince then
      pausedSince = nowMs
    end
  else
    pausedSince = nil
  end

  local hideOnPause = cfg("hide_on_pause", true)

  -- Tags alone do not identify a local file: two files with identical tags but
  -- different URLs must each load their own sidecar. The URL is tracked apart
  -- from the LRCLIB cache key, which stays stable across replays.
  local changed = not currentTrack or currentTrack.key ~= key or currentTrack.url ~= url
  if changed then
    currentTrack = {
      key = key,
      title = player.title,
      artist = artists,
      album = player.album or "",
      lengthMs = player.lengthMs or 0,
      url = url,
      identity = player.identity or "",
    }
    currentLines = nil
    currentStatus = "loading"
    currentSource = ""
    requestInFlight = ""
    loadGeneration = loadGeneration + 1
    loadDeadlineMs = 0

    publish({
      title = player.title,
      artist = artists,
      album = player.album or "",
      status = "loading",
      current = "",
      next = "",
      previous = "",
      progress = 0,
      plain = "",
      count = 0,
      playing = status == "Playing",
      paused_since = pausedSince or 0,
      hide_on_pause = hideOnPause,
    })

    loadFor(currentTrack)
  elseif refreshRequested() then
    requestInFlight = ""
    currentLines = nil
    currentStatus = "loading"
    loadGeneration = loadGeneration + 1
    loadDeadlineMs = 0
    loadFor(currentTrack, true)
  end

  if currentStatus == "loading" and loadDeadlineMs > 0 and nowMs > loadDeadlineMs then
    loadGeneration = loadGeneration + 1
    loadDeadlineMs = 0
    currentStatus = "error"
    publish({ status = "error" })
  end

  if status ~= "Playing" then
    publish({
      status = currentStatus,
      playing = false,
      paused_since = pausedSince or 0,
      hide_on_pause = hideOnPause,
      title = player.title,
      artist = artists,
      progress = 0,
    })
    return
  end

  local position = anchor.ms + math.max(0, nowMs - anchor.wall) * (anchor.rate or 1)
  noctalia.state.set("playing", true)
  publish({ playing = true, paused_since = 0, hide_on_pause = hideOnPause })
  updatePlayhead(position)
  if hidden then
    noctalia.state.set("status", "hidden")
  end
end

function onEnable()
  noctalia.state.set("lyrics_hidden", false)
  overlayShown = false
  wpCheckedAt = 0
  wpPath = ""
  wpZonesSet = false
  noctalia.state.set("overlay_zones", {})
end

function onConfigChanged()
  -- The overlay entry is rebuilt on its own; here we only follow the settings
  -- that decide whether the layer exists at all.
  syncOverlay()
  updateWallpaper()
end
