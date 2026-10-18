--!nonstrict
-- WFMU bar widget: shows the current stream and opens the browse panel.

local data_dir = noctalia.pluginDataDir()
local pid_file = data_dir .. "/mpv.pid"
local ipc_sock = data_dir .. "/mpv.sock"
local idle_interval = 5000

local function configure(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil or value == "" then
    return fallback
  end
  return value
end

-- Single-quote a value for the shell, so a crafted URL or path containing $, `
-- or " can never be expanded into a second command.
local function shq(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local tsv_path = configure("tsv_path", data_dir .. "/latest-archives.tsv")

-- Static live streams, mirrored from scripts/wfmu_archives.py, so the widget can
-- still play something before the archive list has downloaded. Keep in sync.
local SEED_TSV = table.concat({
  "WFMU 91.1 East Orange, NJ\thttp://stream2.wfmu.org/freeform-128k",
  "WFMU Give the Drummer Radio\thttp://stream0.wfmu.org/drummer",
  "WFMU Rock'n'Soul Radio\thttps://wfmu.org/wfmu_rock.pls",
  "WFMU Sheena's Jungle Room\thttps://wfmu.org/wfmu_sheena.pls",
}, "\n") .. "\n"

-- Fall back to the live streams when the archive list is not there yet.
local function readList()
  return noctalia.readFile(tsv_path) or SEED_TSV
end

local refreshing = false
local lastMetaPoll = 0
local lastLiveTitle = nil

local function stopPlayback()
  if pid_file ~= "" then
    noctalia.runAsync(string.format(
      "if [ -f %s ]; then kill $(cat %s) 2>/dev/null; rm -f %s; fi; rm -f %s",
      shq(pid_file), shq(pid_file), shq(pid_file), shq(ipc_sock)))
  end
  noctalia.state.set("now", nil)
  noctalia.state.set("paused", false)
  noctalia.state.set("now_playing", nil)
  lastLiveTitle = nil
end

local function startPlayback(name, url)
  noctalia.runAsync(string.format(
    "if [ -f %s ]; then kill $(cat %s) 2>/dev/null; fi; rm -f %s %s; mpv --no-video --input-ipc-server=%s %s >/dev/null 2>&1 & echo $! > %s",
    shq(pid_file), shq(pid_file), shq(pid_file), shq(ipc_sock), shq(ipc_sock), shq(url), shq(pid_file)))
  noctalia.state.set("now", name or "WFMU")
  noctalia.state.set("last_name", name)
  noctalia.state.set("last_url", url)
  noctalia.state.set("seekable", string.find(url, "mp3archives.wfmu.org", 1, true) ~= nil or string.find(url, "/archive/", 1, true) ~= nil or string.sub(url, -4) == ".mp3" or string.sub(url, -4) == ".mp4")
  noctalia.state.set("paused", false)
end

-- "<label>\t<url>" lines. Archives carry a third column with an ordering stamp;
-- the URL is always the field right after the first tab.
local function urlField(line, tab)
  return noctalia.string.trim(line:sub(tab + 1):match("^[^\t]*") or "")
end

local function playRandom()
  local raw = readList()
  local list = {}
  for line in raw:gmatch("[^\r\n]+") do
    local tab = string.find(line, "\t", 1, true)
    if tab then
      local url = urlField(line, tab)
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
  math.randomseed(os.time())
  local pick = list[math.random(1, #list)]
  startPlayback(pick.name, pick.url)
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
open(sys.argv[2],"w").write(t)' %s %s
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
  noctalia.runAsync(string.format(fetch_cmd, shq(ipc_sock), shq(meta_path)))
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
  pollLiveTitle()
end

noctalia.setUpdateInterval(idle_interval)

-- Our labels carry the air date ("Smile for the Camera (Sep 19)") and WFMU's own
-- stream titles read "<Show> from <date>". Both lines get the date shaved off:
-- line 1 is the show, line 2 the song. When the title was only the show over
-- again, the second line is dropped rather than repeated. Keep in sync with
-- stripDate() in panel.luau.
local function stripDate(text)
  local t = text or ""
  t = t:gsub("%s*%b()%s*$", " ")
  t = t:gsub("%s*[Ff]rom%s+[^%d]*%d[%d%p%s:-]*$", " ")
  do
    local lower = string.lower(t)
    for _, m in ipairs({ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" }) do
      local match = lower:match("%s+" .. m .. "[a-z]*%s+%d%d?,?%s*%d%d%d%d%s*$")
      if match then
        -- The match is a plain-ASCII date suffix, so its byte length is the same
        -- in the original; cut it off instead of replacing the value with its
        -- lowercased form, which would lowercase the show name as well.
        t = t:sub(1, #t - #match)
        break
      end
    end
  end
  t = t:gsub("%s*[%-–—:]?%s*%d%d%d%d%-%d%d%-%d%d%s*$", " ")
  t = t:gsub("%s*[%-–—:]?%s*%d?%d/%d?%d/%d%d%d%d%s*$", " ")
  t = t:gsub("%s+", " ")
  return noctalia.string.trim(t)
end

local function show()
  local now = noctalia.state.get("now")
  local lines = {}
  local showName = stripDate(now)
  lines[1] = showName ~= "" and showName or "WFMU"
  local song = stripDate(noctalia.state.get("now_playing"))
  if song ~= "" and string.lower(song) ~= string.lower(showName) then
    lines[#lines + 1] = song
  end
  if refreshing then
    lines[#lines + 1] = "updating stream list…"
  end
  barWidget.setTooltip(table.concat(lines, "\n"))
end

barWidget.setGlyph("dog")

noctalia.state.watch("now", show)
noctalia.state.watch("now_playing", show)
noctalia.state.watch("refreshing", function(value)
  refreshing = value == true
  show()
end)

refreshing = noctalia.state.get("refreshing") == true
show()

local function playDefault()
  local raw = readList()
  for line in raw:gmatch("[^\r\n]+") do
    local tab = string.find(line, "\t", 1, true)
    if tab then
      local url = urlField(line, tab)
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
    noctalia.state.set("refresh_requested", true)
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