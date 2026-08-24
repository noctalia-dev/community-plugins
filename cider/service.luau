--!nonstrict
-- Cider bridge service: watches bridge state file, drives OSD and sticky lyrics.

noctalia.setUpdateInterval(200)

local bridgeStarted = false
local osdCloseAt = 0
local lastTrackKey = ""
local lastEventId = ""
local nowPlaying = nil
local pendingOsdKey = ""
local pendingOsdAt = 0
local ART_WAIT_MS = 1200

local STATE_PATH = "~/.cache/noctalia-cider/state.json"
local EVENT_PATH = "~/.cache/noctalia-cider/event.json"
local LYRICS_PATH = "~/.cache/noctalia-cider/lyrics.json"
local POSITION_PATH = "~/.cache/noctalia-cider/position.json"
local WINDOW_PATH = "~/.cache/noctalia-cider/window.json"
local lastLyricsId = ""
local lastPositionRaw = ""
-- Local sticky lyrics HUD state.
local syncedLyricsLines = {}
local lyricsReadyLocal = false
local lyricsTick = 0
local anchorPositionMs = 0
local anchorClock = 0
local lastCiderPositionMs = -1

-- Host [[setting]] values live in wipe-prone settings.toml. Mirror effective
-- config under pluginDataDir (same pattern as local/steam bridge-config.json).
local displayMode = "notification" -- notification | osd | off
local saveToHistory = false
local osdDurationMs = 4500
local baseUrl = "http://127.0.0.1:10767"
local apptoken = ""
local lyricsOsdEnabled = true
local lyricsOsdPosition = "top_center"
local lyricsOsdShowNext = true
local lyricsOsdAnimateCues = true
local lyricsOsdShowIdle = true
local lyricsOsdKaraoke = true
local lyricsOsdGlow = true
local lyricsKaraokeStyle = "theme"
local lyricsKaraokeSung = ""
local lyricsKaraokeActive = ""
local lyricsKaraokeUpcoming = ""

local function dataDir()
  local dir, err = noctalia.pluginDataDir()
  if type(dir) == "string" and dir ~= "" then
    return dir
  end
  if err then
    noctalia.log(`cider: pluginDataDir failed: {err}`)
  end
  return nil
end

local function dataPath(name)
  local dir = dataDir()
  if dir == nil then
    return nil
  end
  return `{dir}/{name}`
end

local function loadDurableConfig()
  local path = dataPath("config.json")
  if path == nil then
    return {}
  end
  local raw = noctalia.readFile(path)
  if raw == nil or raw == "" then
    return {}
  end
  local ok, decoded = pcall(function()
    return noctalia.json.decode(raw)
  end)
  if not ok or type(decoded) ~= "table" then
    return {}
  end
  return decoded
end

local function persistConfig()
  local path = dataPath("config.json")
  if path == nil then
    return
  end
  noctalia.mkdirAll(dataDir())
  local encoded = noctalia.json.encode({
    display_mode = displayMode,
    save_to_history = saveToHistory == true,
    show_osd = displayMode == "osd",
    osd_duration_ms = osdDurationMs,
    base_url = baseUrl,
    apptoken = apptoken,
    lyrics_osd_enabled = lyricsOsdEnabled == true,
    lyrics_osd_position = lyricsOsdPosition,
    lyrics_osd_show_next = lyricsOsdShowNext == true,
    lyrics_osd_animate_cues = lyricsOsdAnimateCues == true,
    lyrics_osd_show_idle = lyricsOsdShowIdle == true,
    lyrics_osd_karaoke = lyricsOsdKaraoke == true,
    lyrics_osd_glow = lyricsOsdGlow == true,
    lyrics_karaoke_style = lyricsKaraokeStyle,
    lyrics_karaoke_sung = lyricsKaraokeSung,
    lyrics_karaoke_active = lyricsKaraokeActive,
    lyrics_karaoke_upcoming = lyricsKaraokeUpcoming,
  })
  if encoded then
    noctalia.writeFile(path, encoded)
  end
end

local function cfgBool(key, default, durable)
  local host = noctalia.getConfig(key)
  if host ~= nil then
    return host == true
  end
  if durable[key] ~= nil then
    return durable[key] == true
  end
  return default
end

local function cfgNumber(key, default, durable)
  local host = tonumber(noctalia.getConfig(key))
  if host ~= nil then
    return host
  end
  local fromDisk = tonumber(durable[key])
  if fromDisk ~= nil then
    return fromDisk
  end
  return default
end

local function cfgString(key, default, durable)
  local host = noctalia.getConfig(key)
  if type(host) == "string" and host ~= "" then
    return host
  end
  -- Empty string from host still counts as "set" for optional secrets only when
  -- durable has nothing; prefer durable when host is nil/empty after a wipe.
  if type(host) == "string" and host == "" then
    local fromDisk = durable[key]
    if type(fromDisk) == "string" and fromDisk ~= "" then
      return fromDisk
    end
    return default
  end
  if host == nil then
    local fromDisk = durable[key]
    if type(fromDisk) == "string" and fromDisk ~= "" then
      return fromDisk
    end
  end
  return default
end

local function resolveDisplayMode(durable)
  local mode = cfgString("display_mode", "", durable)
  if mode == "notification" or mode == "osd" or mode == "off" then
    return mode
  end
  -- Legacy durable flag from older builds.
  if durable.show_osd == false then
    return "off"
  end
  return "notification"
end

local function publishLyricsOsdCfg()
  local bag = {
    enabled = lyricsOsdEnabled == true,
    backend = "overlay",
    position = lyricsOsdPosition,
    show_next = lyricsOsdShowNext == true,
    animate_cues = lyricsOsdAnimateCues == true,
    show_idle = lyricsOsdShowIdle == true,
    karaoke = lyricsOsdKaraoke == true,
    glow = lyricsOsdGlow == true,
    karaoke_style = lyricsKaraokeStyle,
    sung = lyricsKaraokeSung,
    active = lyricsKaraokeActive,
    upcoming = lyricsKaraokeUpcoming,
  }
  noctalia.state.set("lyrics_osd_cfg", bag)
  noctalia.state.set("lyrics_osd_enabled", lyricsOsdEnabled == true)
  noctalia.mkdirAll("~/.cache/noctalia-cider")
  local encoded = noctalia.json.encode(bag)
  if encoded then
    noctalia.writeFile("~/.cache/noctalia-cider/lyrics_osd_cfg.json", encoded)
  end
end

local function refreshConfig()
  local durable = loadDurableConfig()
  displayMode = resolveDisplayMode(durable)
  saveToHistory = cfgBool("save_to_history", false, durable)
  osdDurationMs = cfgNumber("osd_duration_ms", 4500, durable)
  baseUrl = cfgString("base_url", "http://127.0.0.1:10767", durable)
  apptoken = cfgString("apptoken", "", durable)
  lyricsOsdEnabled = cfgBool("lyrics_osd_enabled", true, durable)
  lyricsOsdPosition = cfgString("lyrics_osd_position", "top_center", durable)
  lyricsOsdShowNext = cfgBool("lyrics_osd_show_next", true, durable)
  lyricsOsdAnimateCues = cfgBool("lyrics_osd_animate_cues", true, durable)
  lyricsOsdShowIdle = cfgBool("lyrics_osd_show_idle", true, durable)
  lyricsOsdKaraoke = cfgBool("lyrics_osd_karaoke", true, durable)
  lyricsOsdGlow = cfgBool("lyrics_osd_glow", true, durable)
  local kstyle = cfgString("lyrics_karaoke_style", "theme", durable)
  lyricsKaraokeStyle = kstyle == "custom" and "custom" or "theme"
  lyricsKaraokeSung = cfgString("lyrics_karaoke_sung", "", durable)
  lyricsKaraokeActive = cfgString("lyrics_karaoke_active", "", durable)
  lyricsKaraokeUpcoming = cfgString("lyrics_karaoke_upcoming", "", durable)
  persistConfig()
  publishLyricsOsdCfg()
end

refreshConfig()
local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end
local function pluginRoot()
  return noctalia.pluginDir() or "."
end

local function trackKey(np)
  -- Identity for "new song" must NOT include catalog_id — it often arrives on a
  -- later snapshot and was falsely treated as a track change (cleared lyrics,
  -- reopened OSD forever).
  if type(np) ~= "table" then return "" end
  return table.concat({
    tostring(np.title or ""),
    tostring(np.artist or ""),
    tostring(np.album or ""),
    tostring(np.duration_ms or 0),
  }, "|")
end

local function formatTime(ms)
  ms = math.max(0, tonumber(ms) or 0)
  local total = math.floor(ms / 1000)
  local m = math.floor(total / 60)
  local s = total % 60
  return string.format("%d:%02d", m, s)
end

local function publishNowPlaying(np)
  nowPlaying = np
  noctalia.state.set("now_playing", np)
  if type(np) == "table" then
    noctalia.state.set("title", np.title or "")
    noctalia.state.set("artist", np.artist or "")
    noctalia.state.set("album", np.album or "")
    noctalia.state.set("artwork", tostring(np.artwork_path or ""):gsub("^file://", ""))
    noctalia.state.set("playing", np.playback_state == "playing")
    noctalia.state.set("position_ms", tonumber(np.position_ms) or 0)
    noctalia.state.set("duration_ms", tonumber(np.duration_ms) or 0)
    noctalia.state.set("elapsed_text", formatTime(np.position_ms))
    local dur = tonumber(np.duration_ms) or 0
    local pos = tonumber(np.position_ms) or 0
    np.remaining_ms = math.max(0, dur - pos)
    noctalia.state.set("remaining_text", formatTime(np.remaining_ms))
    noctalia.state.set("progress", dur > 0 and math.min(1, pos / dur) or 0)
  else
    -- Cider inactive / cleared — bar chip must go idle, not keep last track.
    lastTrackKey = ""
    noctalia.state.set("title", "")
    noctalia.state.set("artist", "")
    noctalia.state.set("album", "")
    noctalia.state.set("artwork", "")
    noctalia.state.set("playing", false)
    noctalia.state.set("position_ms", 0)
    noctalia.state.set("duration_ms", 0)
    noctalia.state.set("elapsed_text", "0:00")
    noctalia.state.set("remaining_text", "0:00")
    noctalia.state.set("progress", 0)
  end
  -- Nudge sticky lyrics OSD to re-resolve current/next against position.
  lyricsTick = lyricsTick + 1
  noctalia.state.set("lyrics_tick", lyricsTick)
end

local HUD_PATH = "~/.cache/noctalia-cider/hud.json"
local LYRICS_PANEL_ID = "dragged/cider:lyrics-osd"
local lyricsHudVisible = false

-- panel-close is idempotent. togglePanel would invert an already-open
-- now-playing toast. Also close a leftover lyrics-osd panel from older builds.
local function closeLyricsPanel()
  noctalia.runAsync("noctalia msg panel-close " .. LYRICS_PANEL_ID .. " 2>/dev/null || true")
end

local function stopLyricsOverlay()
  -- Kill the overlay by pidfile. Never `pkill -f lyrics_overlay.py`: that
  -- pattern matches this runAsync argv and can kill the launcher instead.
  noctalia.runAsync(
    "sh -c 'f=\"$HOME/.cache/noctalia-cider/lyrics_overlay.pid\"; [ -f \"$f\" ] && kill \"$(cat \"$f\")\" 2>/dev/null; rm -f \"$f\"'"
  )
end

local function persistSurfaceVisible()
  noctalia.mkdirAll("~/.cache/noctalia-cider")
  noctalia.state.set("lyrics_hud_visible", lyricsHudVisible == true)
  local encoded = noctalia.json.encode({ visible = lyricsHudVisible == true })
  if encoded then
    noctalia.writeFile(HUD_PATH, encoded)
  end
end

local function ensureLyricsOverlay()
  local script = pluginRoot() .. "/scripts/lyrics_overlay.py"
  if not noctalia.fileExists(script) then
    noctalia.log("cider: missing lyrics_overlay.py")
    return
  end
  -- Overlay replaces a stale pid itself. Do not pkill by overlay script name:
  -- a -f match hits this runAsync shell and kills the launcher first.
  noctalia.runAsync(
    string.format(
      "nohup python3 %s >/tmp/noctalia-cider-lyrics-overlay.log 2>&1 &",
      shellQuote(script)
    )
  )
end

local function applyLyricsSurface()
  persistSurfaceVisible()
  closeLyricsPanel()
  if not lyricsOsdEnabled or not lyricsHudVisible then
    stopLyricsOverlay()
    return
  end
  ensureLyricsOverlay()
end

local function toggleLyricsHud()
  if not lyricsOsdEnabled then
    return
  end
  lyricsHudVisible = not lyricsHudVisible
  applyLyricsSurface()
end

local function clearLocalLyrics()
  syncedLyricsLines = {}
  lyricsReadyLocal = false
  noctalia.state.set("lyrics_lines", {})
  noctalia.state.set("lyrics_ready", false)
  lyricsTick = lyricsTick + 1
  noctalia.state.set("lyrics_tick", lyricsTick)
end

local function publishLocalLyrics(lines)
  if type(lines) ~= "table" or #lines == 0 then
    clearLocalLyrics()
    return
  end
  syncedLyricsLines = lines
  lyricsReadyLocal = true
  noctalia.state.set("lyrics_lines", lines)
  noctalia.state.set("lyrics_ready", true)
  lyricsTick = lyricsTick + 1
  noctalia.state.set("lyrics_tick", lyricsTick)
end

local lastOsdTrackKey = ""
local lastNotifyTrackKey = ""

local function closeOsd()
  osdCloseAt = 0
  noctalia.runAsync("noctalia msg panel-close dragged/cider:osd")
end

local function openOsd()
  pendingOsdKey = ""
  pendingOsdAt = 0
  noctalia.runAsync("noctalia msg panel-open dragged/cider:osd")
  -- Always (re)arm dismiss timer from this open.
  osdCloseAt = os.clock() * 1000 + osdDurationMs
end

local function artReady(np)
  local path = tostring((np and np.artwork_path) or ""):gsub("^file://", "")
  return path ~= "" and noctalia.fileExists(path)
end

local function trackNotifyBody(np)
  if type(np) ~= "table" then
    return ""
  end
  local parts = {}
  if type(np.artist) == "string" and np.artist ~= "" then
    parts[#parts + 1] = np.artist
  end
  if type(np.album) == "string" and np.album ~= "" then
    parts[#parts + 1] = np.album
  end
  return table.concat(parts, " · ")
end

local function showTrackNotification(np)
  local title = (type(np) == "table" and np.title) or ""
  if title == "" then
    title = noctalia.tr("osd.not_playing")
  end
  local icon = "audio-x-generic"
  if type(np) == "table" then
    local art = tostring(np.artwork_path or ""):gsub("^file://", "")
    if art ~= "" then
      icon = art
    end
  end
  local payload = {
    app_name = "Now Playing",
    summary = tostring(title),
    body = trackNotifyBody(np),
    icon = icon,
    urgency = "low",
    timeout_ms = math.floor(osdDurationMs),
    desktop_entry = "noctalia-now-playing",
    category = "x-noctalia.media",
    save_history = saveToHistory == true,
  }
  local encoded = noctalia.json.encode(payload)
  if not encoded then
    noctalia.notify(payload.summary, payload.body)
    return
  end
  local ok = noctalia.runAsync("noctalia msg notification-show " .. shellQuote(encoded))
  if not ok then
    noctalia.notify(payload.summary, payload.body)
  end
end

local function isPlayingState(state)
  return tostring(state or "") == "playing"
end

local function ciderSuppressesNotify()
  local raw = noctalia.readFile(WINDOW_PATH)
  if raw == nil or raw == "" then
    return false
  end
  local ok, decoded = pcall(function()
    return noctalia.json.decode(raw)
  end)
  if not ok or type(decoded) ~= "table" then
    return false
  end
  if decoded.suppress_notify == true then
    return true
  end
  return decoded.focused == true or decoded.on_screen == true
end

local function presentTrack(np, key, force)
  if displayMode == "off" or key == "" then
    return
  end
  -- Only announce when audio is actually playing — not on launch / queue load.
  if type(np) ~= "table" or not isPlayingState(np.playback_state) then
    return
  end
  if displayMode == "notification" then
    if key == lastNotifyTrackKey and not force then
      return
    end
    -- Wait briefly for art when available; still notify if art never arrives.
    if artReady(np) or force then
      lastNotifyTrackKey = key
      pendingOsdKey = ""
      pendingOsdAt = 0
      -- Skip toast while Cider is focused or visible on the current screen.
      if ciderSuppressesNotify() then
        return
      end
      showTrackNotification(np)
      return
    end
    pendingOsdKey = key
    pendingOsdAt = os.clock() * 1000
    return
  end
  -- osd
  if key == lastOsdTrackKey and osdCloseAt > 0 then
    return
  end
  if artReady(np) or force then
    lastOsdTrackKey = key
    openOsd()
    return
  end
  pendingOsdKey = key
  pendingOsdAt = os.clock() * 1000
end

local function maybeCloseOsd()
  if pendingOsdKey ~= "" and pendingOsdAt > 0 then
    local waited = os.clock() * 1000 - pendingOsdAt
    if artReady(nowPlaying) or waited >= ART_WAIT_MS then
      local key = pendingOsdKey
      pendingOsdKey = ""
      pendingOsdAt = 0
      if key == lastTrackKey then
        presentTrack(nowPlaying, key, true)
      end
    end
  end
  if osdCloseAt <= 0 then return end
  if os.clock() * 1000 >= osdCloseAt then
    closeOsd()
  end
end

local function setPlaybackAnchor(positionMs, playing)
  anchorPositionMs = math.max(0, tonumber(positionMs) or 0)
  anchorClock = os.clock()
  if type(nowPlaying) == "table" then
    nowPlaying.position_ms = anchorPositionMs
    if playing ~= nil then
      nowPlaying.playback_state = playing and "playing" or "paused"
    end
  end
end

local function estimatedPositionMs()
  if type(nowPlaying) ~= "table" then return 0 end
  local base = anchorPositionMs
  if nowPlaying.playback_state ~= "playing" then
    return base
  end
  local elapsed = (os.clock() - anchorClock) * 1000
  local dur = tonumber(nowPlaying.duration_ms) or 0
  local pos = base + elapsed
  if dur > 0 then pos = math.min(pos, dur) end
  return pos
end

local function noteCiderPosition(positionMs, playing, _eventType)
  positionMs = math.max(0, tonumber(positionMs) or 0)
  local prevPlaying = type(nowPlaying) == "table" and nowPlaying.playback_state == "playing"
  if playing == nil then
    playing = prevPlaying
  end
  local playChanged = prevPlaying ~= playing
  local prevPos = lastCiderPositionMs
  if not playChanged and positionMs == prevPos and anchorClock ~= 0 then
    return
  end
  setPlaybackAnchor(positionMs, playing)
  lastCiderPositionMs = positionMs
end

local function applyLocalLyrics(event)
  local lines = nil
  local synced = false
  if type(event.lyrics_lines) == "table" and #event.lyrics_lines > 0 then
    lines = event.lyrics_lines
    synced = tonumber(event.lyrics_lines[1].time) ~= nil and tonumber(event.lyrics_lines[1].time) >= 0
  end
  if lines ~= nil and synced then
    publishLocalLyrics(lines)
  else
    clearLocalLyrics()
  end
  local positionMs = tonumber(event.position_ms)
  if positionMs ~= nil then
    local playing = event.playback_state == "playing"
    if event.playback_state == nil and type(nowPlaying) == "table" then
      playing = nowPlaying.playback_state == "playing"
    end
    setPlaybackAnchor(positionMs, playing)
  end
end

local function handleEvent(event)
  if type(event) ~= "table" or type(event.type) ~= "string" then return end

  if event.type == "clear" then
    lastTrackKey = ""
    clearLocalLyrics()
    publishNowPlaying(nil)
    return
  end

  if event.type == "status" then
    local msg = tostring(event.message or "")
    noctalia.state.set("bridge_status", msg)
    -- Disconnect / dead API: treat as inactive Cider.
    if msg == "disconnected" or msg:match("^api_dead") or msg:match("^connect_failed") then
      lastTrackKey = ""
      clearLocalLyrics()
      publishNowPlaying(nil)
    end
    return
  end

  if event.type == "time" or event.type == "state" or event.type == "track" or event.type == "art" then
    local np = {
      title = event.title or "",
      artist = event.artist or "",
      album = event.album or "",
      artwork_path = tostring(event.artwork_path or ""):gsub("^file://", ""),
      artwork_url = event.artwork_url or "",
      position_ms = tonumber(event.position_ms) or 0,
      duration_ms = tonumber(event.duration_ms) or 0,
      playback_state = event.playback_state or "paused",
      catalog_id = event.catalog_id or "",
      song_id = event.song_id or "",
    }
    if np.artwork_path == "" and type(nowPlaying) == "table" then
      np.artwork_path = tostring(nowPlaying.artwork_path or "")
    end
    -- Keep metadata; position is applied via anchor so OSD/lyrics don't scrub.
    if type(nowPlaying) == "table" and event.type == "time" then
      np.title = np.title ~= "" and np.title or nowPlaying.title
      np.artist = np.artist ~= "" and np.artist or nowPlaying.artist
      np.album = np.album ~= "" and np.album or nowPlaying.album
      np.artwork_path = np.artwork_path ~= "" and np.artwork_path or nowPlaying.artwork_path
      np.duration_ms = (np.duration_ms > 0) and np.duration_ms or nowPlaying.duration_ms
      np.catalog_id = np.catalog_id ~= "" and np.catalog_id or nowPlaying.catalog_id
      np.song_id = np.song_id ~= "" and np.song_id or nowPlaying.song_id
      if not event.playback_state then
        np.playback_state = nowPlaying.playback_state or "paused"
      end
    end
    local wasPlaying = type(nowPlaying) == "table" and isPlayingState(nowPlaying.playback_state)
    publishNowPlaying(np)
    local key = trackKey(np)
    local playing = isPlayingState(np.playback_state)
    if event.type == "track" and key ~= "" and key ~= lastTrackKey then
      lastTrackKey = key
      setPlaybackAnchor(np.position_ms, playing)
      clearLocalLyrics()
      -- Only toast/OSD when this track is already playing (not queue-load at rest).
      if playing then
        presentTrack(np, key, false)
      else
        -- Allow a later play press to announce this track.
        lastNotifyTrackKey = ""
        lastOsdTrackKey = ""
      end
    elseif pendingOsdKey ~= "" and pendingOsdKey == key and artReady(np) then
      presentTrack(np, key, true)
    elseif playing and not wasPlaying and key ~= "" then
      -- Paused/stopped → playing: this is the real "now playing" moment.
      presentTrack(np, key, false)
    end
    if event.type == "time" or event.type == "state" then
      noteCiderPosition(np.position_ms, playing, event.type)
    end
    return
  end

  if event.type == "lyrics" then
    if event.message == "none" then
      clearLocalLyrics()
      return
    end
    applyLocalLyrics(event)
  end
end

local pollInFlight = false

local function pollBridgeFiles()
  -- Order: track before lyrics so a service start does not flash stale lines.
  -- Async chain: STATE → EVENT → LYRICS → POSITION (API 23 readFileAsync).
  if pollInFlight then
    return
  end
  pollInFlight = true

  local function finishPoll()
    pollInFlight = false
  end

  local function applyPosition(posRaw)
    -- Position last — highest-frequency Cider clock for lyrics lock.
    if posRaw and posRaw ~= "" and posRaw ~= lastPositionRaw then
      lastPositionRaw = posRaw
      local decoded = noctalia.json.decode(posRaw)
      if type(decoded) == "table" then
        local playing = decoded.playing == true
        local wasPlaying = type(nowPlaying) == "table" and isPlayingState(nowPlaying.playback_state)
        noteCiderPosition(tonumber(decoded.position_ms) or 0, playing, "time")
        if type(nowPlaying) == "table" then
          nowPlaying.position_ms = tonumber(decoded.position_ms) or nowPlaying.position_ms
          nowPlaying.playback_state = playing and "playing" or "paused"
          if (tonumber(decoded.duration_ms) or 0) > 0 then
            nowPlaying.duration_ms = tonumber(decoded.duration_ms)
          end
          publishNowPlaying(nowPlaying)
          if playing and not wasPlaying then
            local key = trackKey(nowPlaying)
            if key ~= "" then
              presentTrack(nowPlaying, key, false)
            end
          end
        end
      end
    end
    finishPoll()
  end

  local function applyLyrics(lyricsRaw)
    if lyricsRaw and lyricsRaw ~= "" then
      local decoded = noctalia.json.decode(lyricsRaw)
      if type(decoded) == "table" then
        local lid = tostring(decoded._id or "")
        if lid ~= "" and lid ~= lastLyricsId then
          lastLyricsId = lid
          decoded.type = "lyrics"
          handleEvent(decoded)
        end
      end
    end
    local queued = noctalia.readFileAsync(POSITION_PATH, applyPosition)
    if not queued then
      finishPoll()
    end
  end

  local function applyEvent(eventRaw)
    if eventRaw and eventRaw ~= "" then
      local decoded = noctalia.json.decode(eventRaw)
      if type(decoded) == "table" then
        local eid = tostring(decoded._id or "")
        if eid ~= "" and eid ~= lastEventId then
          lastEventId = eid
          -- Skip lyrics edges here — lyrics.json is the durable source and avoids
          -- double-clear races with track events in the same poll.
          if decoded.type ~= "lyrics" then
            handleEvent(decoded)
          end
        end
      end
    end
    local queued = noctalia.readFileAsync(LYRICS_PATH, applyLyrics)
    if not queued then
      finishPoll()
    end
  end

  local function applyState(stateRaw)
    if stateRaw and stateRaw ~= "" then
      local decoded = noctalia.json.decode(stateRaw)
      if type(decoded) == "table" and (decoded.title or decoded.artist) then
        if lastTrackKey == "" then
          decoded.type = "track"
          handleEvent(decoded)
        elseif type(nowPlaying) == "table" then
          local key = trackKey(decoded)
          if key ~= "" and key ~= lastTrackKey then
            decoded.type = "track"
            handleEvent(decoded)
          elseif decoded.type == "art"
              or (decoded.artwork_path and decoded.artwork_path ~= ""
                and decoded.artwork_path ~= nowPlaying.artwork_path) then
            decoded.type = "art"
            handleEvent(decoded)
          end
        end
      end
    elseif type(nowPlaying) == "table" and lastTrackKey ~= "" then
      -- state.json wiped on Cider quit — drop stale chip immediately.
      publishNowPlaying(nil)
      clearLocalLyrics()
    end
    local queued = noctalia.readFileAsync(EVENT_PATH, applyEvent)
    if not queued then
      finishPoll()
    end
  end

  local queued = noctalia.readFileAsync(STATE_PATH, applyState)
  if not queued then
    finishPoll()
  end
end

local function startBridge()
  if bridgeStarted then return end
  local script = pluginRoot() .. "/scripts/cider_bridge.py"
  local launcher = pluginRoot() .. "/scripts/start-bridge.sh"
  if not noctalia.fileExists(script) then
    noctalia.notifyError("Cider", "Missing scripts/cider_bridge.py")
    return
  end
  noctalia.mkdirAll("~/.cache/noctalia-cider/art")
  noctalia.writeFile("~/.cache/noctalia-cider/apptoken", apptoken or "")
  -- bash, not chmod +x: git-store installs can be read-only. Token is a file,
  -- not argv, so `ps` cannot scrape it.
  local cmd = string.format(
    "bash %s %s ~/.cache/noctalia-cider >/tmp/noctalia-cider-bridge.log 2>&1 &",
    shellQuote(launcher),
    shellQuote(baseUrl)
  )
  local ok = noctalia.runAsync(cmd)
  if ok then
    bridgeStarted = true
    noctalia.state.set("bridge_status", "starting")
  else
    noctalia.notifyError("Cider", "Failed to start cider bridge launcher")
  end
end

startBridge()

-- Restore sticky lyrics visibility across service reloads.
do
  local hudRaw = noctalia.readFile(HUD_PATH)
  local visible = false
  if hudRaw and hudRaw ~= "" then
    local decoded = noctalia.json.decode(hudRaw)
    if type(decoded) == "table" and decoded.visible == true then
      visible = true
    end
  end
  lyricsHudVisible = visible
  applyLyricsSurface()
end

function update()
  pollBridgeFiles()
  maybeCloseOsd()
  -- Smooth OSD progress from the last trusted Cider anchor (no fake +200 jumps).
  if type(nowPlaying) == "table" then
    local pos = estimatedPositionMs()
    if pos ~= (tonumber(nowPlaying.position_ms) or 0) then
      nowPlaying.position_ms = pos
      publishNowPlaying(nowPlaying)
    end
  end
end

function onConfigChanged()
  local prevUrl = baseUrl
  local prevToken = apptoken
  refreshConfig()
  applyLyricsSurface()
  if baseUrl ~= prevUrl or apptoken ~= prevToken then
    bridgeStarted = false
    noctalia.runAsync("pkill -f cider_bridge.py 2>/dev/null || true")
    startBridge()
  end
end

function onIpc(event, payload)
  if event == "show-osd" then
    lastOsdTrackKey = ""
    lastNotifyTrackKey = ""
    local key = trackKey(nowPlaying)
    if key == "" then
      key = "manual"
    end
    presentTrack(nowPlaying, key, true)
  elseif event == "hide-osd" then
    closeOsd()
  elseif event == "toggle-lyrics-hud" then
    toggleLyricsHud()
  elseif event == "show-lyrics-hud" then
    lyricsHudVisible = true
    applyLyricsSurface()
  elseif event == "hide-lyrics-hud" then
    lyricsHudVisible = false
    applyLyricsSurface()
  elseif event == "event" and payload then
    local decoded = noctalia.json.decode(payload)
    if decoded then handleEvent(decoded) end
  end
end

function onEnable()
  -- Explicit re-enable only. Ordinary startup already ran startBridge() above.
  startBridge()
end

function onExit(_signal, reason)
  -- Reload keeps the replacement bridge; start-bridge.sh already replaces it.
  if reason == "disable" or reason == "uninstall" or reason == "shutdown" then
    noctalia.runAsync("pkill -f cider_bridge.py >/dev/null 2>&1 || true")
    stopLyricsOverlay()
  end
  if reason == "disable" or reason == "uninstall" then
    noctalia.runAsync("noctalia msg panel-close dragged/cider:osd 2>/dev/null || true")
    closeLyricsPanel()
  end
end
