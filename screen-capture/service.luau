--!nonstrict
-- Screen Capture — headless service.
--
-- Owns the recording. The bar widget and control-center tile are thin clients:
-- they open the "menu" panel so the user picks source/audio/webcam, then publish
-- a command here. This service runs the picker itself, because the panel has to
-- be closed before slurp freezes the screen, and turns the choice into a
-- scripts/record.sh run.
--
-- Everything goes through the panel; a right click replays the last choice
-- ("record-last") without opening it.

local state = "idle" -- idle | selecting | starting | stopping | recording
local outputPath = ""
local available = false
local recorder = nil
local lastChoice = nil

local scriptPath
local dataDir = nil
local generation = 0
local jobs = {}
local jobCounter = 0

local SOURCES = { region = true, window = true, fullscreen = true }
local AUDIOS = { none = true, default_output = true, default_input = true, both = true }

local function cfg(key) return noctalia.getConfig(key) end
local function log(msg) noctalia.log(`screen-capture: {msg}`) end
local function recordScript() return scriptPath end
local function sibling(name) return scriptPath:gsub("record%.sh$", name) end

-- ── state ──────────────────────────────────────────────────────────────────────

local function publish()
  noctalia.state.set("status", {
    state = state,
    available = available,
    outputPath = outputPath,
    choice = lastChoice,
  })
end

-- Poll faster while a picker or a stop is in flight, so the UI reacts within
-- ~250ms; poll the recorder state only twice a second otherwise.
local function setState(next)
  if state == next then
    return
  end
  state = next
  if state == "recording" or state == "idle" then
    noctalia.setUpdateInterval(2000)
  else
    noctalia.setUpdateInterval(250)
  end
  publish()
end

-- ── notifications ──────────────────────────────────────────────────────────────

local function parseResult(result)
  for line in (result.stdout or ""):gmatch("[^\r\n]+") do
    if line:match("^file=") then
      return line:sub(6)
    end
  end
  return nil
end

local function fileUri(path)
  local encoded = path:gsub("([^%w%-%._~/])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return "file://" .. encoded
end

-- Resolved lazily and cached: the data directory holds detached-job results.
local function ensureDataDir()
  if dataDir then
    return dataDir
  end
  local dir = noctalia.pluginDataDir()
  if dir and dir ~= "" then
    noctalia.mkdirAll(dir)
    dataDir = dir
  end
  return dataDir
end

local function cancelPicker()
  -- The picker script owns its runtime directory and PID files. Delegating
  -- cancellation to it keeps both sides on the same path and lets it stop only
  -- the slurp and the freeze it started. The scripts keep that state under
  -- $XDG_RUNTIME_DIR/screen-capture, not in pluginDataDir(), and killing the
  -- picker's shell is not enough: slurp and hyprpicker are its children.
  if not scriptPath then
    return
  end
  if not noctalia.runAsync({ sibling("pick-region.sh"), "--cancel" }) then
    log("could not launch picker cancellation")
  end
end

local function notifySaved(file)
  if not file or file == "" then
    return
  end
  -- noctalia.notify takes only a title and a body: no preview image and no
  -- action button, so the body points at the path instead of promising one.
  noctalia.notify(
    noctalia.tr("notify.saved"),
    noctalia.tr("notify.saved_hint") .. "\n" .. file
  )
  if cfg("copy_to_clipboard") == true then
    noctalia.copyToClipboard(fileUri(file), "text/uri-list")
  end
end

-- ── detached jobs ──────────────────────────────────────────────────────────────

-- runAsync clamps every timeout to 60s. That is too short for a picker the user
-- may take minutes to finish, and for finalizing a long recording, so those run
-- through scripts/run-detached.sh with no callback and the service polls for a
-- result file. The helper writes .out and .err and, last, .code: seeing .code
-- means the other two are complete.

local function startJob(argv, onDone)
  local dir = ensureDataDir()
  if not dir then
    return false
  end
  jobCounter = jobCounter + 1
  local prefix = string.format("%s/job-%d-%d", dir, noctalia.nowMs(), jobCounter)
  local full = { sibling("run-detached.sh"), prefix, "--" }
  for _, arg in ipairs(argv) do
    table.insert(full, arg)
  end
  if not noctalia.runAsync(full) then
    return false
  end
  jobs[prefix] = { onDone = onDone }
  return true
end

local function pollJobs()
  local ready = {}
  for prefix, job in pairs(jobs) do
    if noctalia.fileExists(prefix .. ".code") then
      ready[#ready + 1] = { prefix, job }
    end
  end
  for _, entry in ipairs(ready) do
    local prefix, job = entry[1], entry[2]
    jobs[prefix] = nil
    local code = tonumber(noctalia.readFile(prefix .. ".code") or "") or -1
    local out = noctalia.readFile(prefix .. ".out") or ""
    local err = noctalia.readFile(prefix .. ".err") or ""
    noctalia.removeFile(prefix .. ".code")
    noctalia.removeFile(prefix .. ".out")
    noctalia.removeFile(prefix .. ".err")
    job.onDone({ exitCode = code, stdout = out, stderr = err, timedOut = false })
  end
end

-- ── choices ────────────────────────────────────────────────────────────────────

-- Seed a run from the panel's choice, falling back to the plugin settings.
local function normalize(choice)
  choice = choice or {}
  local source = SOURCES[choice.source] and choice.source or nil
  local audio = AUDIOS[choice.audio] and choice.audio or nil
  return {
    source = source or (lastChoice and lastChoice.source) or "region",
    audio = audio or (lastChoice and lastChoice.audio) or cfg("audio_source") or "both",
    webcam = choice.webcam == true,
  }
end

local function currentChoice()
  return lastChoice or normalize(nil)
end

local function baseArgs(chosen)
  local dir = noctalia.expandPath(cfg("directory") or "~/Videos/Recordings")
  if dir:sub(-1) ~= "/" then
    dir ..= "/"
  end
  noctalia.mkdirAll(dir)

  local webcam = "off"
  if chosen.webcam then
    webcam = cfg("webcam_size") or "medium"
  end

  return {
    string.format("--directory=%s", dir),
    string.format("--filename-pattern=%s", cfg("filename_pattern") or "capture_%Y-%m-%d_%H-%M-%S"),
    string.format("--audio=%s", chosen.audio),
    string.format("--frame-rate=%s", tostring(cfg("frame_rate") or 60)),
    string.format("--framerate-mode=%s", cfg("framerate_mode") or "cfr"),
    string.format("--quality=%s", cfg("quality") or "high"),
    string.format("--cursor=%s", cfg("show_cursor") == false and "no" or "yes"),
    string.format("--normalize=%s", cfg("normalize_audio") == false and "no" or "yes"),
    string.format("--webcam=%s", webcam),
  }
end

-- ── target resolution ──────────────────────────────────────────────────────────

-- pick-region.sh prints "X,Y WxH" for a rectangle and record.sh wants
-- "region:WxH+X+Y"; a whole-monitor selection already arrives as "monitor:NAME".
local function selectionToTarget(selection)
  if not selection or selection == "" then
    return nil
  end
  if selection:match("^monitor:") then
    return selection
  end
  local x, y, w, h = selection:match("^(-?%d+),(-?%d+)%s+(%d+)x(%d+)$")
  if not x then
    return nil
  end
  return string.format("region:%sx%s+%s+%s", w, h, x, y)
end

local function resolveTarget(chosen, gen, onDone)
  if chosen.source == "fullscreen" then
    -- Ask the compositor through pick-region.sh rather than
    -- noctalia.focusedOutputName(): the latter can report nothing while the menu
    -- panel is still closing, which is how "no focused monitor" happened.
    noctalia.runAsync({ "sleep", "0.25" }, function()
      if gen ~= generation or state ~= "selecting" then
        return
      end
      if not startJob({ sibling("pick-region.sh"), "fullscreen", "--match-monitor" }, function(result)
        if gen ~= generation then
          return
        end
        local target = selectionToTarget((result.stdout or ""):match("[^\r\n]+"))
        if target then
          onDone(target)
          return
        end
        -- Last resort if the picker could not resolve a monitor.
        local monitor = noctalia.focusedOutputName()
        if monitor and monitor ~= "" then
          onDone(string.format("monitor:%s", monitor))
        else
          noctalia.notifyError(noctalia.tr("notify.failed"), noctalia.tr("notify.no_monitor"))
          onDone(nil)
        end
      end) then
        noctalia.notifyError(noctalia.tr("notify.failed"), noctalia.tr("notify.launch_failed"))
        onDone(nil)
      end
    end)
    return
  end

  -- "window" feeds slurp the window rectangles and snaps a click to one;
  -- "region" is freeform. Both upgrade a full-monitor selection to a native
  -- monitor capture.
  local mode = chosen.source == "window" and "windows" or "region"

  -- Let the panel finish closing before the picker freezes the screen, or the
  -- panel shape ends up in the frozen frame. This short command fits inside
  -- runAsync's clamp; the picker itself runs detached.
  noctalia.runAsync({ "sleep", "0.25" }, function()
    if gen ~= generation or state ~= "selecting" then
      return
    end
    if not startJob({ sibling("pick-region.sh"), mode, "--match-monitor" }, function(result)
      if gen ~= generation then
        return
      end
      onDone(selectionToTarget((result.stdout or ""):match("[^\r\n]+")))
    end) then
      noctalia.notifyError(noctalia.tr("notify.failed"), noctalia.tr("notify.launch_failed"))
      onDone(nil)
    end
  end)
end

-- ── recording ──────────────────────────────────────────────────────────────────

local function launch(chosen, target, gen)
  local argv = { recordScript(), "start" }
  for _, arg in ipairs(baseArgs(chosen)) do
    table.insert(argv, arg)
  end

  local device = cfg("webcam_device")
  if chosen.webcam and device and device ~= "" then
    table.insert(argv, string.format("--webcam-device=%s", device))
  end
  table.insert(argv, string.format("--target=%s", target))

  log(`starting: {table.concat(argv, " ")}`)

  local started = startJob(argv, function(result)
    if gen ~= generation then
      return
    end
    local file = parseResult(result)
    if result.exitCode == 0 then
      outputPath = file or ""
      setState("recording")
    else
      outputPath = ""
      setState("idle")
      noctalia.notifyError(noctalia.tr("notify.failed"), noctalia.tr("notify.failed_hint"))
    end
  end)

  if not started and gen == generation then
    setState("idle")
    noctalia.notifyError(noctalia.tr("notify.failed"), noctalia.tr("notify.launch_failed"))
  end
end

local function start(choice)
  if state ~= "idle" then
    return
  end

  local chosen = normalize(choice)
  lastChoice = chosen
  -- A generation tags this run. A late callback from a cancelled run carries an
  -- older tag and is ignored, even if a new run is already selecting.
  generation = generation + 1
  local gen = generation
  setState("selecting")

  resolveTarget(chosen, gen, function(target)
    if gen ~= generation or state ~= "selecting" then
      return
    end
    if not target then
      -- Cancelled picker: no error, just back to idle.
      setState("idle")
      return
    end
    setState("starting")
    launch(chosen, target, gen)
  end)
end

local function stop()
  if state == "idle" or state == "stopping" then
    return
  end

  -- While selecting, the picker is ours rather than record.sh's, so record.sh
  -- cannot cancel it. Hand cancellation to pick-region.sh, which stops the
  -- slurp and freeze it owns. Bumping the generation drops the in-flight picker.
  if state == "selecting" then
    cancelPicker()
    generation = generation + 1
    setState("idle")
    return
  end

  generation = generation + 1
  local gen = generation
  setState("stopping")
  log("stopping recording")

  local function onStopped(result)
    if gen ~= generation then
      return
    end
    setState("idle")
    notifySaved(parseResult(result))
    outputPath = ""
  end

  -- Finalizing a long recording can outlast runAsync's 60s clamp, so stop runs
  -- detached too. Fall back to a bounded run only if the helper cannot launch.
  if not startJob({ recordScript(), "stop" }, onStopped) then
    noctalia.runAsync({ recordScript(), "stop" }, onStopped, 60000)
  end
end

-- ── commands ───────────────────────────────────────────────────────────────────

-- record.sh is serialized on its own lock, so a start that lands while one is
-- running means "stop what is running".
local function handleCommand(payload)
  local action = type(payload) == "table" and payload.action or payload
  if type(action) ~= "string" then
    return
  end

  if action == "start" then
    if type(payload) == "table" then
      start({ source = payload.source, audio = payload.audio, webcam = payload.webcam })
    else
      start(currentChoice())
    end
  elseif action == "record-last" or action == "toggle" then
    if state == "idle" then
      start(currentChoice())
    else
      stop()
    end
  elseif action == "record-fullscreen" then
    if state ~= "idle" then
      stop()
    else
      local base = currentChoice()
      start({ source = "fullscreen", audio = base.audio, webcam = base.webcam })
    end
  elseif action == "stop" then
    stop()
  elseif action == "resize-webcam" then
    local size = type(payload) == "table" and payload.size or nil
    if size then
      noctalia.runAsync({ sibling("webcam-resize.sh"), size })
    end
  end
end

-- External IPC (`noctalia msg plugin ...:service all <action> [arg]`).
function onIpc(event, payload)
  if type(payload) == "table" then
    handleCommand(payload)
  elseif type(payload) == "string" and payload ~= "" and event == "start" then
    -- `start region` overrides the source for that run.
    handleCommand({ action = "start", source = payload })
  else
    handleCommand(event)
  end
end

-- ── lifecycle ──────────────────────────────────────────────────────────────────

-- Poll the recorder state rarely; setState() raises the rate while a picker, a
-- start or a stop is in flight. A recording that ended from a terminal, or a
-- recorder that died on its own, would otherwise leave the widget showing
-- "recording" forever.
noctalia.setUpdateInterval(2000)

function update()
  pollJobs()

  if recorder ~= nil then
    return
  end
  if state ~= "recording" and state ~= "starting" then
    return
  end

  local queriedState = state
  local queriedGen = generation
  local started = noctalia.runAsync({ recordScript(), "status" }, function(result)
    recorder = nil
    if queriedGen ~= generation or state ~= queriedState then
      return
    end
    local reported = (result.stdout or ""):match("state=([%w_]+)")
    if reported == "recording" or reported == "starting" then
      return
    end
    if state == "recording" then
      -- The recorder died on its own. Go through stop so the webcam overlay and
      -- the runtime files are cleaned up and the partial file finalized, instead
      -- of leaving mpv alive to appear in the next recording.
      log("recorder is gone; finalizing")
      stop()
    end
  end)
  -- runAsync returns false when the command could not launch; a `false` here
  -- would satisfy `recorder ~= nil` forever and stop the polling entirely.
  recorder = started and true or nil
end

function onConfigChanged()
  publish()
end

function onExit()
  -- A reload or disable must not leave a picker, a recorder, or a webcam overlay
  -- running with nothing left to stop it.
  generation = generation + 1
  if state == "selecting" then
    cancelPicker()
  end
  if state == "recording" or state == "starting" then
    -- Detached, so finalizing is not cut off by runAsync's 60s clamp.
    if not startJob({ recordScript(), "stop" }, function() end) then
      noctalia.runAsync({ recordScript(), "stop" }, nil, 60000)
    end
  end
end

function onEnable()
  local dir = noctalia.pluginDir()
  scriptPath = dir and (dir .. "/scripts/record.sh") or nil
  dataDir = noctalia.pluginDataDir()
  if dataDir then
    noctalia.mkdirAll(dataDir)
  end
  available = scriptPath ~= nil
    and noctalia.commandExists("gpu-screen-recorder")
    and noctalia.commandExists("slurp")
  if not available then
    log("unavailable: record.sh or a required command is missing")
  end
  publish()
end

onEnable()

-- The widget and shortcut drive the recorder through this channel.
noctalia.state.watch("command", handleCommand)
