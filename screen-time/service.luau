--!nonstrict
-- Screen Time service: reads the screen time Noctalia records, once a minute, and publishes
-- today's total and the most used apps.
--
-- Noctalia keeps one entry per day, keyed by the local date: "apps" holds the seconds of
-- each app, "hourly" and "app_hourly" the same by hour.
--
-- Publishes "screen-time.model".

local READ_MS = 60000
local TOP_APPS = 5

local lastReadMs = nil
local reading = false

-- Noctalia's record, unless the data_file setting names another file.
local function dataFile()
  local custom = noctalia.string.trim(noctalia.getConfig("data_file") or "")
  if custom ~= "" then
    return noctalia.expandPath(custom)
  end
  local state = noctalia.getenv("XDG_STATE_HOME")
  if state == nil or state == "" then
    state = noctalia.expandPath("~/.local/state")
  end
  return state .. "/noctalia/screen_time.json"
end

-- Whether Noctalia records screen time. The key is read from its table, since a missing
-- key passed to getSetting logs a warning.
local function recording()
  local shell = noctalia.getSetting("shell")
  return type(shell) ~= "table" or shell.screen_time_enabled ~= false
end

local function read()
  if reading then
    return
  end
  reading = true
  lastReadMs = noctalia.nowMs()
  noctalia.readFileAsync(dataFile(), function(text)
    reading = false
    local data = text and noctalia.json.decode(text)
    local day = type(data) == "table" and data[noctalia.formatTime("%Y-%m-%d")] or nil
    local apps, total = {}, 0
    if type(day) == "table" and type(day.apps) == "table" then
      for id, seconds in pairs(day.apps) do
        if type(seconds) == "number" and seconds > 0 then
          total += seconds
          table.insert(apps, { id = id, seconds = seconds })
        end
      end
    end
    table.sort(apps, function(a, b)
      return a.seconds > b.seconds
    end)
    local top = {}
    for index = 1, math.min(#apps, TOP_APPS) do
      table.insert(top, apps[index])
    end
    noctalia.state.set("screen-time.model", {
      recording = recording(),
      found = type(data) == "table",
      total = total,
      apps = top,
    })
  end)
end

function update()
  if lastReadMs == nil or noctalia.nowMs() - lastReadMs >= READ_MS then
    read()
  end
end

function onConfigChanged()
  read()
end

noctalia.setUpdateInterval(5000)
read()
