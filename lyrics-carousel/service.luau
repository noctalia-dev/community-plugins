--!nonstrict
-- Headless service: polls the MPRIS player and publishes the lyrics state.
--
-- State published on noctalia.state:
--   "track"   { title, artist, duration, playing, positionMs, positionAtMs, key } or nil
--   "lyrics"  { synced, lines } or nil
--   "loading" boolean
--   "error"   string or nil
--
-- The entry points (widget, panel, desktop widget) only read that state and
-- draw it, so the network call and the playerctl poll happen once for all of
-- them instead of once per surface.

local lyrics = require("./lib/lyrics.luau")

local state = noctalia.state
local pluginDir = noctalia.pluginDir() or "."

-- Twice a second is enough to keep the position honest: the entries
-- extrapolate between reads with `positionAtMs`.
noctalia.setUpdateInterval(500)

-- playerctl prints microseconds for the position and the length.
local METADATA_FORMAT =
  "{{status}}\t{{position}}\t{{mpris:length}}\t{{xesam:title}}\t{{xesam:artist}}"

-- A poll is still in flight: playerctl can be slow when the player is busy,
-- and piling up one process per tick would only make it worse.
local polling = false

-- The track the lyrics in flight belong to. Answers for any other track are
-- thrown away: the user may skip three songs while the first search is still
-- running.
local requestedKey = nil

-- Last published track, to publish only when something worth repainting
-- changed. The position is republished every second so the entries can
-- correct their extrapolation.
local lastKey = nil
local lastPlaying = nil
local lastPositionMs = nil
local published = false

state.set("track", nil)
state.set("lyrics", nil)
state.set("loading", false)
state.set("error", nil)
-- The per-track break ("brain"): true paints the karaoke fill. It goes back
-- to true on every new track, so it can never silence a song it was not
-- meant for.
local brainOn = true
state.set("brain", true)

local function setBrain(value)
  brainOn = value == true
  state.set("brain", brainOn)
end

local function clear(reason)
  if published or requestedKey ~= nil or state.get("error") ~= nil then
    published = false
    lastKey = nil
    lastPlaying = nil
    lastPositionMs = nil
    requestedKey = nil
    state.set("track", nil)
    state.set("lyrics", nil)
    state.set("loading", false)
    state.set("error", reason)
    setBrain(true)
  end
end

local function fetch(key, title, artist, duration, force)
  local command = {
    "python3",
    pluginDir .. "/bin/lyrics-fetch.py",
    "--title",
    tostring(title or ""),
    "--artist",
    tostring(artist or ""),
    "--duration",
    string.format("%.1f", tonumber(duration) or 0),
  }
  if force then
    command[#command + 1] = "--force"
  end

  local started = noctalia.runAsync(command, function(result)
    -- A late answer for a track the user already left: dropping it is what
    -- keeps the previous song's lyrics from flashing over the new one.
    if requestedKey ~= key then
      return
    end
    state.set("loading", false)

    local text = ""
    local ok = false
    if type(result) == "table" then
      text = tostring(result.stdout or "")
      ok = result.exitCode == 0
    end

    local data = nil
    if ok and text ~= "" then
      local decoded, value = pcall(noctalia.json.decode, text)
      if decoded then
        data = value
      end
    end

    local model = nil
    if type(data) == "table" then
      model = lyrics.normalize(data)
    end

    if model == nil then
      local reason = "no_lyrics"
      if type(data) == "table" and type(data.error) == "string" then
        reason = data.error
      end
      state.set("lyrics", nil)
      state.set("error", reason)
      return
    end

    state.set("error", nil)
    state.set("lyrics", model)
  end)

  if not started and requestedKey == key then
    -- The process could not even be spawned (python3 missing): report it
    -- instead of leaving the entries loading forever.
    state.set("loading", false)
    state.set("error", "no_adapter")
  end
end

local function publishNothing()
  clear(nil)
end

local function publish(status, position, length, title, artist)
  local playing = status == "Playing"
  local positionMs = math.floor((tonumber(position) or 0) / 1000)
  local duration = (tonumber(length) or 0) / 1000000
  local key = lyrics.trackKey(title, artist, duration)

  local moved = lastPositionMs == nil or math.abs(positionMs - lastPositionMs) >= 900
  if not published or key ~= lastKey or playing ~= lastPlaying or moved then
    published = true
    lastKey = key
    lastPlaying = playing
    lastPositionMs = positionMs
    state.set("track", {
      title = title,
      artist = artist,
      duration = duration,
      playing = playing,
      positionMs = positionMs,
      positionAtMs = noctalia.nowMs(),
      key = key,
    })
  end

  if key ~= requestedKey then
    requestedKey = key
    lastKey = key
    -- A new song always gets its fill back.
    setBrain(true)
    state.set("lyrics", nil)
    state.set("error", nil)
    state.set("loading", true)
    fetch(key, title, artist, duration, false)
  end
end

function update()
  if polling then
    return
  end
  polling = true
  local started = noctalia.runAsync(
    { "playerctl", "metadata", "--format", METADATA_FORMAT },
    function(result)
      polling = false
      if type(result) ~= "table" or result.exitCode ~= 0 then
        publishNothing()
        return
      end
      local line = tostring(result.stdout or ""):match("[^\r\n]+")
      if line == nil then
        publishNothing()
        return
      end
      local status, position, length, title, artist =
        line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
      if status == nil or title == nil or title == "" or status == "Stopped" then
        publishNothing()
        return
      end
      publish(status, position, length, title, artist)
    end
  )
  if not started then
    polling = false
    publishNothing()
  end
end

function onIpc(event, payload)
  if event == "brain" or event == "glow" then
    setBrain(not brainOn)
    return
  end
  if event == "refresh" then
    local track = state.get("track")
    if type(track) == "table" then
      requestedKey = track.key
      state.set("loading", true)
      state.set("error", nil)
      fetch(track.key, track.title, track.artist, track.duration, true)
    end
  end
end

function onExit()
end

-- Keeping the function defined matters: the host restarts the whole runtime
-- when a service lacks it, which would drop the lyrics it already has.
function onConfigChanged()
end
