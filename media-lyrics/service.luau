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

-- NetEase Cloud Music fallback source (public endpoints, no auth): the
-- cloudsearch and song-lyric APIs need a browser User-Agent and a
-- music.163.com Referer — plain requests return an encrypted blob instead.
local NETEASE_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
local NETEASE_REF = "https://music.163.com/"

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
-- Lyrics embedded in the player's own MPRIS metadata (xesam:asText), cached
-- per track key: the aggregator does not forward the field, so we fetch it
-- directly from the player bus once per track change.
local embeddedCache = ""
local embeddedCacheKey = ""

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

-- NetEase keeps placeholder "lyrics" for instrumentals / missing words
-- (e.g. "[00:00.000] 纯音乐，请欣赏" = "instrumental music, enjoy", or
-- "暂无歌词" = "no lyrics yet"). Those are NOT lyrics: treat the text as
-- empty so the chain keeps hunting / ends with a clean "no lyrics".
local NETEASE_PLACEHOLDERS = { "纯音乐请欣赏", "纯音乐版", "暂无歌词",
  "此歌曲为没有填词的纯音乐", "此歌曲为纯音乐请欣赏", "纯音乐" }
local function isPlaceholderLyrics(raw)
  -- Byte-safe sanitize: multibyte chars must NOT live inside a Lua character
  -- class together with ASCII punctuation — it corrupts UTF-8 bytes. Strip
  -- timestamps + ASCII punctuation first, then full-width chars literally.
  local cleaned = (raw or ""):gsub("%[%d+:%d+%.?%d*%]", "")
  cleaned = cleaned:gsub("[%s,.!?]", "")
  cleaned = cleaned:gsub("，", ""):gsub("。", ""):gsub("．", "")
  cleaned = cleaned:gsub("！", ""):gsub("？", "")
  if cleaned == "" then return false end
  for _, p in ipairs(NETEASE_PLACEHOLDERS) do
    if cleaned == p then return true end
  end
  -- variant lines appended after the phrase (e.g. "...请欣赏，谢谢");
  -- compare CHARACTER length (utf8), not bytes
  local clen = utf8.len(cleaned) or #cleaned
  return clen <= 16 and cleaned:find("纯音乐", 1, true) ~= nil
end

-- chain: local dir -> embedded (xesam:asText) -> cache -> LRCLIB exact ->
-- LRCLIB search -> NetEase fallback
local function loadLyricsForTrack(artist, title, album, durationSec, key, embeddedText)
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

  -- 1.5) lyrics embedded in the player's own metadata (xesam:asText):
  -- exact-track and zero-network; only when the player provides them.
  -- Placeholders are filtered like any other source.
  if embeddedText and trim(embeddedText) ~= "" and not isPlaceholderLyrics(embeddedText) then
    if acceptLyrics(noctalia.tr("provider.embedded"), embeddedText, "", key) then
      return
    end
  end

  -- 2) cache (skip entries that are NetEase-style placeholder text cached
  --    before the placeholder filter existed)
  local cached = loadCachedLyrics(title == "" and "" or artist, title)
  if cached and not isPlaceholderLyrics(cached) then
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
  local function httpGetH(url, headers, cb)
    -- -f: 4xx/5xx -> non-zero exit (treated as fetch failure, not parse error).
    -- exitCode is passed through so callers can tell "HTTP miss" (curl -f
    -- exit 22) from a transport/network failure (DNS, timeout, conn reset).
    local argv = { "curl", "-sSf", "-m", "8", "-4" }
    for _, h in ipairs(headers) do
      argv[#argv + 1] = "-H"
      argv[#argv + 1] = h
    end
    argv[#argv + 1] = url
    noctalia.runAsync(argv, function(result)
      cb({ ok = result.exitCode == 0, status = result.exitCode == 0 and 200 or 0,
        body = result.stdout or "", exit = result.exitCode })
    end)
  end

  local function httpGet(url, cb)
    httpGetH(url, { "User-Agent: " .. LRCLIB_UA }, cb)
  end

  -- ── NetEase Cloud Music fallback (last resort, no auth) ──────────────────
  -- NetEase LRCs open with metadata credit lines (作词/作曲/编曲/Artist: …)
  -- that would render as lyric rows; drop them before parsing.
  local NETEASE_META = {
    "^%s*作词%s*[:：]", "^%s*作曲%s*[:：]", "^%s*编曲%s*[:：]",
    "^%s*制作人%s*[:：]", "^%s*混音%s*[:：]", "^%s*母带%s*[:：]",
    "^%s*录音%s*[:：]", "^%s*监制%s*[:：]", "^%s*和声%s*[:：]",
    "^%s*出品%s*[:：]", "^%s*发行%s*[:：]", "^%s*企划%s*[:：]",
    "^%s*统筹%s*[:：]", "^%s*OP%s*[:：]", "^%s*SP%s*[:：]",
    "^%s*Artist%s*[:：]", "^%s*Album%s*[:：]", "^%s*Producer%s*[:：]",
    "^%s*Composer%s*[:：]", "^%s*Lyricist%s*[:：]",
  }
  local function stripNetEaseMeta(raw)
    local out = {}
    for line in (raw .. "\n"):gmatch("(.-)\n") do
      local text = trim(line)
      if text ~= "" then
        local body = text:gsub("^%[%d+:%d+%.?%d*%]%s*", "")
        local isMeta = false
        for _, p in ipairs(NETEASE_META) do
          if body:match(p) then isMeta = true break end
        end
        if not isMeta then out[#out + 1] = text end
      end
    end
    return table.concat(out, "\n")
  end

  local function ciEq(a, b)
    return trim(a or ""):lower() == trim(b or ""):lower()
  end
  local function ciHas(hay, needle)
    return trim(hay or ""):lower():find(trim(needle or ""):lower(), 1, true) ~= nil
  end

  -- Rank cloudsearch hits: exact/contains matches on title (3/1) and artist
  -- (2/1), plus a duration bonus (2/1) when cloudsearch `dt` (ms) matches the
  -- playing track's length — the timed version of a song is the one whose
  -- timestamps line up. Returns score>0 candidates sorted desc {id, score}.
  local function rankNetEaseSongs(songs, artist, title, durSec)
    local ranked = {}
    for _, s in ipairs(songs) do
      local sname = trim(s.name or "")
      local artists = ""
      local arr = type(s.ar) == "table" and s.ar or type(s.artists) == "table" and s.artists or nil
      if arr then
        local names = {}
        for _, a in ipairs(arr) do names[#names + 1] = a.name or "" end
        artists = table.concat(names, ", ")
      end
      -- Eligibility: when we know the artist, the candidate MUST overlap on
      -- the artist too — a title-only hit for "DNA" happily returns some
      -- Chinese song with the same name (wrong-language lyrics, 2026-09-03).
      -- An empty metadata artist (dirty sources) keeps title-based matching.
      local artistKnown = trim(artist or "") ~= ""
      local titleOk = ciEq(sname, title) or ciHas(sname, title)
      local artistOk = (not artistKnown) or ciEq(artists, artist) or ciHas(artists, artist)
      if titleOk and artistOk then
        local score = 0
      if ciEq(sname, title) then score = score + 3 end
      if ciHas(sname, title) then score = score + 1 end
      if ciEq(artists, artist) then score = score + 2 end
      if ciHas(artists, artist) then score = score + 1 end
      if type(s.dt) == "number" and durSec and durSec > 0 then
        local d = math.abs(s.dt / 1000 - durSec)
        if d < 2 then score = score + 2
        elseif d < 6 then score = score + 1 end
      end
        if score > 0 and type(s.id) == "number" then
          ranked[#ranked + 1] = { id = s.id, score = score }
        end
      end
    end
    table.sort(ranked, function(a, b) return a.score > b.score end)
    return ranked
  end

  -- True when the text carries [mm:ss.xx] timestamps (karaoke-capable).
  local function lrcIsSynced(text)
    return text:match("%[%d+:%d+%.?%d*%]") ~= nil
  end

  -- Accept a candidate and cache it on success. Returns success.
  local function acceptAndCache(provider, synced, plain)
    if acceptLyrics(provider, synced, plain, key) then
      cacheLyrics(artist, title, synced, plain)
      return true
    end
    return false
  end

  local neteaseHeaders = {
    "User-Agent: " .. NETEASE_UA,
    "Referer: " .. NETEASE_REF,
  }

  -- Pick the closest cloudsearch hit, then fetch lyrics for up to 3
  -- candidates. SYNCHRONIZED LRC wins: a plain (untimed) NetEase text is
  -- kept as a fallback while better candidates are still hunted, and an
  -- LRCLIB plain-only hit stashed by the caller is used only when NetEase
  -- produced nothing at all.
  local function fetchNetEaseFallback(artist, title, key, stash)
    if gen ~= fetchGeneration then return end
    -- stash = { provider, synced, plain } (e.g. an LRCLIB plain-only hit).
    local function settle(isError)
      if gen ~= fetchGeneration then return end
      if stash then
        acceptAndCache(stash.provider, stash.synced, stash.plain)
      elseif isError then
        finishError(noctalia.tr("service.lyrics-unreachable"))
      else
        finishEmpty()
      end
    end
    local searchAttempt = 0
    local function trySearch(query)
      if gen ~= fetchGeneration then return end
      local searchUrl = "https://music.163.com/api/cloudsearch/pc?s="
        .. noctalia.string.urlEncode(query) .. "&type=1&offset=0&limit=10"
      httpGetH(searchUrl, neteaseHeaders, function(resp)
        if gen ~= fetchGeneration then return end
        if not resp.ok then
          settle(true)
          return
        end
        local data = type(resp.body) == "string" and noctalia.json.decode(resp.body) or nil
        local songs = data and data.result and type(data.result.songs) == "table"
          and data.result.songs or nil
        if not songs or #songs == 0 then
          -- title-only missed: retry once with "artist title"
          if searchAttempt == 0 and artist ~= "" then
            searchAttempt = 1
            trySearch(artist .. " " .. title)
          else
            settle(false)
          end
          return
        end
        local ranked = rankNetEaseSongs(songs, artist, title, durationSec)
        local tried = 0
        local firstPlain = nil
        local anyNetworkError = false
        local function tryLyric(i)
          if gen ~= fetchGeneration then return end
          if i > #ranked or tried >= 3 then
            if firstPlain then
              acceptAndCache("NetEase", firstPlain, "")
            else
              settle(anyNetworkError)
            end
            return
          end
          tried = tried + 1
          local lyricUrl = "https://music.163.com/api/song/lyric?os=pc&id="
            .. tostring(ranked[i].id) .. "&lv=-1&kv=-1&tv=-1"
          httpGetH(lyricUrl, neteaseHeaders, function(resp)
            if gen ~= fetchGeneration then return end
            if resp.ok and type(resp.body) == "string" then
              local d = noctalia.json.decode(resp.body)
              local lrc = type(d) == "table" and d.lrc and type(d.lrc.lyric) == "string"
                and trim(d.lrc.lyric) or ""
              if lrc ~= "" then
                lrc = stripNetEaseMeta(lrc)
                if trim(lrc) ~= "" then
                  if isPlaceholderLyrics(lrc) then
                    -- instrumental placeholder (纯音乐/暂无歌词): next candidate
                    tryLyric(i + 1)
                    return
                  end
                  if lrcIsSynced(lrc) then
                    if not acceptAndCache("NetEase", lrc, "") then
                      tryLyric(i + 1)  -- parsed but unusable: next candidate
                    end
                    return
                  end
                  -- plain (untimed) LRC: keep as the fallback, keep hunting
                  -- for a synced copy in the remaining candidates
                  if not firstPlain then firstPlain = lrc end
                end
              end
            else
              anyNetworkError = true
            end
            tryLyric(i + 1)
          end)
        end
        tryLyric(1)
      end)
    end
    if title ~= "" then
      trySearch(title)
    else
      settle(false)
    end
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
      local synced = trim(okData.synced or "")
      local plain = trim(okData.plain or "")
      if synced ~= "" then
        -- synced LRCLIB hit: done
        acceptAndCache("LRCLIB", synced, plain)
      elseif plain ~= "" then
        -- LRCLIB has only untimed text: hunt for a synced copy on NetEase
        -- first; the plain text is the fallback if NetEase has nothing.
        fetchNetEaseFallback(artist, title, key,
          { provider = "LRCLIB", synced = "", plain = plain })
      else
        fetchNetEaseFallback(artist, title, key)
      end
      return
    end

    -- Transport failure (DNS / timeout / connection), not an HTTP miss:
    -- curl -f exits 22 for 4xx/5xx; anything else means the request never
    -- completed. music.163.com is a different host, so try the NetEase
    -- fallback before giving up.
    if not resp.ok and resp.exit ~= 22 then
      fetchNetEaseFallback(artist, title, key)
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
            if synced ~= "" then
              if not acceptAndCache("LRCLIB", synced, plain) then
                -- parsed but unusable (instrumental): try NetEase
                fetchNetEaseFallback(artist, title, key, plain ~= "" and
                  { provider = "LRCLIB", synced = "", plain = plain } or nil)
              end
            elseif plain ~= "" then
              -- plain-only LRCLIB hit: prefer a synced NetEase copy
              fetchNetEaseFallback(artist, title, key,
                { provider = "LRCLIB", synced = "", plain = plain })
            else
              fetchNetEaseFallback(artist, title, key)
            end
            return
          end
        end
      end
      -- LRCLIB had no usable hit (or its own transport failed): NetEase is
      -- the last resort.
      fetchNetEaseFallback(artist, title, key)
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

-- Some MPRIS players expose lyrics via xesam:asText in their own Metadata;
-- the Noctalia aggregator does not forward that field, so ask the player bus
-- directly (argv-only busctl, once per track change). The reply is a
-- Properties.Get variant: {type="v", data=[{type="a{sv}", data={...}}]}.
local function fetchEmbeddedLyrics(busName, cb)
  if busName == "" then cb("") return end
  local argv = { "busctl", "--user", "--json=short", "call", busName,
    "/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties", "Get", "ss",
    "org.mpris.MediaPlayer2.Player", "Metadata" }
  noctalia.runAsync(argv, function(r)
    if r.exitCode ~= 0 then cb("") return end
    local payload = noctalia.json.decode(r.stdout or "")
    local outer = payload and payload.data
    if type(outer) ~= "table" then cb("") return end
    local inner = outer[1]
    local fields = (type(inner) == "table" and type(inner.data) == "table") and inner.data or nil
    if type(fields) ~= "table" then cb("") return end
    local v = fields["xesam:asText"]
    if type(v) ~= "table" or v.type ~= "s" then cb("") return end
    cb(tostring(v.data or ""))
  end)
end

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
    local busName = parseBusctlVariant(f.bus_name) or ""
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
      -- claim the key up front: the embedded-metadata fetch below is async,
      -- and without the claim the next 150 ms poll would see a "new" track
      -- and restart the whole load forever.
      currentTrackKey = key
      invalidateLyrics()
      snapshot.lyricsStatus = "loading"
      publish()
      fetchEmbeddedLyrics(busName, function(raw)
        embeddedCache = raw or ""
        embeddedCacheKey = key
        loadLyricsForTrack(artist, title, album, snapshot.lengthSec, key, raw or "")
      end)
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
    loadLyricsForTrack(snapshot.artist, snapshot.title, snapshot.album, snapshot.lengthSec, key,
      (embeddedCacheKey == key) and embeddedCache or "")
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
    loadLyricsForTrack(artist, title, snapshot.album, snapshot.lengthSec, key,
      (embeddedCacheKey == key) and embeddedCache or "")
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