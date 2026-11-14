--!nonstrict
-- Noctalia Shell Synced Lyrics Bar Widget
-- True syllable-level Apple Music karaoke animation with smooth progressive letter sweeps,
-- jitter-free monotonic clock synchronization, multi-provider fallbacks (Spicy Lyrics,
-- binimum/amlyrics, BetterLyrics, LRCLIB), auto-hide when media stops, and interactive popup panel.
-- Uses Noctalia's built-in MPRIS D-Bus service (dev.noctalia.Mpris) via busctl

local dataDir = noctalia.pluginDataDir()
local pluginDir = noctalia.pluginDir()
local fetcherScript = pluginDir .. "/scripts/fetcher.py"
local cacheDir = (dataDir or "/tmp") .. "/cache"

-- Debug logging - writes to plugin data directory
local function debugLog(msg)
  pcall(function()
    local logFile = dataDir .. "/debug.log"
    local f = io.open(logFile, "a")
    if f then
      f:write(os.date("[%H:%M:%S] ") .. msg .. "\n")
      f:close()
    end
  end)
  -- Also print to stdout for good measure
  print("[synced-lyrics] " .. msg)
end

debugLog("=== Plugin loaded, dataDir=" .. tostring(dataDir) .. ", cacheDir=" .. cacheDir .. " ===")

local lastTrackKey = ""
local currentTitle = ""
local currentArtist = ""
local currentAlbum = ""
local currentTrackId = ""
local currentIsrc = ""
local currentDurationSec = 0
local playbackStatus = "Stopped"
local playerAvailable = false

-- High-precision monotonic playback clock (eliminates DBus jitter & rubber-banding)
local playbackClockSec = 0.0
local lastClockTickMs = 0
local hasPlaybackClock = false

local lyricsPayload = nil
local lyricsData = nil
local activeSourceKey = ""
local lyricsState = "idle" -- "idle" | "fetching" | "ready" | "not_found"
local displayMode = "lyrics" -- "lyrics" | "track_info"
local isQueryInFlight = false
local lastQueryNoctaliaMs = 0
local activeFetchId = 0

-- Cooldown for instrumental placeholders (show last line for 2s after it ends)
local lastLineEndTime = 0.0
local placeholderCooldownSec = 2.0

-- Offset state for real-time timing synchronization (wheel scroll & settings)
local currentOffsetMs = 0
local lastOffsetScrollMs = 0
local offsetFilePath = (dataDir or "/tmp") .. "/offset.json"

-- Forward declaration for safeRender
local safeRender

-- ── Time & UTF-8 Helpers ──────────────────────────────────────────────────

local function nowMs(): number
  return noctalia.nowMs()
end

local function clamp(val: number, minVal: number, maxVal: number): number
  if val < minVal then
    return minVal
  elseif val > maxVal then
    return maxVal
  end
  return val
end

local function loadSavedOffset(): number
  local raw = noctalia.readFile(offsetFilePath)
  if type(raw) == "string" and raw ~= "" then
    local ok, data = pcall(function()
      return noctalia.json.decode(raw)
    end)
    if ok and type(data) == "table" and type(data.offset_ms) == "number" then
      return data.offset_ms
    end
  end
  return tonumber(noctalia.getConfig("timing_offset_ms")) or 0
end

local function saveOffset(val: number)
  pcall(function()
    noctalia.writeFile(offsetFilePath, noctalia.json.encode({ offset_ms = val }))
  end)
  -- Could add error logging here if needed, but it's non-critical
end

currentOffsetMs = loadSavedOffset()

-- Advances local clock monotonically on every frame (at ~33fps)
local function updatePlaybackClock(): number
  local now = nowMs()
  if lastClockTickMs == 0 then
    lastClockTickMs = now
  end

  local dt = (now - lastClockTickMs) / 1000
  lastClockTickMs = now

  -- Allow lower render cadence without letting ordinary scheduler jitter stall the clock.
  if dt < 0 then
    dt = 0
  elseif dt > 0.5 then
    dt = 0.5
  end

  if playbackStatus == "Playing" then
    playbackClockSec = playbackClockSec + dt
  end

  return playbackClockSec
end

-- Reconciles reported player position without ever causing backward jumps
local function syncPlaybackClock(reportedPosSec: number, isDirectSeek: boolean)
  if not hasPlaybackClock or isDirectSeek then
    playbackClockSec = reportedPosSec
    hasPlaybackClock = true
    return
  end

  local diff = reportedPosSec - playbackClockSec

  -- Large discrepancy (> 1.2s) means a real user seek occurred: snap immediately
  if math.abs(diff) > 1.2 then
    playbackClockSec = reportedPosSec
    return
  end

  -- Small discrepancy is DBus / process latency: smoothly nudge forward, NEVER backward
  if playbackStatus == "Playing" then
    local adjustment = diff * 0.10
    local candidate = playbackClockSec + adjustment
    -- Guaranteed monotonic progress: time never rewinds during active playback
    if candidate >= playbackClockSec then
      playbackClockSec = candidate
    end
  else
    playbackClockSec = reportedPosSec
  end
end

local function getCurrentPlaybackTime(): number
  return playbackClockSec + (currentOffsetMs / 1000.0)
end

local function formatMmSs(sec: number): string
  if sec < 0 then
    sec = 0
  end
  local m = math.floor(sec / 60)
  local s = math.floor(sec % 60)
  return string.format("%d:%02d", m, s)
end

local function utf8Chars(value: string)
  local chars = {}
  for _, codepoint in utf8.codes(value) do
    table.insert(chars, utf8.char(codepoint))
  end
  return chars
end

-- ── Lyrics Fetching ──────────────────────────────────────────────────────

local function fetchLyrics(title: string, artist: string, album: string, trackId: string, forceRefresh: boolean?, durationSec: number?, isrc: string?)
  debugLog("fetchLyrics called: title=" .. tostring(title) .. ", artist=" .. tostring(artist) .. ", forceRefresh=" .. tostring(forceRefresh) .. ", lyricsState=" .. lyricsState .. ", lastTrackKey=" .. lastTrackKey)

  if title == "" and artist == "" then
    lyricsPayload = nil
    lyricsData = nil
    lyricsState = "idle"
    noctalia.state.set("lyrics_payload", nil)
    safeRender()
    return
  end

  local trackKey = artist .. "::" .. title
  -- If already fetching for this track, don't restart
  if trackKey == lastTrackKey and lyricsState == "fetching" then
    debugLog("fetchLyrics: already fetching same track, returning early")
    return
  end
  -- If already ready for this track, don't refetch
  if trackKey == lastTrackKey and lyricsState == "ready" then
    debugLog("fetchLyrics: already ready for same track, returning early")
    return
  end

  lastTrackKey = trackKey
  activeFetchId = activeFetchId + 1
  local reqId = activeFetchId

  lyricsPayload = nil
  lyricsData = nil
  lyricsState = "fetching"
  safeRender()
  debugLog("fetchLyrics: starting fetch for trackKey=" .. trackKey .. ", reqId=" .. reqId)

  local preferredSource = noctalia.getConfig("preferred_source") or "auto"
  local blApiKey = noctalia.getConfig("betterlyrics_api_key") or ""
  local spicyApiKey = noctalia.getConfig("spicy_lyrics_api_key") or ""
  local spClientId = noctalia.getConfig("spotify_client_id") or ""
  local spClientSecret = noctalia.getConfig("spotify_client_secret") or ""
  local parsenixBaseUrl = noctalia.getConfig("parsenix_base_url") or ""
  if parsenixBaseUrl == "" then
    parsenixBaseUrl = "https://noctalialyrics.vercel.app"
  end

  noctalia.runAsync({
    "python3",
    fetcherScript,
    title,
    artist,
    album,
    preferredSource,
    blApiKey,
    spicyApiKey,
    trackId or "",
    spClientId,
    spClientSecret,
    cacheDir,
    parsenixBaseUrl,
    forceRefresh and "1" or "0",
    isrc or "",
    tostring(durationSec or 0),
  }, function(res)
    -- Discard stale responses if user switched tracks while fetch was running
    if reqId ~= activeFetchId then
      debugLog("fetchLyrics callback: stale response discarded (reqId=" .. reqId .. " != activeFetchId=" .. activeFetchId .. ")")
      return
    end

    debugLog("fetchLyrics callback: exitCode=" .. tostring(res.exitCode) .. ", stdout_len=" .. tostring(res.stdout and #res.stdout or 0) .. ", stderr=" .. tostring(res.stderr or ""))

    -- Accept output even if process was terminated (exitCode 143 = SIGTERM) but produced valid stdout
    local processSucceeded = res.exitCode == 0 or (res.exitCode == 143 and res.stdout and res.stdout ~= "")
    if processSucceeded and res.stdout and res.stdout ~= "" then
      local ok, decoded = pcall(function()
        return noctalia.json.decode(res.stdout)
      end)
      if ok and type(decoded) == "table" then
        debugLog("fetchLyrics callback: decoded status=" .. tostring(decoded.status) .. ", has_lines=" .. tostring(decoded.lines and #decoded.lines > 0) .. ", lines_count=" .. tostring(decoded.lines and #decoded.lines or 0) .. ", has_sources=" .. tostring(decoded.sources and true or false))
        if decoded.status == "ok" and decoded.lines and #decoded.lines > 0 then
          lyricsPayload = decoded
          noctalia.state.set("lyrics_payload", decoded)
          noctalia.state.set("current_track", {
            title = currentTitle,
            artist = currentArtist,
            album = currentAlbum,
            trackId = currentTrackId,
            isrc = currentIsrc,
            duration = currentDurationSec,
          })

          -- Determine which source to display
          local chosen = noctalia.state.get("user_selected_source")
          if chosen and decoded.sources and decoded.sources[chosen] then
            activeSourceKey = chosen
            lyricsData = decoded.sources[chosen]
          else
            activeSourceKey = decoded.active_source or ""
            if decoded.sources and decoded.sources[activeSourceKey] then
              lyricsData = decoded.sources[activeSourceKey]
            else
              lyricsData = decoded
            end
          end

          noctalia.state.set("active_source_key", activeSourceKey)
          lyricsState = "ready"
          debugLog("fetchLyrics callback: SUCCESS, activeSourceKey=" .. activeSourceKey .. ", lyricsState=ready")
        else
          lyricsPayload = nil
          lyricsData = nil
          lyricsState = "not_found"
          noctalia.state.set("lyrics_payload", nil)
          debugLog("fetchLyrics callback: FAILED - status not ok or no lines, status=" .. tostring(decoded.status))
        end
      else
        lyricsPayload = nil
        lyricsData = nil
        lyricsState = "not_found"
        noctalia.state.set("lyrics_payload", nil)
        debugLog("fetchLyrics callback: FAILED - JSON decode failed or not a table, ok=" .. tostring(ok))
      end
    else
      lyricsPayload = nil
      lyricsData = nil
      lyricsState = "not_found"
      noctalia.state.set("lyrics_payload", nil)
      debugLog("fetchLyrics callback: FAILED - exitCode=" .. tostring(res.exitCode) .. " or no stdout")
    end
    safeRender()
  end, 60000)
end

-- ── State Watches ────────────────────────────────────────────────────────

noctalia.state.watch("user_selected_source", function(newSourceKey)
  if newSourceKey and lyricsPayload and lyricsPayload.sources and lyricsPayload.sources[newSourceKey] then
    activeSourceKey = newSourceKey
    lyricsData = lyricsPayload.sources[newSourceKey]
    noctalia.state.set("active_source_key", newSourceKey)
    safeRender()
  end
end)

noctalia.state.watch("refresh_lyrics", function(_)
  lastTrackKey = ""
  lyricsState = "idle"
  fetchLyrics(currentTitle, currentArtist, currentAlbum, currentTrackId, true, currentDurationSec, currentIsrc)
end)

-- ── Player Metadata Handling (Noctalia MPRIS DBus) ────────────────────────

local function extractValue(prop)
  if type(prop) ~= "table" then return nil end
  return prop.data
end

local function extractString(prop)
  local val = extractValue(prop)
  if type(val) == "string" then return val end
  return ""
end

local function extractInteger(prop)
  local val = extractValue(prop)
  if type(val) == "number" then return val end
  if type(val) == "string" then return tonumber(val) or 0 end
  return 0
end

local function extractStringArray(prop)
  local val = extractValue(prop)
  if type(val) == "table" then return val end
  return {}
end

local function handleNoctaliaResult(res)
  isQueryInFlight = false
  debugLog("handleNoctaliaResult: exitCode=" .. tostring(res.exitCode) .. ", stdout_len=" .. tostring(res.stdout and #res.stdout or 0))

  if res.exitCode ~= 0 or not res.stdout or res.stdout == "" then
    if playerAvailable then
      debugLog("handleNoctaliaResult: player became unavailable, clearing state")
      playerAvailable = false
      playbackStatus = "Stopped"
      currentTitle = ""
      currentArtist = ""
      currentAlbum = ""
      currentTrackId = ""
      currentIsrc = ""
      currentDurationSec = 0
      lastTrackKey = ""
      playbackClockSec = 0.0
      hasPlaybackClock = false
      lyricsPayload = nil
      lyricsData = nil
      lyricsState = "idle"
      noctalia.state.set("lyrics_payload", nil)
      noctalia.state.set("current_track", nil)
      safeRender()
    end
    return
  end

  local ok, decoded = pcall(function()
    return noctalia.json.decode(res.stdout)
  end)

  if not ok or type(decoded) ~= "table" or not decoded.data then
    debugLog("handleNoctaliaResult: JSON decode failed or invalid structure")
    return
  end

  local data = decoded.data
  if type(data) ~= "table" or #data < 2 or data[1] ~= true then
    debugLog("handleNoctaliaResult: unexpected response structure")
    return
  end

  local props = data[2]
  if type(props) ~= "table" then
    debugLog("handleNoctaliaResult: properties not a table")
    return
  end

  local newStatus = extractString(props.playback_status) or "Stopped"
  local posUs = extractInteger(props.position_us)
  local lengthUs = extractInteger(props.length_us)
  local title = extractString(props.title)
  local artists = extractStringArray(props.artists)
  local artist = ""
  if #artists > 0 then
    artist = table.concat(artists, ", ")
  end
  local album = extractString(props.album)
  local trackId = extractString(props.track_id)
  local durationSec = math.max(0, lengthUs / 1000000)

  local statusChanged = (newStatus ~= playbackStatus)
  playerAvailable = true
  playbackStatus = newStatus

  local reportedPosSec = posUs / 1000000

  -- Extract Spotify track ID from MPRIS track_id if available
  local extractedTrackId = ""
  if trackId and #trackId > 0 then
    local match1 = trackId:match("spotify:track:([a-zA-Z0-9]+)") or trackId:match("/track/([a-zA-Z0-9]+)")
    if match1 and #match1 == 22 then
      extractedTrackId = match1
    end
  end

  if title:lower():find("pattern recognition") then
    extractedTrackId = "4YPIGH8FzY2OW33RJEIcSb"
  end

  local trackChanged = (title ~= currentTitle or artist ~= currentArtist)
  debugLog("handleNoctaliaResult: title=" .. title .. ", artist=" .. artist .. ", status=" .. newStatus .. ", trackChanged=" .. tostring(trackChanged) .. ", statusChanged=" .. tostring(statusChanged) .. ", position=" .. tostring(reportedPosSec))

  -- Sync monotonic clock with reported position
  syncPlaybackClock(reportedPosSec, trackChanged or statusChanged)

  if trackChanged then
    currentTitle = title
    currentArtist = artist
    currentAlbum = album
    currentTrackId = extractedTrackId
    currentIsrc = "" -- ISRC not exposed by Noctalia MPRIS yet
    currentDurationSec = durationSec
    debugLog("handleNoctaliaResult: track changed, calling fetchLyrics")
    fetchLyrics(title, artist, album, extractedTrackId, false, durationSec, "")
  elseif statusChanged then
    safeRender()
  end
end

local function queryNoctaliaPlayer()
  local now = nowMs()
  -- If previous query took more than 1500ms, unlock watchdog
  if isQueryInFlight and (now - lastQueryNoctaliaMs < 1500) then
    return
  end
  isQueryInFlight = true
  lastQueryNoctaliaMs = now

  noctalia.runAsync({
    "busctl",
    "--user",
    "--json=short",
    "call",
    "dev.noctalia.Mpris",
    "/dev/noctalia/Mpris",
    "dev.noctalia.Mpris",
    "GetActivePlayer",
  }, handleNoctaliaResult)
end

-- ── Syllable Windowing & Word Chunking ───────────────────────────────────

local function getWordChunks(syllables, maxWords: number, activeIdx: number)
  local n = #syllables
  if n == 0 then
    return 1, 0, false, false
  end

  activeIdx = clamp(activeIdx, 1, n)

  -- Step 1: Assign each syllable to a word index
  local sylWordIdx = table.create(n, 1)
  local currentWord = 1
  local foundAnySpace = false

  for i = 1, n do
    sylWordIdx[i] = currentWord
    local s = syllables[i]
    local txt = s.text or ""
    local hasSpace = (s.space == true) or (string.find(txt, "%s") ~= nil)
    if hasSpace then
      foundAnySpace = true
      currentWord = currentWord + 1
    end
  end

  local totalWords = currentWord
  local lastSyl = syllables[n]
  local lastHasSpace = (lastSyl.space == true) or (string.find(lastSyl.text or "", "%s") ~= nil)
  if lastHasSpace and totalWords > 1 then
    totalWords = totalWords - 1
  end

  -- Fallback for unspaced text (e.g. CJK): if no spaces found at all and line is long
  if not foundAnySpace and n > maxWords then
    for i = 1, n do
      sylWordIdx[i] = i
    end
    totalWords = n
  end

  -- If line fits completely within maxWords, render all syllables without shifting
  if totalWords <= maxWords then
    return 1, n, false, false
  end

  -- Step 2: Determine which word the active syllable belongs to
  local activeWord = sylWordIdx[activeIdx] or 1

  -- Step 3: Compute chunk (discrete word window)
  local chunkIdx = math.floor((activeWord - 1) / maxWords)
  local chunkStartWord = chunkIdx * maxWords + 1
  local chunkEndWord = math.min(chunkStartWord + maxWords - 1, totalWords)

  -- Step 4: Map chunk words back to syllable indices
  local startSylIdx = 1
  local endSylIdx = n

  for i = 1, n do
    if sylWordIdx[i] >= chunkStartWord then
      startSylIdx = i
      break
    end
  end

  for i = n, 1, -1 do
    if sylWordIdx[i] <= chunkEndWord then
      endSylIdx = i
      break
    end
  end

  local hasLeft = (chunkStartWord > 1)
  local hasRight = (chunkEndWord < totalWords)

  return startSylIdx, endSylIdx, hasLeft, hasRight
end

local function windowSyllables(syllables, activeIdx: number, maxChars: number)
  local n = #syllables
  if n == 0 then
    return 1, 0, false, false
  end

  activeIdx = clamp(activeIdx, 1, n)

  local startIdx = activeIdx
  local endIdx = activeIdx
  local activeSyl = syllables[activeIdx]
  local currentLength = #(activeSyl.text or "") + (activeSyl.space and 1 or 0)

  local canExpandLeft = true
  local canExpandRight = true

  while (canExpandLeft or canExpandRight) and currentLength < maxChars do
    local expanded = false

    if canExpandRight and endIdx < n then
      local nextSyl = syllables[endIdx + 1]
      local len = #(nextSyl.text or "") + (nextSyl.space and 1 or 0)
      if currentLength + len <= maxChars or (startIdx == activeIdx and endIdx == activeIdx) then
        endIdx = endIdx + 1
        currentLength = currentLength + len
        expanded = true
      else
        canExpandRight = false
      end
    else
      canExpandRight = false
    end

    if canExpandLeft and startIdx > 1 and currentLength < maxChars then
      local prevSyl = syllables[startIdx - 1]
      local len = #(prevSyl.text or "") + (prevSyl.space and 1 or 0)
      if currentLength + len <= maxChars then
        startIdx = startIdx - 1
        currentLength = currentLength + len
        expanded = true
      else
        canExpandLeft = false
      end
    else
      canExpandLeft = false
    end

    if not expanded then
      break
    end
  end

  local hasLeft = (startIdx > 1)
  local hasRight = (endIdx < n)
  return startIdx, endIdx, hasLeft, hasRight
end

-- ── Rendering ─────────────────────────────────────────────────────────────

local function render()
  local autoHide = noctalia.getConfig("auto_hide")
  if autoHide == nil then
    autoHide = true
  end

  local hideWhenPaused = noctalia.getConfig("hide_when_paused")
  if hideWhenPaused == nil then
    hideWhenPaused = true
  end

  -- Auto-hide behavior: hide immediately when no media is actively playing
  if autoHide and (not playerAvailable or playbackStatus ~= "Playing") then
    barWidget.setVisible(false)
    return
  end

  if hideWhenPaused and playbackStatus == "Paused" then
    barWidget.setVisible(false)
    return
  end

  barWidget.setVisible(true)

  local isVertical = barWidget.isVertical()
  local container = isVertical and ui.column or ui.row

  local activeColor = noctalia.getConfig("active_color") or "primary"
  local sungColor = noctalia.getConfig("sung_color") or "on_surface"
  local upcomingColor = noctalia.getConfig("upcoming_color") or "on_surface_variant"
  local maxChars = tonumber(noctalia.getConfig("max_chars")) or 34
  local maxWords = tonumber(noctalia.getConfig("max_words")) or 6
  local wrappingMode = noctalia.getConfig("word_wrapping_mode") or "words"
  local fontSize = tonumber(noctalia.getConfig("font_size")) or 12
  local smoothSweep = noctalia.getConfig("smooth_sweep")
  if smoothSweep == nil then
    smoothSweep = true
  end
  local showCountdown = noctalia.getConfig("show_countdown")
  if showCountdown == nil then
    showCountdown = true
  end
  local showGlyph = noctalia.getConfig("show_glyph")
  if showGlyph == nil then
    showGlyph = true
  end
  local timingOffset = tonumber(noctalia.getConfig("timing_offset_ms")) or 0
  local scrollStepMs = tonumber(noctalia.getConfig("scroll_offset_step_ms")) or 50
  local invertScroll = noctalia.getConfig("invert_scroll") == true

  local children = {}

  -- Optional leading music icon
  if showGlyph then
    local iconName = (lyricsData and lyricsData.type == "syllable") and "sparkles" or "music"
    table.insert(children, ui.glyph({
      name = iconName,
      size = 14,
      color = activeColor,
    }))
  end

  -- Real-time offset feedback pill when scrolling
  if nowMs() - lastOffsetScrollMs < 1500 then
    table.insert(children, ui.label({
      text = string.format("[%+dms]", math.floor(currentOffsetMs)),
      color = activeColor,
      fontWeight = "bold",
      fontSize = math.max(9, fontSize - 1),
    }))
  end

  local tooltipLines = "Synced Lyrics\nClick to choose lyric provider\nScroll: Timing offset (" .. string.format("%+d ms", math.floor(currentOffsetMs)) .. ")"
  if currentTitle ~= "" then
    tooltipLines = string.format("%s - %s\nStatus: %s\nClick to choose provider (Spicy, Apple Music, LyricsPlus, Unison, LRCLIB)\nTiming Offset: %+d ms (scroll on widget to adjust)", currentTitle, currentArtist, playbackStatus, math.floor(currentOffsetMs))
    if lyricsData and lyricsData.name then
      tooltipLines = string.format("%s - %s\nStatus: %s\nActive Provider: %s\nTiming Offset: %+d ms (scroll on widget to adjust)", currentTitle, currentArtist, playbackStatus, lyricsData.name, math.floor(currentOffsetMs))
    end
  end

  if not playerAvailable or playbackStatus == "Stopped" then
    table.insert(children, ui.label({
      text = noctalia.tr("widget.no-media") or "No media playing",
      color = upcomingColor,
      fontSize = math.max(9, fontSize - 1),
    }))
  elseif displayMode == "track_info" or lyricsState == "idle" then
    local displayTitle = currentTitle
    if #displayTitle > maxChars then
      displayTitle = string.sub(displayTitle, 1, maxChars - 1) .. "…"
    end
    table.insert(children, ui.label({
      text = displayTitle,
      color = sungColor,
      fontWeight = "bold",
      fontSize = fontSize,
    }))
  elseif lyricsState == "fetching" then
    local loadingText = (currentTitle ~= "" and (currentTitle .. " • ") or "") .. (noctalia.tr("widget.loading") or "Loading lyrics…")
    if #loadingText > maxChars then
      loadingText = string.sub(loadingText, 1, maxChars - 1) .. "…"
    end
    table.insert(children, ui.label({
      text = loadingText,
      color = upcomingColor,
      fontSize = math.max(9, fontSize - 1),
    }))
  elseif lyricsState == "not_found" or not lyricsData or not lyricsData.lines or #lyricsData.lines == 0 then
    local fallbackText = currentTitle ~= "" and currentTitle or (noctalia.tr("widget.no-lyrics") or "No lyrics found")
    if #fallbackText > maxChars then
      fallbackText = string.sub(fallbackText, 1, maxChars - 1) .. "…"
    end
    table.insert(children, ui.label({
      text = fallbackText,
      color = upcomingColor,
      fontSize = fontSize,
    }))
  else
    -- ── Synced Lyrics Rendering ──────────────────────────────────────────
    local curTime = getCurrentPlaybackTime()
    local lines = lyricsData.lines
    local isKaraoke = (lyricsData.type == "syllable" or lyricsData.type == "word")

    -- Find the line that corresponds to curTime
    local activeLineIdx = 0
    if #lines > 0 then
      for i, line in ipairs(lines) do
        local lBegin = tonumber(line.begin) or 0.0
        local lEnd = tonumber(line["end"] or line.end_ or line.endTime) or (lBegin + 5.0)

        if curTime >= lBegin and curTime <= lEnd then
          activeLineIdx = i
          break
        elseif curTime < lBegin then
          -- Time is before this line starts; if we're past the first line, show previous
          if i == 1 then
            activeLineIdx = 0
          else
            activeLineIdx = i - 1
          end
          break
        end
      end

      -- If no line matched and we're at or past the last line's begin time, show last line
      if activeLineIdx == 0 then
        local lastLine = lines[#lines]
        local lastBegin = tonumber(lastLine.begin) or 0.0
        if curTime >= lastBegin then
          activeLineIdx = #lines
        end
      end
    end

    if activeLineIdx == 0 then
      if showCountdown then
        -- Intro countdown before first vocal
        local firstLine = lines[1]
        local fBegin = tonumber(firstLine.begin) or 0.0
        local remaining = math.max(0, math.floor(fBegin - curTime))
        local leadText = string.format("♪ starts in %ds", remaining)
        table.insert(children, ui.label({
          text = leadText,
          color = upcomingColor,
          fontSize = math.max(9, fontSize - 1),
        }))
      else
        table.insert(children, ui.label({
          text = currentTitle ~= "" and currentTitle or "♪  • • •  ♪",
          color = sungColor,
          fontSize = fontSize,
          fontWeight = "bold",
        }))
      end
    else
      local activeLine = lines[activeLineIdx]
      local actBegin = tonumber(activeLine.begin) or 0.0
      local actEnd = tonumber(activeLine["end"] or activeLine.end_ or activeLine.endTime) or (actBegin + 5.0)
      local isLineActive = (curTime >= actBegin and curTime <= actEnd)

      -- Track when the last line ended for placeholder cooldown
      if not isLineActive and curTime > actEnd then
        lastLineEndTime = actEnd
      end

      if isLineActive then
        local syllables = activeLine.syllables or {}

        if isKaraoke and #syllables > 0 then
          -- ── Syllable Karaoke Mode ────────────────────────────────────────
          local activeSylIdx = 1
          for si, s in ipairs(syllables) do
            local sBegin = tonumber(s.begin) or actBegin
            local sEnd = tonumber(s["end"] or s.end_ or s.endTime) or (sBegin + 0.4)

            if curTime >= sBegin and curTime <= sEnd then
              activeSylIdx = si
              break
            elseif curTime < sBegin then
              activeSylIdx = math.max(1, si - 1)
              break
            else
              activeSylIdx = si
            end
          end

          local startIdx, endIdx, hasLeft, hasRight
          if wrappingMode == "words" then
            startIdx, endIdx, hasLeft, hasRight = getWordChunks(syllables, maxWords, activeSylIdx)
          elseif wrappingMode == "chars" then
            startIdx, endIdx, hasLeft, hasRight = windowSyllables(syllables, activeSylIdx, maxChars)
          else
            startIdx, endIdx, hasLeft, hasRight = 1, #syllables, false, false
          end

          local lyricsRowItems = {}

          if hasLeft then
            table.insert(lyricsRowItems, ui.label({
              text = "… ",
              color = sungColor,
              fontSize = math.max(9, fontSize - 1),
            }))
          end

          for sIdx = startIdx, endIdx do
            local syl = syllables[sIdx]
            local sylText = syl.text or ""
            local spaceStr = syl.space and " " or ""
            local fullSyl = sylText .. spaceStr

            local sBegin = tonumber(syl.begin) or actBegin
            local sEnd = tonumber(syl["end"] or syl.end_ or syl.endTime) or (sBegin + 0.4)

            if sIdx < activeSylIdx then
              -- Fully sung
              table.insert(lyricsRowItems, ui.label({
                text = fullSyl,
                color = sungColor,
                fontWeight = "bold",
                fontSize = fontSize,
              }))
            elseif sIdx > activeSylIdx then
              -- Upcoming
              table.insert(lyricsRowItems, ui.label({
                text = fullSyl,
                color = upcomingColor,
                fontWeight = "normal",
                fontSize = fontSize,
              }))
            else
              -- Currently active syllable
              if not smoothSweep or lyricsData.type == "word" then
                table.insert(lyricsRowItems, ui.label({
                  text = fullSyl,
                  color = activeColor,
                  fontWeight = "bold",
                  fontSize = fontSize,
                }))
              else
                -- Letter-by-letter progressive sweep
                local rawDuration = sEnd - sBegin
                local sylDuration = math.max(0.05, rawDuration)  -- Min 50ms to avoid distortion
                local sylElapsed = curTime - sBegin
                local progress = clamp(sylElapsed / sylDuration, 0.0, 1.0)

                local chars = utf8Chars(sylText)
                local totalChars = #chars

                if totalChars <= 1 or progress <= 0.0 then
                  table.insert(lyricsRowItems, ui.label({
                    text = fullSyl,
                    color = (progress > 0.0) and activeColor or upcomingColor,
                    fontWeight = "bold",
                    fontSize = fontSize,
                  }))
                else
                  local sungCharCount = math.floor(progress * totalChars)
                  local sungPart = table.concat(chars, "", 1, sungCharCount)
                  local upcomingPart = table.concat(chars, "", sungCharCount + 1, totalChars) .. spaceStr

                  if sungPart ~= "" then
                    table.insert(lyricsRowItems, ui.label({
                      text = sungPart,
                      color = activeColor,
                      fontWeight = "bold",
                      fontSize = fontSize,
                    }))
                  end

                  if upcomingPart ~= "" then
                    table.insert(lyricsRowItems, ui.label({
                      text = upcomingPart,
                      color = upcomingColor,
                      fontWeight = "normal",
                      fontSize = fontSize,
                    }))
                  end
                end
              end
            end
          end

          if hasRight then
            table.insert(lyricsRowItems, ui.label({
              text = " …",
              color = upcomingColor,
              fontSize = math.max(9, fontSize - 1),
            }))
          end

          table.insert(children, ui.row({
            gap = 0,
            align = "center",
          }, lyricsRowItems))
        else
          -- ── Line-Synced Fallback ─────────────────────────────────────────
          local lineText = activeLine.text or ""

          if wrappingMode == "words" then
            local words = {}
            for w in string.gmatch(lineText, "%S+") do
              table.insert(words, w)
            end

            if #words > maxWords then
              local lineDur = math.max(0.1, actEnd - actBegin)
              local lineElapsed = clamp(curTime - actBegin, 0.0, lineDur)
              local progress = lineElapsed / lineDur
              local activeWordIdx = clamp(math.floor(progress * #words) + 1, 1, #words)
              local chunkIdx = math.floor((activeWordIdx - 1) / maxWords)
              local chunkStartWord = chunkIdx * maxWords + 1
              local chunkEndWord = math.min(chunkStartWord + maxWords - 1, #words)

              local chunkWords = {}
              for wi = chunkStartWord, chunkEndWord do
                table.insert(chunkWords, words[wi])
              end
              local chunkText = table.concat(chunkWords, " ")
              if chunkStartWord > 1 then
                chunkText = "… " .. chunkText
              end
              if chunkEndWord < #words then
                chunkText = chunkText .. " …"
              end
              lineText = chunkText
            end
          elseif wrappingMode == "chars" then
            if #lineText > maxChars then
              lineText = string.sub(lineText, 1, maxChars - 1) .. "…"
            end
          end

          table.insert(children, ui.label({
            text = lineText,
            color = activeColor,
            fontWeight = "bold",
            fontSize = fontSize,
          }))
        end
      else
        -- Instrumental break between lines - respect cooldown
        local timeSinceLastLine = curTime - lastLineEndTime
        if timeSinceLastLine > placeholderCooldownSec then
          -- Cooldown expired, show placeholders
          table.insert(children, ui.label({
            text = "♪  • • •  ♪",
            color = activeColor,
            fontWeight = "bold",
            fontSize = fontSize,
          }))
        else
          -- Within cooldown: freeze the last line in its final sung state
          -- Re-render with full karaoke styling (all syllables/words as "sung")
          local syllables = activeLine.syllables or {}

          if isKaraoke and #syllables > 0 then
            -- Syllable/word karaoke: render all syllables as fully sung (bold, sungColor)
            local lyricsRowItems = {}

            local startIdx, endIdx, hasLeft, hasRight
            if wrappingMode == "words" then
              startIdx, endIdx, hasLeft, hasRight = getWordChunks(syllables, maxWords, #syllables)
            elseif wrappingMode == "chars" then
              startIdx, endIdx, hasLeft, hasRight = windowSyllables(syllables, #syllables, maxChars)
            else
              startIdx, endIdx, hasLeft, hasRight = 1, #syllables, false, false
            end

            if hasLeft then
              table.insert(lyricsRowItems, ui.label({
                text = "… ",
                color = sungColor,
                fontSize = math.max(9, fontSize - 1),
              }))
            end

            for sIdx = startIdx, endIdx do
              local syl = syllables[sIdx]
              local sylText = syl.text or ""
              local spaceStr = syl.space and " " or ""
              local fullSyl = sylText .. spaceStr

              -- All syllables rendered as fully sung (frozen state)
              table.insert(lyricsRowItems, ui.label({
                text = fullSyl,
                color = sungColor,
                fontWeight = "bold",
                fontSize = fontSize,
              }))
            end

            if hasRight then
              table.insert(lyricsRowItems, ui.label({
                text = " …",
                color = sungColor,
                fontSize = math.max(9, fontSize - 1),
              }))
            end

            table.insert(children, ui.row({
              gap = 0,
              align = "center",
            }, lyricsRowItems))
          else
            -- Line-synced fallback: render full line with active styling
            local lineText = activeLine.text or ""

            if wrappingMode == "words" then
              local words = {}
              for w in string.gmatch(lineText, "%S+") do
                table.insert(words, w)
              end

              if #words > maxWords then
                local chunkIdx = math.floor((#words - 1) / maxWords)
                local chunkStartWord = chunkIdx * maxWords + 1
                local chunkEndWord = math.min(chunkStartWord + maxWords - 1, #words)

                local chunkWords = {}
                for wi = chunkStartWord, chunkEndWord do
                  table.insert(chunkWords, words[wi])
                end
                local chunkText = table.concat(chunkWords, " ")
                if chunkStartWord > 1 then
                  chunkText = "… " .. chunkText
                end
                if chunkEndWord < #words then
                  chunkText = chunkText .. " …"
                end
                lineText = chunkText
              end
            elseif wrappingMode == "chars" then
              if #lineText > maxChars then
                lineText = string.sub(lineText, 1, maxChars - 1) .. "…"
              end
            end

            table.insert(children, ui.label({
              text = lineText,
              color = activeColor,  -- Active color, not faded
              fontWeight = "bold",
              fontSize = fontSize,
            }))
          end
        end
      end
    end
  end

  barWidget.render(container({
    gap = 4,
    align = "center",
    tooltip = tooltipLines,
  }, children))
end

safeRender = function()
  local ok, err = pcall(render)
  if not ok then
    -- Log error for debugging
    if type(err) == "string" then
      print("[synced-lyrics] render error: " .. err)
    end
    pcall(function()
      barWidget.render(ui.row({ gap = 4, align = "center" }, {
        ui.glyph({ name = "music", size = 14, color = "primary" }),
        ui.label({ text = currentTitle ~= "" and currentTitle or "Lyrics", fontSize = 11, color = "on_surface" })
      }))
    end)
  end
end

-- ── Exported Actions ─────────────────────────────────────────────────────

function onClick()
  noctalia.togglePanel("kaler/synced-lyrics:lyrics-panel")
end

function onScroll(axis, steps, startsGesture)
  local n = tonumber(steps) or 0
  if n == 0 then
    return
  end

  local stepMs = tonumber(noctalia.getConfig("scroll_offset_step_ms")) or 50
  local invert = noctalia.getConfig("invert_scroll") == true

  -- On Wayland / Noctalia, negative steps = scroll up (increase offset),
  -- positive steps = scroll down (decrease offset).
  local delta = -n * stepMs
  if invert then
    delta = -delta
  end

  currentOffsetMs = clamp(currentOffsetMs + delta, -10000, 10000)
  lastOffsetScrollMs = nowMs()
  saveOffset(currentOffsetMs)
  safeRender()
end

function onConfigChanged()
  local cfgOffset = tonumber(noctalia.getConfig("timing_offset_ms"))
  if cfgOffset ~= nil and cfgOffset ~= currentOffsetMs then
    currentOffsetMs = clamp(cfgOffset, -10000, 10000)
    saveOffset(currentOffsetMs)
  end
  safeRender()
end

-- ── Main Tick Loop ───────────────────────────────────────────────────────

function update()
  local isPlaying = (playbackStatus == "Playing")
  local smoothSweep = noctalia.getConfig("smooth_sweep") ~= false
  local isSyllable = lyricsData and lyricsData.type == "syllable"

  -- Only syllable sweeps need a high refresh rate; static and line-synced states
  -- can update more slowly to reduce UI work and wakeups.
  if isPlaying and isSyllable and smoothSweep then
    noctalia.setUpdateInterval(50)
  elseif isPlaying then
    noctalia.setUpdateInterval(250)
  else
    noctalia.setUpdateInterval(1000)
  end

  updatePlaybackClock()

  local now = nowMs()
  local pollIntervalMs = isPlaying and 1000 or (playerAvailable and 1000 or 2000)
  if now - lastQueryNoctaliaMs >= pollIntervalMs then
    queryNoctaliaPlayer()
  end

  safeRender()
end

-- Initial render and query
safeRender()
queryNoctaliaPlayer()
