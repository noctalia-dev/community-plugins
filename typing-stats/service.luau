--!nonstrict
-- Typing Stats - headless counter with per-day history.
--
-- Runs the printable-key listener, keeps a total and a per-day count, and
-- publishes the summary the bar capsule needs. The history is persisted to the
-- plugin data dir and drives the bar capsule and the calendar heatmap.

local pluginDir = noctalia.pluginDir() or ""
local listenerPath = pluginDir .. "/scripts/typelisten.py"

local active = noctalia.getConfig("enabled") ~= false
local blockSize = tonumber(noctalia.getConfig("block_size")) or 100
blockSize = math.max(1, math.min(100000, math.floor(blockSize + 0.5)))

local DEFAULT_THRESHOLDS = { 500, 1000, 2000, 5000 }
local function parseThresholds(raw)
  local values = {}
  if type(raw) == "string" then
    for part in string.gmatch(raw, "[^,;%s]+") do
      local value = tonumber(part)
      if value ~= nil and value > 0 then
        values[#values + 1] = math.floor(value + 0.5)
      end
    end
  end
  if #values < 4 then
    return { DEFAULT_THRESHOLDS[1], DEFAULT_THRESHOLDS[2], DEFAULT_THRESHOLDS[3], DEFAULT_THRESHOLDS[4] }
  end
  table.sort(values)
  return { values[1], values[2], values[3], values[4] }
end
local thresholds = parseThresholds(noctalia.getConfig("thresholds"))
local levelNotify = noctalia.getConfig("level_notify") ~= false

local function levelOf(count)
  if count <= 0 or count < thresholds[1] then
    return 0
  elseif count < thresholds[2] then
    return 1
  elseif count < thresholds[3] then
    return 2
  elseif count < thresholds[4] then
    return 3
  end
  return 4
end

local function numberText(value)
  local text = tostring(math.floor(value))
  local out = ""
  while #text > 3 do
    out = "," .. text:sub(-3) .. out
    text = text:sub(1, -4)
  end
  return text .. out
end

-- ── Focused-window filter (niri) ────────────────────────────────────────────
local filterMode = "off"
local filterSet = {}
local focusedApp = ""
local windowApps = {}
local niriStreaming = false

local function trim(value)
  return string.match(value, "^%s*(.-)%s*$") or value
end

local function normalizeApp(value)
  if type(value) ~= "string" then
    return ""
  end
  return string.lower(trim(value))
end

local function refreshFilter()
  local mode = noctalia.getConfig("filter_mode")
  if mode ~= "whitelist" and mode ~= "blacklist" then
    mode = "off"
  end
  filterMode = mode

  filterSet = {}
  local apps = noctalia.getConfig("filter_apps")

  local function addEntry(entry)
    if type(entry) ~= "string" then
      return
    end
    entry = trim(entry)
    entry = entry:gsub("^%[", ""):gsub("%]$", "")
    entry = entry:gsub('^"', ""):gsub('"$', "")
    local key = normalizeApp(entry)
    if key ~= "" then
      filterSet[key] = true
    end
  end

  if type(apps) == "table" then
    for _, entry in ipairs(apps) do
      addEntry(entry)
    end
  elseif type(apps) == "string" then
    -- The host may hand a string_list back as a comma-separated string.
    for item in (apps .. ","):gmatch("([^,]*),") do
      addEntry(item)
    end
  end
end

local function allowsFocusedApp()
  if filterMode == "off" then
    return true
  end
  local listed = focusedApp ~= "" and filterSet[focusedApp] == true
  local allowed
  if filterMode == "whitelist" then
    allowed = listed
  else
    allowed = not listed
  end
  return allowed
end

local function handleNiri(line)
  local ok, event = pcall(noctalia.json.decode, line)
  if not ok or type(event) ~= "table" then
    return
  end

  if type(event.WindowsChanged) == "table" and type(event.WindowsChanged.windows) == "table" then
    local focused = ""
    for _, window in ipairs(event.WindowsChanged.windows) do
      if type(window) == "table" then
        local id = tonumber(window.id)
        local app = normalizeApp(window.app_id)
        if id ~= nil then
          windowApps[id] = app
        end
        if window.is_focused == true then
          focused = app
        end
      end
    end
    focusedApp = focused
  end

  if type(event.WindowOpenedOrChanged) == "table" and type(event.WindowOpenedOrChanged.window) == "table" then
    local window = event.WindowOpenedOrChanged.window
    local id = tonumber(window.id)
    local app = normalizeApp(window.app_id)
    if id ~= nil then
      windowApps[id] = app
    end
    if window.is_focused == true then
      focusedApp = app
    end
  end

  if type(event.WindowClosed) == "table" then
    local id = tonumber(event.WindowClosed.id)
    if id ~= nil then
      windowApps[id] = nil
    end
  end

  if event.WindowFocusChanged ~= nil then
    local payload = event.WindowFocusChanged
    local id = type(payload) == "table" and tonumber(payload.id) or nil
    if id == nil then
      focusedApp = ""
    else
      focusedApp = windowApps[id] or ""
    end
  end
end

local function pollFocus()
  if not noctalia.commandExists("niri") then
    return
  end
  noctalia.runAsync({ "niri", "msg", "--json", "focused-window" }, function(result)
    if result == nil or result.exitCode ~= 0 then
      return
    end
    local ok, window = pcall(noctalia.json.decode, result.stdout)
    if ok and type(window) == "table" then
      focusedApp = normalizeApp(window.app_id)
    end
  end, 3000)
end

local function startNiri()
  if niriStreaming or not noctalia.commandExists("niri") then
    return
  end
  niriStreaming = noctalia.runStream("niri msg --json event-stream", handleNiri)
  if not niriStreaming then
    noctalia.log("typing-stats: niri event stream unavailable; window filter will use polling")
  end
end

local function dateToday()
  return os.date("%Y-%m-%d")
end

local chars = 0
local days = {}
local today = dateToday()
local displayMode = "today"

local running = false
local startedAt = 0
local lastLine = 0
local dirty = false
local warnedNoAccess = false

local dataDir = noctalia.pluginDataDir()
local savePath = nil
if dataDir ~= nil and dataDir ~= "" then
  savePath = dataDir .. "/stats.json"
end

local function shellQuote(value)
  return "'" .. string.gsub(value, "'", "'\\''") .. "'"
end

local function load()
  if savePath == nil then
    return
  end
  local contents = noctalia.readFile(savePath)
  if contents == nil then
    return
  end

  local ok, data = pcall(noctalia.json.decode, contents)
  if not ok or type(data) ~= "table" then
    return
  end

  chars = math.max(0, math.floor((tonumber(data.chars) or 0) + 0.5))
  displayMode = data.display_mode == "total" and "total" or "today"

  if type(data.days) == "table" then
    for date, count in pairs(data.days) do
      if type(date) == "string" and type(count) == "number" and count > 0 then
        days[date] = math.floor(count + 0.5)
      end
    end
  end

  if chars == 0 and next(days) ~= nil then
    for _, count in pairs(days) do
      chars = chars + count
    end
  end

  -- Migrate a v1 file (total only): the old total was typed today.
  if chars > 0 and next(days) == nil then
    days[today] = chars
  end

  if days[today] == nil then
    days[today] = 0
  end
end

-- One publish per key press would redraw the capsule and the panel at typing
-- speed, so coalesce to at most four per second; discrete events (reset, mode,
-- date rollover, config change) still publish immediately.
local PUBLISH_MIN_MS = 250
local lastPublish = 0
local publishPending = false

local function publish(force)
  if not force and noctalia.nowMs() - lastPublish < PUBLISH_MIN_MS then
    publishPending = true
    return
  end
  publishPending = false
  lastPublish = noctalia.nowMs()
  local todayChars = days[today] or 0
  noctalia.state.set("stats", {
    total_chars = chars,
    today_chars = todayChars,
    total_blocks = math.floor(chars / blockSize),
    total_progress = (chars % blockSize) / blockSize,
    today_blocks = math.floor(todayChars / blockSize),
    today_progress = (todayChars % blockSize) / blockSize,
    block_size = blockSize,
    thresholds = thresholds,
    mode = displayMode,
    today = today,
  })
end

local function save()
  if not dirty or savePath == nil then
    return
  end
  local ok, encoded = pcall(noctalia.json.encode, {
    version = 2,
    chars = chars,
    today = today,
    days = days,
    display_mode = displayMode,
  }, false)
  if not ok or encoded == nil then
    return
  end
  if noctalia.writeFile(savePath, encoded) then
    dirty = false
  end
end

local function ensureToday()
  local nowDate = dateToday()
  if nowDate ~= today then
    today = nowDate
    if days[today] == nil then
      days[today] = 0
    end
    dirty = true
    publish(true)
  elseif days[today] == nil then
    days[today] = 0
  end
end

local function add(count)
  if count <= 0 then
    return
  end
  ensureToday()
  local before = levelOf(days[today] or 0)
  chars = chars + count
  days[today] = (days[today] or 0) + count
  local after = levelOf(days[today] or 0)
  if levelNotify and after > before then
    noctalia.notify(noctalia.tr("notify.level.title"), noctalia.tr("notify.level.body", {
      count = numberText(days[today] or 0),
      level = after,
    }))
  end
  dirty = true
  publish()
end

local function reset()
  chars = 0
  days = {}
  today = dateToday()
  days[today] = 0
  dirty = true
  publish(true)
  save()
  noctalia.notify(noctalia.tr("notify.reset.title"), noctalia.tr("notify.reset.body"))
end

local function handleLine(line)
  lastLine = noctalia.nowMs()

  if line == "C" then
    if active and allowsFocusedApp() then
      add(1)
    end
    return
  end

  if string.sub(line, 1, 4) == "ERR " then
    noctalia.log("typing-stats: " .. string.sub(line, 5))
    if not warnedNoAccess then
      warnedNoAccess = true
      noctalia.notifyError(noctalia.tr("notify.no_access.title"), noctalia.tr("notify.no_access.body"))
    end
  end
end

local function startListener()
  if running or not active then
    return
  end
  if not noctalia.commandExists("python3") then
    noctalia.log("typing-stats: python3 is missing; cannot count keys")
    return
  end

  startedAt = noctalia.nowMs()
  lastLine = startedAt
  running = noctalia.runStream("python3 -u " .. shellQuote(listenerPath), handleLine)
  if not running then
    noctalia.log("typing-stats: could not start the key listener")
  end
end

local function setMode(mode)
  local nextMode = mode == "total" and "total" or "today"
  if nextMode == displayMode then
    return
  end
  displayMode = nextMode
  dirty = true
  noctalia.state.set("display_mode", displayMode)
  publish(true)
  save()
end

-- The bar widget and the shortcut tiles talk to the service through state.
noctalia.state.watch("display_mode", function(value)
  setMode(value)
end)

noctalia.state.watch("command", function(command)
  if type(command) ~= "table" then
    return
  end
  if command.action == "reset" then
    reset()
  end
end)

noctalia.setUpdateInterval(5000)

function update()
  ensureToday()
  save()
  if publishPending then
    publish(true)
  end
  if filterMode ~= "off" then
    pollFocus()
  end

  if not active then
    return
  end
  if not running then
    startListener()
    return
  end

  local now = noctalia.nowMs()
  if now - startedAt > 45000 and now - lastLine > 45000 then
    noctalia.log("typing-stats: key listener went silent; restarting")
    running = false
    startListener()
  end
end

function onConfigChanged()
  active = noctalia.getConfig("enabled") ~= false
  blockSize = tonumber(noctalia.getConfig("block_size")) or 100
  blockSize = math.max(1, math.min(100000, math.floor(blockSize + 0.5)))
  thresholds = parseThresholds(noctalia.getConfig("thresholds"))
  levelNotify = noctalia.getConfig("level_notify") ~= false
  refreshFilter()
  if filterMode ~= "off" then
    startNiri()
    pollFocus()
  end

  if active then
    startListener()
  end
  publish(true)
end

function onIpc(event, payload)
  if event == "reset" then
    reset()
  elseif event == "add" then
    add(math.max(0, math.floor((tonumber(payload) or 0) + 0.5)))
  elseif event == "filter_off" then
    filterMode = "off"
    filterSet = {}
    publish(true)
  elseif event == "mode" then
    setMode(payload)
  elseif event == "reload" then
    onConfigChanged()
  end
end

function onExit()
  ensureToday()
  save()
end

load()
refreshFilter()
publish(true)
noctalia.state.set("display_mode", displayMode)
startListener()
if filterMode ~= "off" then
  startNiri()
  pollFocus()
end
