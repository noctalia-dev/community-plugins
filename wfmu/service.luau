--!nonstrict
-- WFMU stream-list service: downloads the archive list on load and keeps it
-- fresh, so the browse panel is populated the first time it is opened instead
-- of starting blank. It publishes "refreshing" and "refresh_seq" to the
-- plugin's shared state; the widget and panel watch those.

local data_dir = noctalia.pluginDataDir()
local plugin_dir = noctalia.pluginDir() or ""

-- Rebuild the list when it is missing or older than this (the newest archive of
-- each show changes at most daily, so six hours is plenty fresh).
local MAX_AGE = 6 * 3600
-- An update tick while a download is in flight, and while idle. Idle only
-- re-checks the age of a six-hour-old list, so it can be slow.
local REFRESH_INTERVAL = 1000
local IDLE_INTERVAL = 60000
-- Give up on a download that has not written a new list after this long.
local TIMEOUT = 360

local tsv_path = ""
local refresh_cmd = ""

local refreshing = false
local startedAt = 0
local baseMtime = 0
local seq = 0
local notifyWhenDone = false

local function configure(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil or value == "" then
    return fallback
  end
  return value
end

-- Single-quote a value for the shell, so a path containing $, ` or " can never
-- be expanded into a second command.
local function shq(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function resolvePaths()
  data_dir = noctalia.pluginDataDir()
  plugin_dir = noctalia.pluginDir() or ""
  tsv_path = configure("tsv_path", data_dir .. "/latest-archives.tsv")
  refresh_cmd = configure("refresh_cmd", string.format(
    "python3 %s --out %s", shq(plugin_dir .. "/scripts/wfmu_archives.py"), shq(tsv_path)))
end

local function listAge()
  if tsv_path == "" then
    return nil
  end
  local info = noctalia.fileInfo(tsv_path)
  if not info or not info.mtime or info.mtime == 0 then
    return nil
  end
  return os.time() - info.mtime
end

local function finish(timedOut)
  refreshing = false
  noctalia.setUpdateInterval(IDLE_INTERVAL)
  noctalia.state.set("refreshing", false)
  if timedOut then
    noctalia.notifyError("WFMU", "stream list download timed out")
  elseif notifyWhenDone then
    noctalia.notify("WFMU", "Stream list updated")
  end
  notifyWhenDone = false
  if not timedOut then
    seq = seq + 1
    noctalia.state.set("refresh_seq", seq)
  end
end

local function fetch(fromUser)
  if refreshing then
    return
  end
  local ok = noctalia.runAsync(refresh_cmd)
  if not ok then
    if fromUser then
      noctalia.notifyError("WFMU", "could not start stream list download")
    end
    return
  end
  local info = tsv_path ~= "" and noctalia.fileInfo(tsv_path)
  baseMtime = info and info.mtime or 0
  startedAt = os.time()
  refreshing = true
  notifyWhenDone = fromUser == true
  noctalia.state.set("refreshing", true)
  noctalia.setUpdateInterval(REFRESH_INTERVAL)
end

local function ensure()
  if refreshing then
    return
  end
  local age = listAge()
  if age == nil or age > MAX_AGE then
    fetch(false)
  end
end

resolvePaths()
noctalia.setUpdateInterval(IDLE_INTERVAL)
noctalia.state.set("refreshing", false)
ensure()

function update()
  if not refreshing then
    ensure()
    return
  end
  if os.time() - startedAt >= TIMEOUT then
    finish(true)
    return
  end
  local info = tsv_path ~= "" and noctalia.fileInfo(tsv_path)
  if info and info.mtime and info.mtime > baseMtime then
    finish(false)
  end
end

function onEnable()
  ensure()
end

function onConfigChanged()
  resolvePaths()
  ensure()
end

-- The widget, panel, and IPC all ask for a download through this flag.
noctalia.state.watch("refresh_requested", function(value)
  if value then
    noctalia.state.set("refresh_requested", false)
    fetch(true)
  end
end)
