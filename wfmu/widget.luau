--!nonstrict
-- WFMU bar widget: shows the current stream and opens the browse panel.

local data_dir = noctalia.pluginDataDir()
local plugin_dir = noctalia.pluginDir() or ""
local pid_file = data_dir .. "/mpv.pid"
local ipc_sock = data_dir .. "/mpv.sock"
local idle_interval = 5000
local refresh_interval = 1000

local function configure(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil or value == "" then
    return fallback
  end
  return value
end

local tsv_path = configure("tsv_path", data_dir .. "/latest-archives.tsv")
local refresh_cmd = configure("refresh_cmd", string.format(
  "python3 %q --out %q", plugin_dir .. "/scripts/wfmu_archives.py", tsv_path))
local refreshing = false
local refreshStartedAt = 0
local refreshBaseMtime = 0
local refreshSeq = 0
local lastMetaPoll = 0
local lastLiveTitle = nil

local function stopPlayback()
  if pid_file ~= "" then
    noctalia.runAsync(string.format(
      "if [ -f %q ]; then kill $(cat %q) 2>/dev/null; rm -f %q; fi; rm -f %q",
      pid_file, pid_file, pid_file, ipc_sock))
  end
  noctalia.state.set("now", nil)
  noctalia.state.set("paused", false)
  noctalia.state.set("now_playing", nil)
  lastLiveTitle = nil
end

local function startPlayback(name, url)
  noctalia.runAsync(string.format(
    "if [ -f %q ]; then kill $(cat %q) 2>/dev/null; fi; rm -f %q %q; mpv --no-video --input-ipc-server=%q %q >/dev/null 2>&1 & echo $! > %q",
    pid_file, pid_file, pid_file, ipc_sock, ipc_sock, url, pid_file))
  noctalia.state.set("now", name or "WFMU")
  noctalia.state.set("last_name", name)
  noctalia.state.set("last_url", url)
  noctalia.state.set("seekable", string.find(url, "mp3archives.wfmu.org", 1, true) ~= nil or string.find(url, "/archive/", 1, true) ~= nil or string.sub(url, -4) == ".mp3" or string.sub(url, -4) == ".mp4")
  noctalia.state.set("paused", false)
end

local function playRandom()
  local raw = noctalia.readFile(tsv_path)
  if not raw then
    noctalia.notifyError("WFMU", "no stream list yet")
    return
  end
  local list = {}
  for line in raw:gmatch("[^\r\n]+") do
    local tab = string.find(line, "\t", 1, true)
    if tab then
      local url = noctalia.string.trim(line:sub(tab + 1))
      local name = noctalia.string.trim(line:sub(1, tab - 1))
      if url ~= "" then
        list[#list + 1] = { name = name, url = url }
      end
    end
  end
  if #list == 0 then
    noctalia.notifyError("WFMU", "no streams to pick from")
    return
  end
  local pick = list[math.random(1, #list)]
  startPlayback(pick.name, pick.url)
end

local function refreshDone(timedOut)
  refreshing = false
  noctalia.setUpdateInterval(idle_interval)
  refreshSeq = refreshSeq + 1
  noctalia.state.set("refresh_seq", refreshSeq)
  if timedOut then
    noctalia.notifyError("WFMU", "refresh timed out")
  else
    noctalia.notify("WFMU", "Archives refreshed")
  end
end

local function checkRefresh()
  if not refreshing then
    return
  end
  if os.time() - refreshStartedAt >= 360 then
    refreshDone(true)
    return
  end
  local info = tsv_path and noctalia.fileInfo(tsv_path)
  if info and info.mtime and info.mtime > refreshBaseMtime then
    refreshDone()
  end
end

local function refresh()
  if refreshing then
    return
  end
  local ok = noctalia.runAsync(refresh_cmd)
  if not ok then
    noctalia.notifyError("WFMU", "could not start refresh")
    return
  end
  refreshStartedAt = os.time()
  local info = tsv_path and noctalia.fileInfo(tsv_path)
  refreshBaseMtime = info and info.mtime or 0
  refreshing = true
  noctalia.setUpdateInterval(refresh_interval)
  noctalia.state.set("refresh_requested", false)
end

local meta_path = data_dir .. "/mpv-title.txt"
local fetch_cmd = [====[
python3 -c 'import socket,json,sys,time
try:
 s=socket.socket(socket.AF_UNIX)
 s.connect(sys.argv[1])
 s.send((json.dumps({"command":["get_property","media-title"]})+"\n").encode())
 time.sleep(1)
 d=json.loads(s.recv(8192))
 t=str(d.get("data") or "")
except Exception:
 t=""
open(sys.argv[2],"w").write(t)' %q %q
]====]

local function pollLiveTitle()
  local now = noctalia.state.get("now")
  if not (now and now ~= "") then
    return
  end
  local t = os.time()
  if t - lastMetaPoll < 8 then
    return
  end
  lastMetaPoll = t
  noctalia.runAsync(string.format(fetch_cmd, ipc_sock, meta_path))
  local raw = noctalia.readFile(meta_path)
  if raw then
    local title = noctalia.string.trim(raw)
    if title ~= lastLiveTitle then
      lastLiveTitle = title
      noctalia.state.set("now_playing", title)
    end
  end
end

function update()
  checkRefresh()
  pollLiveTitle()
end

noctalia.state.watch("refresh_requested", function(value)
  if value then
    refresh()
  end
end)

noctalia.setUpdateInterval(idle_interval)

local function show()
  local now = noctalia.state.get("now")
  local lines = {}
  lines[1] = (now and now ~= "") and now or "WFMU"
  if now and now ~= "" then
    local np = noctalia.state.get("now_playing")
    if np and np ~= "" then
      lines[#lines + 1] = np
    end
  end
  barWidget.setTooltip(table.concat(lines, "\n"))
end

barWidget.setGlyph("dog")

noctalia.state.watch("now", show)
noctalia.state.watch("now_playing", show)

show()

local function playDefault()
  local raw = noctalia.readFile(tsv_path)
  if not raw then
    noctalia.notifyError("WFMU", "no stream list yet")
    return
  end
  for line in raw:gmatch("[^\r\n]+") do
    local tab = string.find(line, "\t", 1, true)
    if tab then
      local url = noctalia.string.trim(line:sub(tab + 1))
      local name = noctalia.string.trim(line:sub(1, tab - 1))
      if url ~= "" and string.find(url, "wfmu.org", 1, true) and not string.find(url, "mp3archives", 1, true) then
        startPlayback(name, url)
        return
      end
    end
  end
  noctalia.notifyError("WFMU", "no live stream found")
end

function onClick()
  noctalia.togglePanel("quaversa/wfmu:browse")
end

function onRightClick()
  local now = noctalia.state.get("now")
  if now and now ~= "" then
    stopPlayback()
  else
    playDefault()
  end
end

function onMiddleClick()
  playRandom()
end

function onIpc(event, _payload)
  if event == "stop" then
    stopPlayback()
  elseif event == "refresh" then
    refresh()
  elseif event == "random" then
    playRandom()
  elseif event == "play" then
    local name = noctalia.state.get("last_name")
    local url
    if _payload and _payload ~= "" then
      url = _payload
    else
      url = noctalia.state.get("last_url")
    end
    if url and url ~= "" then
      startPlayback(name or "WFMU", url)
    end
  end
end

function onExit()
  stopPlayback()
end