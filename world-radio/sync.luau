--!nonstrict
-- sync.luau
-- Headless service for World Radio.
--
-- The panel only runs while it is open, but the radio keeps playing after it
-- closes. mpv is launched with the whole station queue as a playlist, so its
-- own MPRIS Next/Previous controls can move between stations without the panel.
-- This service follows those changes (radio.lua records the current playlist
-- position in now.json), keeps playing.json pointing at the station that is
-- actually playing, publishes the "playing" state used by the bar widget, and
-- turns wheel gestures from the widget into MPRIS Next/Previous calls.

noctalia.setUpdateInterval(1000)

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

local function playingPath()
  return getDataDir() .. "/playing.json"
end

local function nowPath()
  return getDataDir() .. "/now.json"
end

local function flagEmoji(code)
  local letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  local emojis = {}
  for i = 1, #letters do
    local cp = 127397 + letters:byte(i)
    local b0 = 0xF0 + math.floor(cp / 0x40000)
    local b1 = 0x80 + math.floor(math.floor(cp / 0x1000) % 0x40)
    local b2 = 0x80 + math.floor(math.floor(cp / 0x40) % 0x40)
    local b3 = 0x80 + (cp % 0x40)
    emojis[letters:sub(i, i)] = string.char(b0, b1, b2, b3)
  end
  code = tostring(code or ""):upper()
  local e1, e2 = emojis[code:sub(1, 1)], emojis[code:sub(2, 2)]
  if e1 == nil or e2 == nil then
    return ""
  end
  return e1 .. e2
end

local playingRaw = nil
local playingData = nil
local publishedKey = nil

local function publish(station, session, pos)
  local name = type(station.name) == "string" and station.name or ""
  local uuid = type(station.uuid) == "string" and station.uuid or ""
  local url = type(station.url) == "string" and station.url or ""
  local flag = flagEmoji(station.countrycode)
  local key = table.concat({ name, uuid, url, flag, tostring(session or ""), tostring(pos or "") }, "\0")
  if key == publishedKey then
    return
  end
  publishedKey = key
  noctalia.state.set("playing", {
    name = name,
    uuid = uuid,
    url = url,
    flag = flag,
    session = session or "",
    pos = pos or -1,
  })
end

local function publishEmpty()
  if publishedKey == "" then
    return
  end
  publishedKey = ""
  noctalia.state.set("playing", { name = "", uuid = "", url = "", flag = "", session = "", pos = -1 })
end

local function loadPlaying()
  local raw = noctalia.readFile(playingPath())
  if raw == playingRaw then
    return
  end
  if raw == nil then
    playingRaw = nil
    playingData = nil
    return
  end
  local ok, val = pcall(noctalia.json.decode, raw)
  if not ok or type(val) ~= "table" or type(val.station) ~= "table" then
    -- Possibly caught mid-write; retry on the next tick.
    playingRaw = nil
    playingData = nil
    return
  end
  playingRaw = raw
  playingData = val
end

local function syncPlaying()
  loadPlaying()
  local data = playingData
  if data == nil then
    publishEmpty()
    return
  end

  local session = type(data.session) == "string" and data.session or ""
  if session ~= "" then
    local rawNow = noctalia.readFile(nowPath())
    if rawNow ~= nil then
      local ok, nowVal = pcall(noctalia.json.decode, rawNow)
      if ok and type(nowVal) == "table" and nowVal.session == session then
        local pos = tonumber(nowVal.pos)
        local queue = data.queue
        local station = (pos ~= nil and type(queue) == "table") and queue[pos + 1] or nil
        if type(station) == "table" and type(station.uuid) == "string" then
          local current = data.station
          if type(current) ~= "table" or current.uuid ~= station.uuid then
            -- mpv moved to another playlist entry through MPRIS, so the
            -- persisted "current station" has to follow it.
            data.station = station
            local encodedOk, encoded = pcall(noctalia.json.encode, data)
            if encodedOk and encoded ~= nil then
              noctalia.writeFile(playingPath(), encoded)
              playingRaw = encoded
            end
          end
          publish(station, session, pos)
          return
        end
      end
    end
  end

  publish(data.station, session, nil)
end

function update()
  syncPlaying()
end

-- ---------------------------------------------------------------------------
-- MPRIS transport (mpv-mpris)
-- ---------------------------------------------------------------------------

local hasGdbus = noctalia.commandExists("gdbus")

local function mprisCall(method)
  if not hasGdbus then
    return
  end
  noctalia.runAsync({
    "gdbus",
    "call",
    "--session",
    "--dest",
    "org.freedesktop.DBus",
    "--object-path",
    "/org/freedesktop/DBus",
    "--method",
    "org.freedesktop.DBus.ListNames",
  }, function(result)
    if result == nil or result.exitCode ~= 0 then
      return
    end
    local bus = nil
    for name in tostring(result.stdout or ""):gmatch("'([^']+)'") do
      if name:match("^org%.mpris%.MediaPlayer2%.mpv%.World_Radio") then
        bus = name
      end
    end
    if bus == nil then
      noctalia.log("world-radio: no MPRIS bus for " .. method)
      return
    end
    noctalia.log("world-radio: MPRIS " .. method .. " on " .. bus)
    noctalia.runAsync({
      "gdbus",
      "call",
      "--session",
      "--dest",
      bus,
      "--object-path",
      "/org/mpris/MediaPlayer2",
      "--method",
      "org.mpris.MediaPlayer2.Player." .. method,
    }, function(inner)
      if inner == nil or inner.exitCode ~= 0 then
        noctalia.log("world-radio: MPRIS " .. method .. " failed")
      else
        noctalia.log("world-radio: MPRIS " .. method .. " done")
      end
    end)
  end)
end

-- The bar widget publishes one request per scroll gesture, with a monotonic id
-- so a service restart or a burst cannot replay an old direction.
local lastSkipId = 0

noctalia.state.watch("skip_request", function(request)
  if type(request) ~= "table" then
    return
  end
  local id = tonumber(request.id)
  if id == nil or id <= lastSkipId then
    return
  end
  lastSkipId = id
  local dir = tonumber(request.dir) or 0
  if dir > 0 then
    mprisCall("Next")
  elseif dir < 0 then
    mprisCall("Previous")
  end
end)

function onIpc(event, payload)
  local ev = tostring(event or ""):lower()
  local arg = type(payload) == "string" and payload:lower() or ""
  if ev == "next" or ev == "skip" or arg == "next" then
    mprisCall("Next")
  elseif ev == "previous" or ev == "prev" or arg == "previous" or arg == "prev" then
    mprisCall("Previous")
  end
end
