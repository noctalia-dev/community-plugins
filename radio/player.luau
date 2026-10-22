--!nonstrict
-- [[service]] entry: owns the single headless mpv process.
-- Other entries never touch mpv directly. They publish a plain table to
-- noctalia.state "radio_request" and this service executes it, then publishes
-- the result to noctalia.state "radio_status".
--
--   request = { seq = n, action = "play" | "stop" | "volume",
--               uuid = "...", name = "...", url = "...", volume = 0-100 }
--   status  = { playing = bool, name = "...", url = "...", volume = 0-100 }
--
-- mpv runs headless: mpv --no-video --input-ipc-server=<sock> <url>
-- Volume/stop go through the IPC socket via socat when available,
-- otherwise we fall back to SIGTERM on the recorded PID / relaunch.
--
-- Every mpv transition runs through one ordered queue (enqueue below): a new
-- stream starts only after the previous mpv has really exited. Two live
-- instances share a single socket path and a single pidfile, so the loser
-- becomes unreachable and can only be killed from a terminal (issue #1094).

local dataDir = noctalia.pluginDataDir()
local SOCK = dataDir .. "/mpv.sock"
local PIDFILE = dataDir .. "/mpv.pid"
local API_MIRRORS = { "https://de1.api.radio-browser.info", "https://de2.api.radio-browser.info" }
local UA = "noctalia-radio/0.1.1"
local QUEUE_STUCK_SECS = 15

local volume = tonumber(noctalia.getConfig("default_volume")) or 70
local mpvBin = noctalia.getConfig("mpv_bin") or "mpv"
local hasSocat = noctalia.commandExists("socat")

local status = { playing = false, name = "", url = "", uuid = "", volume = volume }
local lastSeq = -1
local launchedAt = 0
local deadStreak = 0
-- Bumped by every play and stop. Async continuations (stream URL resolution,
-- queued mpv transitions) compare it and drop themselves when a newer request
-- has taken over the player.
local playGen = 0
local queue, queueBusy, queueSince = {}, false, 0

noctalia.log("[radio] player loaded: datadir=" .. tostring(dataDir) .. " mpv=" .. tostring(mpvBin) .. " socat=" .. tostring(hasSocat))

local function publish()
  noctalia.state.set("radio_status", {
    playing = status.playing,
    name = status.name,
    url = status.url,
    uuid = status.uuid,
    volume = status.volume,
  })
end

-- Single-quote escaping for /bin/sh -c strings.
local function sq(s)
  return "'" .. string.gsub(s or "", "'", "'\\''") .. "'"
end

local function aliveCheck(onResult)
  -- Pure PID bookkeeping: no pkill/pgrep anywhere. Pattern-matching our own
  -- socket path would match the checker's own command line (suicide for
  -- pkill, always-true for pgrep), so liveness is kill -0 on the recorded
  -- PID plus a read-only /proc cmdline confirmation.
  local cmd = "test -S " .. sq(SOCK) .. " && test -f " .. sq(PIDFILE)
    .. " && p=$(tail -n 1 " .. sq(PIDFILE) .. ") && case \"$p\" in *[!0-9]*) exit 1 ;; esac && kill -0 \"$p\" 2>/dev/null"
    .. " && grep -qa mpv /proc/\"$p\"/cmdline 2>/dev/null"
  noctalia.runAsync(cmd, function(res)
    onResult(res.exitCode == 0)
  end)
end

local function mpvCmd(payload)
  -- Deliver one JSON IPC command file to the socket. The payload file is
  -- written host-side (no shell quoting involved) and always newline
  -- terminated, since mpv ignores unterminated commands on disconnect.
  -- Returns a shell fragment; the caller runs it via runAsync.
  noctalia.writeFile(dataDir .. "/mpvcmd.json", payload .. "\n")
  return "(socat - " .. sq(SOCK) .. " < " .. sq(dataDir .. "/mpvcmd.json") .. " >/dev/null 2>&1 || true)"
end

-- Kill loop over every PID recorded in PIDFILE that is still an mpv we started.
-- The evidence is read-only: /proc/<pid>/cmdline must mention mpv *and* the
-- plugin data dir, which appears in our own --input-ipc-server argument, so a
-- stale or recycled PID can never take out an unrelated process. No
-- pkill/pgrep anywhere: a pattern match would also hit the checker's own
-- command line (see aliveCheck).
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
  -- Quit over IPC first (clean mpv shutdown, no "stream interrupted" noise),
  -- then make sure no instance survived: recorded PIDs from the pidfile, plus a
  -- sweep for strays it does not know about (a launch that outlived its stop,
  -- or an orphan left by an older build - the state reporters of #1094 are in,
  -- where no file points at the still-playing stream any more).
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

local function launchMpv(url, name, onDone)
  -- Only reached with no live instance (enqueue -> stopMpv guarantees it). The
  -- PID is appended, never truncated: if a launch ever outlived its stop, the
  -- next stop still knows about it and can kill it.
  local cmd = "rm -f " .. sq(SOCK) .. "; "
    .. "nohup " .. sq(mpvBin) .. " --no-video --input-ipc-server=" .. sq(SOCK)
    .. " --volume=" .. tostring(status.volume)
    .. " --title=" .. sq("radio: " .. name)
    -- "--" ends option parsing: a hostile stream URL cannot be read as mpv flags.
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

local function doPlay(name, url, uuid)
  if not url or url == "" then
    noctalia.notifyError("Radio", "Station has no stream URL")
    return
  end
  playGen = playGen + 1
  local gen = playGen
  local playName = (name and name ~= "") and name or url

  status.name = playName
  status.uuid = uuid or ""
  status.playing = true
  publish()

  -- A newer play/stop owns the player now: drop this one before it touches mpv.
  local dropped = false
  local function superseded()
    if gen == playGen then
      return false
    end
    if not dropped then
      dropped = true
      noctalia.log("[radio] play superseded, dropping " .. playName)
    end
    return true
  end

  local function start(finalUrl)
    if superseded() then
      return
    end
    enqueue(function(done)
      if superseded() then
        done()
        return
      end
      -- Stop the running station first: this is the actual fix for #1094.
      stopMpv(function()
        if superseded() then
          done()
          return
        end
        status.url = finalUrl
        launchMpv(finalUrl, playName, function(res)
          local launched = res == nil or res.exitCode == 0
          noctalia.log("[radio] play: launched=" .. tostring(launched) .. " name=" .. playName)
          if launched then
            launchedAt = os.time()
            deadStreak = 0
            publish()
          else
            noctalia.notifyError("Radio", "Could not launch mpv")
            status.playing = false
            publish()
          end
          done()
        end)
      end)
    end)
  end

  if uuid and uuid ~= "" then
    -- Resolve the authoritative stream URL (also counts the click for the API).
    -- Walk mirrors: de1 is sometimes down, de2 usually answers.
    local function resolve(attempt)
      local base = API_MIRRORS[attempt]
      if not base then
        noctalia.log("[radio] click-resolve failed, falling back to search URL")
        start(url)
        return
      end
      noctalia.http({
        url = base .. "/json/url/" .. uuid,
        headers = { "User-Agent: " .. UA },
      }, function(res)
        if superseded() then
          return
        end
        if res.ok then
          local data = noctalia.json.decode(res.body)
          if type(data) == "table" and data.url and data.url ~= "" then
            start(data.url)
            return
          end
        end
        resolve(attempt + 1)
      end)
    end
    resolve(1)
  else
    start(url)
  end
end

local function doStop()
  playGen = playGen + 1
  status.playing = false
  publish()
  enqueue(function(done)
    stopMpv(done)
  end)
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
    -- No socat: relaunch once at the new volume so mpv still follows the
    -- slider. Routed through the queue like any other restart.
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
        launchMpv(url, status.name, function()
          done()
        end)
      end)
    end)
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
  noctalia.log("[radio] request: action=" .. tostring(req.action) .. " seq=" .. tostring(seq))
  if req.action == "play" and req.url and req.url ~= "" then
    doPlay(req.name or req.url, req.url, req.uuid)
  elseif req.action == "stop" then
    doStop()
  elseif req.action == "volume" then
    doVolume(req.volume)
  end
end

noctalia.state.watch("radio_request", handleRequest)
local initial = noctalia.state.get("radio_request")
if initial ~= nil then
  handleRequest(initial)
end

-- Restore persisted volume, load favorites into shared state for widget/panel.
local favRaw = noctalia.readFile(dataDir .. "/favorites.json")
if favRaw then
  local favs = noctalia.json.decode(favRaw)
  if type(favs) == "table" then
    noctalia.state.set("radio_favorites", favs)
  end
end

publish()
noctalia.setUpdateInterval(2000)

function update()
  -- Watchdog: a queued mpv transition must never wedge playback. If a shell
  -- callback is lost, drop the queue and let the next request through.
  if queueBusy and os.time() - queueSince > QUEUE_STUCK_SECS then
    noctalia.log("[radio] queue stuck for " .. tostring(os.time() - queueSince) .. "s, resetting")
    queue, queueBusy = {}, false
  end
  -- Correct a stale "playing" flag when mpv died externally. Grace period:
  -- mpv needs a few seconds to connect and create its socket, and a single
  -- missed observation is not death (poll races, slow DNS). Two consecutive
  -- misses past the grace window means the stream is really gone.
  if status.playing then
    if os.time() - launchedAt < 8 then
      return
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
      local name = status.name
      status.playing = false
      publish()
      if failedFast then
        noctalia.notifyError("Radio", "Stream failed (" .. name .. ") - try another station")
        noctalia.log("[radio] mpv died shortly after launch for " .. name .. " - see mpv.log in plugin data dir")
      else
        noctalia.log("[radio] mpv went away during playback of " .. name)
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
  noctalia.log("[radio] onIpc: event=" .. tostring(event))
  if event == "play" and payload and payload ~= "" then
    local ok, data = pcall(function()
      return noctalia.json.decode(payload)
    end)
    if ok and type(data) == "table" and data.url then
      handleRequest({ seq = lastSeq + 1, action = "play", uuid = data.uuid, name = data.name, url = data.url })
    else
      handleRequest({ seq = lastSeq + 1, action = "play", name = payload, url = payload })
    end
  elseif event == "stop" then
    handleRequest({ seq = lastSeq + 1, action = "stop" })
  elseif event == "toggle" then
    if status.playing then
      handleRequest({ seq = lastSeq + 1, action = "stop" })
    elseif status.url ~= "" then
      handleRequest({ seq = lastSeq + 1, action = "play", uuid = status.uuid, name = status.name, url = status.url })
    end
  elseif event == "volume" then
    handleRequest({ seq = lastSeq + 1, action = "volume", volume = tonumber(payload) })
  elseif event == "volume-up" then
    handleRequest({ seq = lastSeq + 1, action = "volume", volume = math.clamp((tonumber(status.volume) or 70) + 10, 0, 100) })
  elseif event == "volume-down" then
    handleRequest({ seq = lastSeq + 1, action = "volume", volume = math.clamp((tonumber(status.volume) or 70) - 10, 0, 100) })
  elseif event == "status" then
    publish()
  end
end

function onExit(_signal, _reason)
  -- Detached: outlives this runtime, which is exactly what cleanup needs.
  stopMpv()
end
