--!nonstrict
-- [[service]] entry: owns the single headless mpv process.
-- Others publish plain tables to noctalia.state "pod_request"; this service
-- executes them and publishes "pod_status" back.
--
--   request = { seq = n, action = "play" | "stop" | "volume",
--               podcast = "...", episode = "...", url = "...", volume = 0-100 }
--   status  = { playing = bool, podcast = "...", episode = "...",
--               url = "...", volume = 0-100 }
--
-- Process bookkeeping is PID-based only. Never pattern-match our own socket
-- path with pkill/pgrep: the matcher's own command line contains that string
-- (suicide for pkill, always-true for pgrep).
--
-- Every mpv transition runs through one ordered queue (enqueue below): a new
-- episode starts only after the previous mpv has really exited. Two live
-- instances share a single socket path and a single pidfile, so the loser
-- becomes unreachable and can only be killed from a terminal (same bug as
-- fel/radio #1094).

local dataDir = noctalia.pluginDataDir()
local SOCK = dataDir .. "/mpv.sock"
local PIDFILE = dataDir .. "/mpv.pid"
local POSFILE = dataDir .. "/positions.json"
local QUEUE_STUCK_SECS = 15

local rss = require("./lib/rss.luau")

local volume = math.clamp(math.floor(tonumber(noctalia.getConfig("default_volume")) or 70), 0, 100)
local mpvBin = noctalia.getConfig("mpv_bin") or "mpv"
local hasSocat = noctalia.commandExists("socat")

-- mpv-mpris exposes our headless mpv on MPRIS so the desktop media player
-- (Noctalia media widget, playerctl, media keys) sees it. Auto-detected;
-- most distros ship it (Arch: pacman -S mpv-mpris).
local function mprisScript()
  if noctalia.getConfig("mpris") == false then
    return nil
  end
  local custom = noctalia.string.trim(tostring(noctalia.getConfig("mpris_path") or ""))
  if custom ~= "" and noctalia.fileExists(custom) then
    return custom
  end
  local home = noctalia.getenv("HOME") or "~"
  local candidates = {
    home .. "/.config/mpv/scripts/mpris.so",
    "/usr/lib/mpv-mpris/mpris.so",
    "/usr/local/lib/mpv-mpris/mpris.so",
  }
  for _, p in ipairs(candidates) do
    if noctalia.fileExists(p) then
      return p
    end
  end
  return nil
end

local status = { playing = false, paused = false, podcast = "", episode = "", url = "", volume = volume, pos = 0, dur = 0 }
local lastSeq = -1
local launchedAt = 0
local deadStreak = 0
local pollCount = 0
local pendingSeek = nil
-- Bumped by every play and stop: queued transitions compare it and drop
-- themselves when a newer request has taken over the player.
local playGen = 0
local queue, queueBusy, queueSince = {}, false, 0

local positions = {}
do
  local raw = noctalia.readFile(POSFILE)
  if raw then
    local data = noctalia.json.decode(raw)
    if type(data) == "table" then
      positions = data
    end
  end
end

local function savePositions()
  noctalia.writeFile(POSFILE, noctalia.json.encode(positions) or "{}")
end

noctalia.log("[podcast] player loaded: datadir=" .. tostring(dataDir) .. " mpv=" .. tostring(mpvBin) .. " socat=" .. tostring(hasSocat))

local function publish()
  noctalia.state.set("pod_status", {
    playing = status.playing,
    paused = status.paused,
    podcast = status.podcast,
    episode = status.episode,
    url = status.url,
    volume = status.volume,
    pos = status.pos,
    dur = status.dur,
  })
end

local function sq(s)
  return "'" .. string.gsub(s or "", "'", "'\\''") .. "'"
end

local function aliveCheck(onResult)
  local cmd = "test -S " .. sq(SOCK) .. " && test -f " .. sq(PIDFILE)
    .. " && p=$(tail -n 1 " .. sq(PIDFILE) .. ") && case \"$p\" in *[!0-9]*) exit 1 ;; esac && kill -0 \"$p\" 2>/dev/null"
    .. " && grep -qa mpv /proc/\"$p\"/cmdline 2>/dev/null"
  noctalia.runAsync(cmd, function(res)
    onResult(res.exitCode == 0)
  end)
end

-- One JSON IPC command delivered through a host-written file: no shell
-- quoting involved, always newline terminated (mpv ignores unterminated
-- commands on disconnect).
local function mpvCmd(payload)
  noctalia.writeFile(dataDir .. "/mpvcmd.json", payload .. "\n")
  return "(socat - " .. sq(SOCK) .. " < " .. sq(dataDir .. "/mpvcmd.json") .. " >/dev/null 2>&1 || true)"
end

-- Kill loop over every PID recorded in PIDFILE that is still an mpv we started.
-- The evidence is read-only: /proc/<pid>/cmdline must mention mpv *and* the
-- plugin data dir (seen in our own --input-ipc-server argument), so a stale or
-- recycled PID can never take out an unrelated process.
local function killRecorded(signal)
  local guard = "grep -qa mpv /proc/\"$p\"/cmdline 2>/dev/null && grep -qaF -- "
    .. sq(dataDir) .. " /proc/\"$p\"/cmdline 2>/dev/null"
  return "while read -r p; do case \"$p\" in ''|*[!0-9]*) continue ;; esac; "
    .. "if " .. guard .. "; then kill " .. signal .. " \"$p\" >/dev/null 2>&1 || true; fi; done < "
    .. sq(PIDFILE)
end

-- Sweep for instances the pidfile does not know about: one pass over
-- /proc/*/cmdline for our unique socket path, which only this plugin's mpv
-- carries. Two guards keep it surgical - the process must be running the mpv
-- binary (so the shell running this sweep, whose own cmdline contains the same
-- text, can never match itself) and must have our socket on its command line.
local function sweepStray(signal)
  local comm = string.match(mpvBin, "([^/]+)$") or "mpv"
  return "for f in $(grep -laF -- " .. sq(SOCK) .. " /proc/[0-9]*/cmdline 2>/dev/null); do "
    .. "p=${f#/proc/}; p=${p%/cmdline}; "
    .. "[ \"$(cat /proc/$p/comm 2>/dev/null)\" = " .. sq(comm) .. " ] || continue; "
    .. "kill " .. signal .. " \"$p\" >/dev/null 2>&1 || true; done"
end

local function killStrays(signal)
  return "if [ -f " .. sq(PIDFILE) .. " ]; then " .. killRecorded(signal) .. "; fi; "
    .. sweepStray(signal)
end

local function stopMpv(onDone)
  -- Quit over IPC first (clean mpv shutdown), then make sure nothing survived:
  -- recorded PIDs plus a sweep for strays the pidfile lost track of. onDone only
  -- fires once every process is gone, so the next stream may reuse the socket.
  local parts = {}
  if hasSocat then
    table.insert(parts, mpvCmd('{"command":["quit"]}'))
  end
  table.insert(parts, "sleep 0.3")
  table.insert(parts, killStrays(""))
  table.insert(parts, "sleep 0.4")
  table.insert(parts, killStrays("-9"))
  table.insert(parts, "rm -f " .. sq(SOCK) .. " " .. sq(PIDFILE))
  noctalia.runAsync(table.concat(parts, "; "), function()
    if onDone then
      onDone()
    end
  end)
end

local function launchMpv(url, name, startSecs, onDone)
  -- Only reached with no live instance (enqueue -> stopMpv guarantees it). The
  -- PID is appended, never truncated: a launch that outlived its stop stays
  -- known to the next stop.
  local startArg = ""
  if startSecs and startSecs > 10 then
    startArg = " --start=" .. tostring(math.floor(startSecs))
  end
  local scriptArg = ""
  local mpris = mprisScript()
  if mpris then
    scriptArg = " --script=" .. sq(mpris)
  end
  -- force-media-title feeds MPRIS (Noctalia media widget) and audio metadata.
  local mediaTitle = string.gsub(name or "podcast", "\n", " ")
  local cmd = "rm -f " .. sq(SOCK) .. "; "
    .. "nohup " .. sq(mpvBin) .. " --no-video --input-ipc-server=" .. sq(SOCK)
    .. " --volume=" .. tostring(status.volume) .. startArg .. scriptArg
    .. " --force-media-title=" .. sq(mediaTitle)
    .. " --title=" .. sq("podcast: " .. name)
    -- "--" ends option parsing: a hostile episode URL cannot be read as mpv flags.
    .. " -- " .. sq(url) .. " >" .. sq(dataDir .. "/mpv.log") .. " 2>&1 & "
    .. "echo $! >> " .. sq(PIDFILE)
  noctalia.writeFile(dataDir .. "/lastcmd.txt", cmd)
  return noctalia.runAsync(cmd, function(res)
    if onDone then
      onDone(res)
    end
  end)
end

-- One mpv transition at a time, in request order.
local function runNext()
  if queueBusy then
    return
  end
  local job = table.remove(queue, 1)
  if not job then
    return
  end
  queueBusy = true
  queueSince = os.time()
  local finished = false
  job(function()
    if finished then
      return
    end
    finished = true
    queueBusy = false
    runNext()
  end)
end

local function enqueue(job)
  table.insert(queue, job)
  runNext()
end

local function doPlay(podcast, episode, url)
  if not url or url == "" then
    noctalia.notifyError("Podcasts", "Episode has no audio URL")
    return
  end
  playGen = playGen + 1
  local gen = playGen
  local episodeName = episode or url

  status.podcast = podcast or ""
  status.episode = episodeName
  status.url = url
  status.pos = 0
  status.dur = 0
  status.paused = false
  status.playing = true
  pendingSeek = nil
  publish()

  local resumeAt = tonumber(positions[url]) or 0
  enqueue(function(done)
    -- A newer play/stop owns the player now: never launch over it.
    if gen ~= playGen then
      noctalia.log("[podcast] play superseded, dropping " .. episodeName)
      done()
      return
    end
    -- Stop the running episode first: two live instances lose the socket and
    -- the pidfile to each other and neither can be stopped afterwards (#1094).
    stopMpv(function()
      if gen ~= playGen then
        noctalia.log("[podcast] play superseded, dropping " .. episodeName)
        done()
        return
      end
      launchMpv(url, episodeName, resumeAt, function(res)
        local launched = res == nil or res.exitCode == 0
        noctalia.log("[podcast] play: launched=" .. tostring(launched) .. " episode=" .. tostring(episodeName))
        if launched then
          launchedAt = os.time()
          deadStreak = 0
          if resumeAt > 10 then
            status.pos = resumeAt
            noctalia.notify("Podcasts", "Resumed from " .. rss.clock(resumeAt))
          end
          publish()
        else
          noctalia.notifyError("Podcasts", "Could not launch mpv")
          status.playing = false
          publish()
        end
        done()
      end)
    end)
  end)
end

local function doStop()
  playGen = playGen + 1
  status.playing = false
  status.paused = false
  publish()
  enqueue(function(done)
    stopMpv(done)
  end)
end

local function doPause()
  if not status.playing or status.paused or status.url == "" then
    return
  end
  status.paused = true
  publish()
  if hasSocat then
    enqueue(function(done)
      noctalia.runAsync(mpvCmd('{"command":["set_property","pause",true]}'), function()
        done()
      end)
    end)
  end
end

local function doUnpause()
  if not status.playing or not status.paused or status.url == "" then
    return
  end
  status.paused = false
  publish()
  if hasSocat then
    enqueue(function(done)
      noctalia.runAsync(mpvCmd('{"command":["set_property","pause",false]}'), function()
        done()
      end)
    end)
  end
end

local function doToggle()
  if status.playing and not status.paused then
    doStop()
  elseif status.playing and status.paused then
    doUnpause()
  elseif status.url ~= "" then
    doPlay(status.podcast, status.episode, status.url)
  end
end

local function doVolume(v)
  v = math.clamp(math.floor(tonumber(v) or status.volume), 0, 100)
  status.volume = v
  publish()
  if not status.playing then
    return
  end
  if hasSocat then
    enqueue(function(done)
      noctalia.runAsync(mpvCmd('{"command":["set_property","volume",' .. tostring(v) .. "]}"), function()
        done()
      end)
    end)
  else
    -- No socat: relaunch once at the new volume, resuming where it was.
    -- Routed through the queue like any other restart.
    local url = status.url
    if url == "" then
      return
    end
    enqueue(function(done)
      if not status.playing or url ~= status.url then
        done()
        return
      end
      stopMpv(function()
        if not status.playing or url ~= status.url then
          done()
          return
        end
        launchMpv(url, status.episode, tonumber(status.pos) or 0, function()
          done()
        end)
      end)
    end)
  end
end

-- Poll mpv for position/duration/pause. Replies arrive in command order,
-- tagged by request_id (data precedes request_id in mpv's reply objects).
local function pollPos()
  local cmd = "(printf '%s\\n%s\\n%s\\n' '{\"command\":[\"get_property\",\"time-pos\"],\"request_id\":1}' '{\"command\":[\"get_property\",\"duration\"],\"request_id\":2}' '{\"command\":[\"get_property\",\"pause\"],\"request_id\":3}' | socat - "
    .. sq(SOCK) .. " 2>/dev/null)"
  noctalia.runAsync(cmd, function(res)
    if res.exitCode ~= 0 or not status.playing then
      return
    end
    local out = res.stdout or ""
    local p = string.match(out, '"data":([%d%.]+),"request_id":1')
    local d = string.match(out, '"data":([%d%.]+),"request_id":2')
    local pausedRaw = string.match(out, '"data":(%a+),"request_id":3')
    local changed = false
    if p then
      local np = tonumber(p)
      if np and math.abs(np - (tonumber(status.pos) or 0)) > 0.5 then
        status.pos = np
        changed = true
      end
      if np and np > 10 and status.url ~= "" then
        positions[status.url] = np
        savePositions()
      end
    end
    if d then
      local nd = tonumber(d)
      if nd and nd > 0 and nd ~= tonumber(status.dur) then
        status.dur = nd
        changed = true
      end
    end
    -- External pause/resume (MPRIS, media keys): adopt mpv's truth.
    if pausedRaw == "true" and not status.paused then
      status.paused = true
      changed = true
      noctalia.log("[podcast] paused externally")
    elseif pausedRaw == "false" and status.paused then
      status.paused = false
      changed = true
      noctalia.log("[podcast] resumed externally")
    end
    if changed then
      publish()
    end
    if pendingSeek and (tonumber(status.dur) or 0) > 0 then
      local v = pendingSeek
      pendingSeek = nil
      doSeek(v)
    end
  end)
end

local function doSeek(secs)
  if not status.playing or status.url == "" then
    return
  end
  local v = math.max(0, tonumber(secs) or 0)
  if tonumber(status.dur) and tonumber(status.dur) > 0 then
    v = math.min(v, tonumber(status.dur))
  end
  status.pos = v
  publish()
  if not hasSocat then
    return
  end
  if (tonumber(status.dur) or 0) > 0 then
    -- Loaded: seek now.
    pendingSeek = nil
    local target = math.floor(v)
    enqueue(function(done)
      noctalia.runAsync(mpvCmd('{"command":["set_property","time-pos",' .. tostring(target) .. "]}"), function()
        done()
      end)
    end)
  else
    -- Still starting: park it, the poll sends it once duration is known.
    pendingSeek = v
  end
end

local function handleRequest(req)
  if type(req) ~= "table" then
    return
  end
  local seq = tonumber(req.seq) or -1
  if seq <= lastSeq then
    return
  end
  lastSeq = seq
  noctalia.log("[podcast] request: action=" .. tostring(req.action) .. " seq=" .. tostring(seq))
  if req.action == "play" and req.url and req.url ~= "" then
    doPlay(req.podcast, req.episode, req.url)
  elseif req.action == "stop" then
    doStop()
  elseif req.action == "toggle" then
    doToggle()
  elseif req.action == "pause" then
    doPause()
  elseif req.action == "resume" then
    doUnpause()
  elseif req.action == "volume" then
    doVolume(req.volume)
  elseif req.action == "seek" then
    doSeek(req.pos)
  end
end

noctalia.state.watch("pod_request", handleRequest)
local initial = noctalia.state.get("pod_request")
if initial ~= nil then
  handleRequest(initial)
end

publish()
noctalia.setUpdateInterval(2000)

function update()
  -- Watchdog: a queued mpv transition must never wedge playback. If a shell
  -- callback is lost, drop the queue and let the next request through.
  if queueBusy and os.time() - queueSince > QUEUE_STUCK_SECS then
    noctalia.log("[podcast] queue stuck for " .. tostring(os.time() - queueSince) .. "s, resetting")
    queue, queueBusy = {}, false
  end
  -- Grace period for mpv startup, then two consecutive misses to confirm.
  if status.playing then
    if os.time() - launchedAt < 8 then
      return
    end
    pollCount = pollCount + 1
    if hasSocat and pollCount % 3 == 0 then
      pollPos()
    end
    aliveCheck(function(alive)
      if not status.playing then
        return
      end
      if alive then
        deadStreak = 0
        return
      end
      deadStreak = deadStreak + 1
      if deadStreak < 2 then
        return
      end
      deadStreak = 0
      local failedFast = os.time() - launchedAt < 30
      local name = status.episode
      -- Natural end (played to the finish) clears the saved position so a
      -- replay starts over; anything else keeps it for resume. Our own stop
      -- sets playing=false first, so it never reaches here.
      local dur = tonumber(status.dur) or 0
      local pos = tonumber(status.pos) or 0
      if dur > 0 and pos > dur - 30 then
        positions[status.url] = nil
        savePositions()
      end
      status.playing = false
      publish()
      if failedFast then
        noctalia.notifyError("Podcasts", "Audio failed (" .. name .. ") - try another episode")
        noctalia.log("[podcast] mpv died shortly after launch for " .. name)
      else
        noctalia.log("[podcast] mpv went away during playback of " .. name)
      end
    end)
  end
end

function onConfigChanged()
  volume = math.clamp(math.floor(tonumber(noctalia.getConfig("default_volume")) or volume), 0, 100)
  mpvBin = noctalia.getConfig("mpv_bin") or mpvBin
  hasSocat = noctalia.commandExists("socat")
  if not status.playing then
    status.volume = volume
    publish()
  end
end

function onIpc(event, payload)
  noctalia.log("[podcast] onIpc: event=" .. tostring(event))
  if event == "play" and payload and payload ~= "" then
    local ok, data = pcall(function()
      return noctalia.json.decode(payload)
    end)
    if ok and type(data) == "table" and data.url then
      handleRequest({ seq = lastSeq + 1, action = "play", podcast = data.podcast, episode = data.episode, url = data.url })
    else
      handleRequest({ seq = lastSeq + 1, action = "play", episode = payload, url = payload })
    end
  elseif event == "stop" then
    handleRequest({ seq = lastSeq + 1, action = "stop" })
  elseif event == "toggle" then
    handleRequest({ seq = lastSeq + 1, action = "toggle" })
  elseif event == "pause" then
    handleRequest({ seq = lastSeq + 1, action = "pause" })
  elseif event == "resume" then
    handleRequest({ seq = lastSeq + 1, action = "resume" })
  elseif event == "volume" then
    handleRequest({ seq = lastSeq + 1, action = "volume", volume = tonumber(payload) })
  elseif event == "volume-up" then
    handleRequest({ seq = lastSeq + 1, action = "volume", volume = math.clamp((tonumber(status.volume) or 70) + 10, 0, 100) })
  elseif event == "volume-down" then
    handleRequest({ seq = lastSeq + 1, action = "volume", volume = math.clamp((tonumber(status.volume) or 70) - 10, 0, 100) })
  elseif event == "seek" then
    handleRequest({ seq = lastSeq + 1, action = "seek", pos = tonumber(payload) })
  elseif event == "status" then
    publish()
  end
end

function onExit(_signal, _reason)
  stopMpv()
end
