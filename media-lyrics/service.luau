--!nonstrict
-- media-lyrics service: owns all media/lyrics logic, publishes snapshots.
--
-- Port of Clavis's lyrics stack (shell/Services/LyricsTrackService.qml +
-- shell/core/plugin/lyrics/src/lyrics.cpp) to Noctalia v5 Luau:
--   * Clavis MediaManager.active      -> Noctalia D-Bus aggregator
--                                        dev.noctalia.Mpris GetActivePlayer
--                                        (poll via busctl every 150 ms)
--   * Clavis.Lyrics providers         -> LRCLIB /api/get then /api/search
--   * Lyrics::parseLrc / indexForTime -> pure Luau ports below
--   * cache + local dir               -> pluginDataDir()/lyrics + configured dir
-- Publishes a snapshot table to noctalia.state("media") for the panel.

-- 150ms: the panel has no timer of its own (host never calls panel update(),
-- verified by probe) — it animates the marquee from watch("media") ticks.
-- 150ms keeps the scroll smooth (~0.2 char per tick at 24px/s) without
-- hammering MPRIS.
local POLL_MS = 150
local LRCLIB_UA = "media-lyrics/0.1 (Noctalia v5 plugin)"

-- ============================= utility =============================

local function trim(s)
  return noctalia.string.trim(s or "")
end

local function nowMs()
  local ok, v = pcall(function() return noctalia.nowMs() end)
  if ok and type(v) == "number" then return v end
  return os.time() * 1000
end

-- ============================= state =============================

local snapshot = {
  hasPlayer = false,
  playerName = "",
  title = "",
  artist = "",
  album = "",
  artUrl = "",
  playing = false,
  canSeek = false,
  canGoNext = false,
  canGoPrev = false,
  shuffle = false,
  loopStatus = "None",
  lengthSec = 0,
  posSec = 0,
  posAtMs = 0, -- wall-clock ms when posSec was sampled (panel interpolates)
  -- lyrics block
  lyricsStatus = "idle", -- idle | loading | ready | empty | error
  lyricsError = "",
  lyricsProvider = "",
  synced = false,
  lyrics = {}, -- { { time = sec, text = "..." }, ... }  (time < 0 = unsynced)
}

-- ============================= LRC parsing (port of Lyrics::parseLrc) =============================

local function fractionalSeconds(frac)
  if not frac or frac == "" then return 0.0 end
  local v = tonumber(frac) or 0
  local n = #frac
  if n == 1 then return v / 10.0 end
  if n == 2 then return v / 100.0 end
  return v / 1000.0
end

local function isMetadataLine(line)
  local l = line:lower()
  return l:match("^%[ar%s*:") ~= nil or l:match("^%[ti%s*:") ~= nil
    or l:match("^%[al%s*:") ~= nil or l:match("^%[by%s*:") ~= nil
    or l:match("^%[re%s*:") ~= nil or l:match("^%[ve%s*:") ~= nil
    or l:match("^%[offset%s*:") ~= nil
end

local function looksLikeMalformedTimestamp(line)
  return line:match("^%[%d+%s*:[^%]]+%]") ~= nil
end

-- Parse an LRC (or plain-text) lyric into a sorted list of { time = sec, text }.
-- time < 0 marks unsynced lines. Mirrors Lyrics::parseLrc from Clavis.
local function parseLrc(text, offsetMs)
  local result = {}
  if trim(text) == "" then return result end

  local fileOffsetMs = 0
  local off = text:match("%[offset%s*:%s*(-?%d+%.?%d*)%]")
  if off then fileOffsetMs = tonumber(off) or 0 end
  local extraOffset = (fileOffsetMs + (offsetMs or 0)) / 1000.0

  for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local timestamps = {}
    local rest = line
    -- consume every leading [mm:ss(.ttt)] timestamp tag (also accepts : or - ms separators)
    while true do
      local min, sec, epos
      local sep, frac
      -- with fractional part
      min, sec, sep, frac, epos = rest:match("^%s*%[(%d+):(%d%d?)([%.:%-])(%d+)%]()")
      if not min then
        -- plain [mm:ss]
        min, sec, epos = rest:match("^%s*%[(%d+):(%d%d?)%]()")
        sep, frac = nil, nil
      end
      if not min then break end
      local ts = tonumber(min) * 60 + tonumber(sec) + fractionalSeconds(frac)
      timestamps[#timestamps + 1] = ts + extraOffset
      rest = rest:sub(epos)
    end

    local lyricText = trim(rest)
    if #timestamps > 0 then
      if lyricText ~= "" then
        for _, t in ipairs(timestamps) do
          result[#result + 1] = { time = t, text = lyricText }
        end
      end
    else
      local trimmedLine = trim(line)
      if not (lyricText == "" or isMetadataLine(trimmedLine) or looksLikeMalformedTimestamp(trimmedLine)) then
        result[#result + 1] = { time = -1.0, text = lyricText }
      end
    end
  end

  -- stable sort: synced lines first (by time), unsynced after, preserving order
  local function keyed(t)
    for i, v in ipairs(result) do
      if v == t then return i end
    end
    return 0
  end
  table.sort(result, function(a, b)
    local at, bt = a.time >= 0, b.time >= 0
    if at ~= bt then return at end
    if at and bt then
      if a.time ~= b.time then return a.time < b.time end
      return keyed(a) < keyed(b) -- stability
    end
    return false
  end)
  return result
end

local function indexForTime(lyrics, positionSeconds)
  if not snapshot.synced or positionSeconds == nil or positionSeconds < 0 then return -1 end
  local lo, hi = 1, #lyrics
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if lyrics[mid].time <= positionSeconds then lo = mid + 1 else hi = mid end
  end
  return lo - 1
end

local function timeForIndex(lyrics, idx)
  if idx < 1 or idx > #lyrics then return -1 end
  local t = lyrics[idx].time
  if t >= 0 then return t end
  return -1
end

-- ============================= cache / local lyrics =============================

local function sanitizePart(s)
  return trim((s or ""):gsub('[%c/\\]', "_"))
end

local function cachePath(artist, title)
  local dir = noctalia.pluginDataDir()
  if not dir then return nil end
  return dir .. "/lyrics/" .. sanitizePart(artist) .. "__" .. sanitizePart(title) .. ".lrc"
end

local function loadCachedLyrics(artist, title)
  if noctalia.getConfig("use_cache") ~= true then return nil end
  local path = cachePath(artist, title)
  if not path then return nil end
  local raw = noctalia.readFile(path)
  if raw and trim(raw) ~= "" then return raw end
  return nil
end

local function cacheLyrics(artist, title, synced, plain)
  if noctalia.getConfig("use_cache") ~= true then return end
  local path = cachePath(artist, title)
  if not path then return end
  local body = synced ~= "" and synced or plain
  if trim(body) == "" then return end
  noctalia.writeFile(path, body)
end

local function tryLocalLyrics(artist, title)
  local dirCfg = noctalia.getConfig("local_lyrics_dir")
  if not dirCfg or trim(dirCfg) == "" then return nil end
  local dir = noctalia.expandPath(dirCfg)
  local base = sanitizePart(artist)
  local candidates = {}
  if base ~= "" then
    candidates[#candidates + 1] = dir .. "/" .. base .. " - " .. sanitizePart(title) .. ".lrc"
  end
  candidates[#candidates + 1] = dir .. "/" .. sanitizePart(title) .. ".lrc"
  for _, path in ipairs(candidates) do
    local raw = noctalia.readFile(path)
    if raw and trim(raw) ~= "" then return raw end
  end
  return nil
end

-- ============================= lyrics pipeline =============================

local currentTrackKey = ""
local fetchGeneration = 0

local function publish()
  noctalia.state.set("media", snapshot)
end

local function acceptLyrics(provider, synced, plain, key)
  local raw = synced ~= "" and synced or plain
  if trim(raw) == "" then return false end
  local offsetMs = tonumber(noctalia.getConfig("offset_ms")) or 0
  local lines = parseLrc(raw, offsetMs)
  if #lines == 0 then return false end

  local hasSynced = false
  for _, l in ipairs(lines) do
    if l.time >= 0 then hasSynced = true break end
  end

  snapshot.lyrics = lines
  snapshot.lyricsStatus = "ready"
  snapshot.lyricsProvider = provider
  snapshot.synced = hasSynced
  snapshot.lyricsError = ""
  currentTrackKey = key
  publish()
  return true
end

local function finishEmpty()
  snapshot.lyrics = {}
  snapshot.lyricsStatus = "empty"
  snapshot.lyricsProvider = ""
  snapshot.synced = false
  snapshot.lyricsError = ""
  if currentTrackKey ~= "" then currentTrackKey = currentTrackKey end
  publish()
end

local function finishError(msg)
  snapshot.lyrics = {}
  snapshot.lyricsStatus = "error"
  snapshot.lyricsProvider = ""
  snapshot.synced = false
  snapshot.lyricsError = msg
  publish()
end

-- chain: local dir -> cache -> LRCLIB exact -> LRCLIB search
local function loadLyricsForTrack(artist, title, album, durationSec, key)
  fetchGeneration = fetchGeneration + 1
  local gen = fetchGeneration
  -- claim the track key up front: while the fetch is in flight, subsequent
  -- refreshPlayer() ticks must treat this track as UNCHANGED (otherwise every
  -- 500ms tick would invalidate the pending fetch and re-start it forever).
  currentTrackKey = key
  snapshot.lyricsStatus = "loading"
  publish()

  if trim(title) == "" then
    finishEmpty()
    return
  end

  -- 1) local directory (default ~/.local/share/media-lyrics)
  local localRaw = tryLocalLyrics(artist, title)
  if localRaw then
    acceptLyrics(noctalia.tr("provider.local"), localRaw, "", key)
    return
  end

  -- 2) cache
  local cached = loadCachedLyrics(title == "" and "" or artist, title)
  if cached then
    acceptLyrics(noctalia.tr("provider.cache"), cached, "", key)
    return
  end

  -- 3) LRCLIB exact /api/get (fast endpoint), 4) /api/search fallback
  local getUrl = "https://lrclib.net/api/get?track_name=" .. noctalia.string.urlEncode(title)
    .. "&artist_name=" .. noctalia.string.urlEncode(artist)
  if album ~= "" then getUrl = getUrl .. "&album_name=" .. noctalia.string.urlEncode(album) end
  if durationSec and durationSec > 0 then
    getUrl = getUrl .. "&duration=" .. tostring(math.floor(durationSec + 0.5))
  end

  -- fetch via external curl: the built-in noctalia.http hangs against lrclib.net
  -- on this setup (curl=28 timeout, 30s, 0 bytes) while the curl CLI resolves
  -- IPv4 happily (~50ms). Force IPv4 and a short timeout.
  local function httpGet(url, cb)
    -- -f: 4xx/5xx -> non-zero exit (treated as fetch failure, not parse error).
    -- exitCode is passed through so callers can tell "HTTP miss" (curl -f
    -- exit 22) from a transport/network failure (DNS, timeout, conn reset).
    noctalia.runAsync({ "curl", "-sSf", "-m", "8", "-4",
      "-H", "User-Agent: " .. LRCLIB_UA, url }, function(result)
      cb({ ok = result.exitCode == 0, status = result.exitCode == 0 and 200 or 0,
        body = result.stdout or "", exit = result.exitCode })
    end)
  end

  httpGet(getUrl, function(resp)
    if gen ~= fetchGeneration then return end
    local okData = nil
    if resp.ok and resp.status == 200 and type(resp.body) == "string" then
      local data = noctalia.json.decode(resp.body)
      if type(data) == "table" and (trim(data.syncedLyrics or "") ~= "" or trim(data.plainLyrics or "") ~= "") then
        okData = { synced = trim(data.syncedLyrics or ""), plain = trim(data.plainLyrics or "") }
      end
    end

    if okData then
      if acceptLyrics("LRCLIB", okData.synced, okData.plain, key) then
        cacheLyrics(artist, title, okData.synced, okData.plain)
      end
      return
    end

    -- Transport failure (DNS / timeout / connection), not an HTTP miss:
    -- curl -f exits 22 for 4xx/5xx; anything else means the request never
    -- completed, so a search against the same host would fail the same way.
    -- Surface a real error instead of the misleading "no lyrics found".
    if not resp.ok and resp.exit ~= 22 then
      if gen == fetchGeneration then
        finishError(noctalia.tr("service.lyrics-unreachable"))
      end
      return
    end

    -- search fallback
    local searchUrl = "https://lrclib.net/api/search?track_name=" .. noctalia.string.urlEncode(title)
      .. "&artist_name=" .. noctalia.string.urlEncode(artist)
    httpGet(searchUrl, function(resp2)
      if gen ~= fetchGeneration then return end
      if resp2.ok and resp2.status == 200 and type(resp2.body) == "string" then
        local list = noctalia.json.decode(resp2.body)
        if type(list) == "table" and #list > 0 then
          local best, bestScore = nil, -1
          for _, cand in ipairs(list) do
            local score = 0
            if trim(cand.artistName or "") == artist then score = score + 2 end
            if trim(cand.trackName or "") == title then score = score + 2 end
            if trim(cand.syncedLyrics or "") ~= "" then score = score + 1 end
            if score > bestScore then best, bestScore = cand, score end
          end
          if best then
            local synced = trim(best.syncedLyrics or "")
            local plain = trim(best.plainLyrics or "")
            -- accept may fail on an instrumental hit (empty lyrics): end the
            -- pipeline with "empty", otherwise the status sticks at "loading"
            if acceptLyrics("LRCLIB", synced, plain, key) then
              cacheLyrics(artist, title, synced, plain)
            else
              finishEmpty()
            end
            return
          end
        end
      end
      if not resp2.ok and resp2.exit ~= 22 then
        if gen == fetchGeneration then
          finishError(noctalia.tr("service.lyrics-unreachable"))
        end
        return
      end
      finishEmpty()
    end)
  end)
end

local function invalidateLyrics()
  fetchGeneration = fetchGeneration + 1
  snapshot.lyrics = {}
  snapshot.lyricsStatus = "idle"
  snapshot.lyricsProvider = ""
  snapshot.synced = false
  snapshot.lyricsError = ""
end

-- ============================= MPRIS via busctl =============================

local GET_ACTIVE = { "busctl", "--user", "--json=short", "call", "dev.noctalia.Mpris",
  "/dev/noctalia/Mpris", "dev.noctalia.Mpris", "GetActivePlayer" }

local function parseBusctlVariant(v)
  if type(v) ~= "table" or v.type == nil then return nil end
  local t, d = v.type, v.data
  if t == "s" then return d end
  if t == "b" then return d == true end
  if t == "x" or t == "d" or t == "i" or t == "u" then return tonumber(d) end
  if t == "as" and type(d) == "table" then return table.concat(d, ", ") end
  return d
end

local function clearPlayer()
  if snapshot.hasPlayer or snapshot.title ~= "" then
    snapshot.hasPlayer = false
    snapshot.title, snapshot.artist, snapshot.album, snapshot.artUrl = "", "", "", ""
    snapshot.playing = false
    invalidateLyrics()
    publish()
  end
end

local refreshInFlight = false

local function refreshPlayer()
  if refreshInFlight then return end
  refreshInFlight = true
  noctalia.runAsync(GET_ACTIVE, function(result)
    refreshInFlight = false
    if result.exitCode ~= 0 or trim(result.stdout or "") == "" then
      clearPlayer()
      return
    end

    -- busctl --json=short wraps the reply: { type = "ba{sv}", data = [ found, fields ] }
    local payload = noctalia.json.decode(result.stdout)
    local body = payload and payload.data
    if type(body) ~= "table" or type(body[1]) ~= "boolean" then return end
    if not body[1] or type(body[2]) ~= "table" then
      clearPlayer()
      return
    end

    local f = body[2]
    local title = parseBusctlVariant(f.title) or ""
    local artist = parseBusctlVariant(f.artists) or ""
    local album = parseBusctlVariant(f.album) or ""
    -- art_url comes as file:// URI; ui.image expects a filesystem path
    local artUrl = parseBusctlVariant(f.art_url) or ""
    artUrl = artUrl:gsub("^file://", "")
    local playing = (parseBusctlVariant(f.playback_status) == "Playing")
    local lengthUs = tonumber(parseBusctlVariant(f.length_us)) or 0
    local posUs = tonumber(parseBusctlVariant(f.position_us)) or 0
    local ident = parseBusctlVariant(f.identity) or parseBusctlVariant(f.bus_name) or ""
    local canSeek = parseBusctlVariant(f.can_seek) == true
    local canNext = parseBusctlVariant(f.can_go_next) == true
    local canPrev = parseBusctlVariant(f.can_go_previous) == true
    local shuffle = parseBusctlVariant(f.shuffle) == true
    local loopStatus = parseBusctlVariant(f.loop_status) or "None"

    local key = ident .. "|" .. title .. "|" .. artist .. "|" .. tostring(lengthUs)
    local trackChanged = (not snapshot.hasPlayer) or (currentTrackKey ~= key)

    snapshot.hasPlayer = true
    snapshot.playerName = ident
    snapshot.title = title
    snapshot.artist = artist
    snapshot.album = album
    snapshot.artUrl = artUrl
    snapshot.playing = playing
    snapshot.canSeek = canSeek
    snapshot.canGoNext = canNext
    snapshot.canGoPrev = canPrev
    snapshot.shuffle = shuffle
    snapshot.loopStatus = loopStatus
    snapshot.lengthSec = lengthUs / 1e6
    snapshot.posSec = posUs / 1e6
    snapshot.posAtMs = nowMs()

    if trackChanged then
      invalidateLyrics()
      publish()
      loadLyricsForTrack(artist, title, album, snapshot.lengthSec, key)
    else
      publish()
    end
  end)
end

-- ============================= command channel =============================

local function busctlCall(method, argType, argValue)
  local argv = { "busctl", "--user", "call", "dev.noctalia.Mpris", "/dev/noctalia/Mpris",
    "dev.noctalia.Mpris", method }
  -- busctl requires the D-Bus signature for typed arguments ("Too few
  -- parameters for signature" otherwise); methods without args need none.
  if argType then
    argv[#argv + 1] = argType
    argv[#argv + 1] = tostring(argValue)
  end
  noctalia.runAsync(argv)
end

noctalia.state.watch("panel_cmd", function(value)
  if type(value) ~= "table" or value.action == nil then return end
  local a = value.action
  if a == "toggle" then
    busctlCall("PlayPauseActive")
  elseif a == "next" then
    busctlCall("NextActive")
  elseif a == "prev" then
    busctlCall("PreviousActive")
  elseif a == "shuffle" then
    busctlCall("SetShuffleActive", "b", tostring(not snapshot.shuffle))
  elseif a == "loop" then
    local order = { None = "Playlist", Playlist = "Track", Track = "None" }
    local nextLoop = order[snapshot.loopStatus] or "None"
    busctlCall("SetLoopStatusActive", "s", nextLoop)
  elseif a == "seekTo" then
    local sec = tonumber(value.sec)
    if sec then
      -- SetPositionActive is ABSOLUTE (like MPRIS SetPosition); SeekActive
      -- is RELATIVE (MPRIS Seek) and would jump by the timestamp, not to it.
      busctlCall("SetPositionActive", "x", math.floor(sec * 1e6 + 0.5))
    end
  end
  -- refresh promptly after a command
  local gen = fetchGeneration
  noctalia.runAsync({ "sleep", "0.35" }, function()
    if gen == fetchGeneration then refreshPlayer() end
  end)
end)

noctalia.state.watch("panel_req", function(value)
  if type(value) ~= "table" then return end
  if value.action == "refresh" then
    refreshPlayer()
  elseif value.action == "reloadLyrics" then
    -- same track key format as refreshPlayer (lengthUs integer, not float)
    local key = snapshot.playerName .. "|" .. snapshot.title .. "|" .. snapshot.artist
      .. "|" .. tostring(math.floor(snapshot.lengthSec * 1e6 + 0.5))
    loadLyricsForTrack(snapshot.artist, snapshot.title, snapshot.album, snapshot.lengthSec, key)
  end
end)

-- ============================= lifecycle =============================

function onConfigChanged()
  -- settings changed (e.g. offset_ms): rebuild the timeline for the current track
  local artist, title = snapshot.artist, snapshot.title
  invalidateLyrics()
  refreshPlayer()
  if title ~= "" then
    local key = snapshot.playerName .. "|" .. title .. "|" .. artist .. "|" .. tostring(snapshot.lengthSec * 1e6)
    loadLyricsForTrack(artist, title, snapshot.album, snapshot.lengthSec, key)
  end
end

function onEnable()
  publish()
  refreshPlayer()
end

function update()
  refreshPlayer()
end

noctalia.setUpdateInterval(POLL_MS)