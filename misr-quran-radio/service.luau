--!nonstrict
-- Misr Quran Radio service - the only entry that talks to the network or mpv.
--
-- Reads the daily programme schedule from the public API:
--   POST https://API.misrquran.gov.eg/api/RadioProgrammeSchedule/GetByDay
-- and plays the public live HLS stream through `mpv --no-video`.
--
--   noctalia.state.set("misr_quran.state", snapshot)    UI entries render this
--   noctalia.state.watch("misr_quran.request", handler) actions from bar/panel
--
-- Playback is one detached mpv process tagged --title=MISRQRNLIVE, so a
-- shell restart never leaves a stray player: the tick re-checks with
-- processMatches and the snapshot follows the live process list.

local STATE_KEY = "misr_quran.state"
local REQUEST_KEY = "misr_quran.request"
local PROC_TAG = "MISRQRNLIVE"
local API_URL = "https://API.misrquran.gov.eg/api/RadioProgrammeSchedule/GetByDay"
local DEFAULT_STREAM = "https://service.webvideocore.net/CL1olYogIrDWvwqiIKK7eCxOS4PStqG9DuEjAr2ZjZQtvS3d4y9r0cvRhvS17SGN/a_7a4vuubc6mo8.m3u8"
local TICK_MS = 2000
local BUSY_TIMEOUT_MS = 20000
local MAX_ITEMS = 200

noctalia.setUpdateInterval(TICK_MS)

local mpvAvailable = noctalia.commandExists("mpv")
local pkillAvailable = noctalia.commandExists("pkill")

local playing = false
local busy = false
local busySinceMs = 0
local errorMessage = nil
local schedule = {}
local current = nil
local fetching = false
local lastFetchMs = 0
local fetchCount = 0

local function streamUrl()
  local v = noctalia.getConfig("stream_url")
  if type(v) == "string" and v ~= "" then
    return v
  end
  return DEFAULT_STREAM
end

local function refreshMinutes()
  local v = tonumber(noctalia.getConfig("refresh_minutes"))
  if v == nil then
    return 30
  end
  if v < 5 then
    return 5
  end
  if v > 720 then
    return 720
  end
  return math.floor(v)
end

local function nowMs()
  return noctalia.nowMs()
end

local function clearBusyIfStuck()
  if busy and (nowMs() - busySinceMs) > BUSY_TIMEOUT_MS then
    busy = false
    errorMessage = "timed out"
  end
end

-- "01:30 AM" -> minutes since midnight, nil when unparseable.
local function timeToMinutes(text)
  if type(text) ~= "string" then
    return nil
  end
  local trimmed = noctalia.string.trim(text)
  local h, m, ap = trimmed:match("^(%d+):(%d+)%s*([AaPp][Mm])$")
  if h == nil then
    h, m = trimmed:match("^(%d+):(%d+)$")
    if h == nil then
      return nil
    end
    local hh = tonumber(h)
    local mm = tonumber(m)
    if hh == nil or mm == nil or hh > 23 or mm > 59 then
      return nil
    end
    return hh * 60 + mm
  end
  local hh = tonumber(h)
  local mm = tonumber(m)
  if hh == nil or mm == nil or hh < 1 or hh > 12 or mm > 59 then
    return nil
  end
  local upper = ap:upper()
  if upper == "AM" then
    if hh == 12 then
      hh = 0
    end
  else
    if hh ~= 12 then
      hh = hh + 12
    end
  end
  return hh * 60 + mm
end

local function cairoMinutes()
  local ok, text = pcall(noctalia.formatTime, "%H:%M", nil, "Africa/Cairo")
  if not ok or type(text) ~= "string" then
    return nil
  end
  local h, m = text:match("^(%d+):(%d+)$")
  if h == nil then
    return nil
  end
  return tonumber(h) * 60 + tonumber(m)
end

local function pickCurrent(items)
  local nowMin = cairoMinutes()
  if nowMin == nil then
    return nil
  end
  for _, item in ipairs(items) do
    local fromMin = timeToMinutes(item.fromTime)
    local toMin = timeToMinutes(item.toTime)
    if fromMin ~= nil and toMin ~= nil then
      if toMin <= fromMin then
        -- Overnight slot, e.g. 11:30 PM -> 12:30 AM.
        if nowMin >= fromMin or nowMin < toMin then
          return item
        end
      elseif nowMin >= fromMin and nowMin < toMin then
        return item
      end
    end
  end
  return nil
end

local function snapshot()
  local ageS = nil
  if lastFetchMs > 0 then
    ageS = math.floor((nowMs() - lastFetchMs) / 1000)
  end
  return {
    available = mpvAvailable,
    playing = playing,
    busy = busy,
    error = errorMessage,
    stream_url = streamUrl(),
    schedule = schedule,
    schedule_count = #schedule,
    schedule_age_s = ageS,
    fetch_count = fetchCount,
    current = current,
  }
end

local function publish()
  noctalia.state.set(STATE_KEY, snapshot())
end

local function setBusy(value)
  busy = value
  if value then
    busySinceMs = nowMs()
  end
  publish()
end

local function onScheduleResponse(res)
  fetching = false
  if not res.ok then
    errorMessage = "schedule: HTTP failed"
    publish()
    return
  end
  local decoded, err = noctalia.json.decode(res.body)
  if decoded == nil then
    errorMessage = "schedule: bad JSON"
    publish()
    return
  end
  local data = decoded.data
  if type(data) ~= "table" then
    errorMessage = "schedule: empty"
    publish()
    return
  end
  local items = {}
  for _, row in ipairs(data) do
    if type(row) == "table" and type(row.title) == "string" then
      table.insert(items, {
        title = row.title,
        fromTime = row.fromTime,
        toTime = row.toTime,
        description = row.description,
      })
      if #items >= MAX_ITEMS then
        break
      end
    end
    if #items >= MAX_ITEMS then
      break
    end
  end
  schedule = items
  current = pickCurrent(schedule)
  lastFetchMs = nowMs()
  fetchCount = fetchCount + 1
  if errorMessage ~= nil and errorMessage:find("^schedule:") ~= nil then
    errorMessage = nil
  end
  publish()
end

local function fetchSchedule()
  if fetching then
    return
  end
  fetching = true
  publish()
  local ok = noctalia.http({
    url = API_URL,
    method = "POST",
    headers = { "Content-Type: application/json" },
    body = '{"Date":null}',
  }, onScheduleResponse)
  if not ok then
    fetching = false
    errorMessage = "schedule: request refused"
    publish()
  end
end

local function scheduleStale()
  if lastFetchMs == 0 then
    return true
  end
  return (nowMs() - lastFetchMs) > (refreshMinutes() * 60 * 1000)
end

local function startPlayback()
  if not mpvAvailable then
    errorMessage = "mpv is not installed"
    publish()
    return
  end
  if playing or busy then
    return
  end
  errorMessage = nil
  setBusy(true)
  local argv = { "mpv", "--no-video", "--title=" .. PROC_TAG, "--user-agent=Mozilla/5.0", streamUrl() }
  local launched = noctalia.runAsync(argv)
  if not launched then
    setBusy(false)
    errorMessage = "mpv: could not be started"
    publish()
    return
  end
  -- The tick confirms via processMatches; assume playing so the UI answers fast.
  playing = true
  setBusy(false)
  publish()
end

local function stopPlayback()
  if not playing and not busy then
    return
  end
  if not pkillAvailable then
    errorMessage = "pkill is not installed"
    publish()
    return
  end
  errorMessage = nil
  setBusy(true)
  noctalia.runAsync({ "pkill", "-f", PROC_TAG }, function(_res)
    playing = false
    setBusy(false)
    publish()
  end, 8000)
end

local function togglePlayback()
  if playing then
    stopPlayback()
  else
    startPlayback()
  end
end

local function handleAction(action)
  if action == "play" then
    startPlayback()
  elseif action == "stop" then
    stopPlayback()
  elseif action == "toggle" then
    togglePlayback()
  elseif action == "refresh" then
    errorMessage = nil
    fetchSchedule()
    current = pickCurrent(schedule)
    publish()
  end
end

local function diagnose()
  local snap = snapshot()
  snap.busy = busy
  snap.fetching = fetching
  snap.mpv = mpvAvailable
  snap.pkill = pkillAvailable
  local dir, dirErr = noctalia.pluginDataDir()
  local path = nil
  if type(dir) == "string" and dir ~= "" then
    path = dir .. "/state.json"
    local encoded = noctalia.json.encode(snap, true)
    if type(encoded) == "string" then
      noctalia.writeFile(path, encoded)
    end
  end
  local summary = "playing=" .. tostring(playing) .. " items=" .. tostring(#schedule)
  if current ~= nil and type(current.title) == "string" then
    summary = summary .. " current=" .. current.title
  end
  if path ~= nil then
    summary = summary .. " path=" .. path
  elseif dirErr ~= nil then
    summary = summary .. " datadir=" .. tostring(dirErr)
  end
  noctalia.log("[misr-quran] diagnose " .. summary)
  return snap
end

noctalia.state.watch(REQUEST_KEY, function(value)
  if type(value) ~= "table" then
    return
  end
  if type(value.action) == "string" then
    handleAction(value.action)
  end
end)

function onIpc(event, payload)
  if event == "request" and type(payload) == "string" and payload ~= "" then
    local decoded = noctalia.json.decode(payload)
    if type(decoded) == "table" and type(decoded.action) == "string" then
      if decoded.action == "diagnose" then
        diagnose()
        return
      end
      handleAction(decoded.action)
      return
    end
  elseif event == "play" then
    startPlayback()
    return
  elseif event == "stop" then
    stopPlayback()
    return
  elseif event == "toggle" then
    togglePlayback()
    return
  elseif event == "refresh" then
    handleAction("refresh")
    return
  elseif event == "diagnose" then
    diagnose()
    return
  end
end

function onConfigChanged()
  current = pickCurrent(schedule)
  publish()
end

function onEnable()
  fetchSchedule()
end

function update()
  clearBusyIfStuck()
  noctalia.processMatches(function(matched)
    if matched ~= playing and not busy then
      playing = matched
      publish()
    elseif busy and matched then
      -- A launch confirmed by the process list: drop the busy flag.
      playing = true
      setBusy(false)
    end
  end, "mpv", PROC_TAG)
  if scheduleStale() and not fetching then
    fetchSchedule()
  else
    local fresh = pickCurrent(schedule)
    local before = nil
    local after = nil
    if current ~= nil then
      before = current.title .. "\0" .. tostring(current.fromTime)
    end
    if fresh ~= nil then
      after = fresh.title .. "\0" .. tostring(fresh.fromTime)
    end
    if before ~= after then
      current = fresh
      publish()
    end
  end
end

fetchSchedule()
publish()
