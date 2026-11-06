--!nonstrict
-- Background service: owns the localsend-controller daemon and mirrors its
-- snapshot to the widget and panel through noctalia.state ("ls").

local lib = require("./lib.luau")
local extras = require("./extras.luau")

math.randomseed(noctalia.nowMs())

-- update() runs once a second; these count its ticks.
local STOP_GRACE_TICKS = 3 -- a daemon acknowledged the shutdown
local STOP_TIMEOUT_TICKS = 6 -- nothing answered the shutdown
local START_TIMEOUT_TICKS = 15
-- Panel closed and nothing in progress. The daemon reports new requests and
-- transfers with a "changed" line, so this poll is only a safety net.
local IDLE_POLL_TICKS = 30
local MAX_POLL_FAILURES = 3
-- Seconds before retrying a failed start, doubled after every failure.
local FIRST_BACKOFF = 5
local MAX_BACKOFF = 60

local DEFAULT_PORT = 53317

-- phase: "stopping" -> "starting" -> "running"; "failed" retries with backoff
local phase = "stopping"
local ticks = 0
local gen = 0 -- generation of the daemon stream we own
local stopAcked = false -- a daemon answered our shutdown request
local polling = false
local pollAgain = false -- a change arrived while a poll was running
local failures = 0
local backoff = FIRST_BACKOFF
local lastBusy = false
local startError = nil
local failureNotified = false -- one error notification per run of failed starts

local seenTransfers = {} -- transfer id -> last state seen
local seenIncoming = nil -- id of the pending request we notified about
local primed = false -- the first snapshot only records state
local dataPrivate = false -- the data directory is known to be 0700
local quietBy = {} -- sender fingerprint -> os.time() before which its requests do not alert

-- A request its sender withdrew before we answered silences that sender's
-- alerts for a while, so a peer that keeps offering and withdrawing cannot
-- flood notifications or keep popping the panel open. Other senders still
-- alert. (The controller also declines its requests for a minute.)
local ABORT_QUIET_SECONDS = 30

-- Requests from devices that are not favorites alert at most this many times
-- a minute, however many certificates and addresses a sender goes through.
-- They still wait in the panel.
local STRANGER_ALERTS_PER_MINUTE = 3
local strangerAlerts = {} -- os.time() of the recent alerts

local function strangerMayAlert()
  local now = os.time()
  local recent = {}
  for _, at in ipairs(strangerAlerts) do
    if now - at < 60 then table.insert(recent, at) end
  end
  strangerAlerts = recent
  if #recent >= STRANGER_ALERTS_PER_MINUTE then return false end
  table.insert(recent, now)
  return true
end

local function tr(key, args)
  return noctalia.tr(key, args)
end

-- A setting the panel or launcher can also change. Plugins cannot write
-- their own settings, so the choice survives restarts in <name>.json with
-- the settings value it replaced: a later settings change wins over an
-- older panel choice, never the other way round.
local function panelChoice(name, key, valid, default)
  local file = lib.dataFile(name .. ".json")
  local choice = {}

  local function configured()
    local mode = noctalia.getConfig(key)
    return valid[mode] and mode or default
  end

  function choice.set(mode)
    choice.mode = mode
    if file == nil then return end
    local ok, err = lib.writeJson(file, { mode = mode, setting = choice.setting })
    if not ok then noctalia.log("localsend: could not save " .. name .. ": " .. tostring(err)) end
    lib.restrictFile(file)
  end

  -- Takes over a changed settings value; true when it did.
  function choice.sync()
    local setting = configured()
    if setting == choice.setting then return false end
    choice.setting = setting
    choice.set(setting)
    return true
  end

  choice.setting = configured()
  local raw = file and noctalia.readFile(file)
  local data = raw and noctalia.json.decode(raw)
  if type(data) == "table" and data.setting == choice.setting and valid[data.mode] then
    choice.mode = data.mode
    lib.restrictFile(file)
  else
    choice.set(choice.setting)
  end
  return choice
end

-- Visibility; "everyone for 10 min" is temporary on top of the chosen mode.
local visibility = panelChoice("visibility", "visibility", lib.VISIBILITY, "everyone")
local tempUntil = 0 -- os.time() at which a temporary "everyone" ends; 0 = none
local visSeq = 0 -- counts visibility changes, so the panel can show each one once

-- Auto-accept of files: favorites by default, since pinning a device means
-- trusting it. The PIN card switches to everyone ("accept when the PIN is
-- right"), which the controller allows only with a PIN of 8 characters or
-- more.
local AUTO_ACCEPT = { off = true, favorites = true, everyone = true }
local autoAccept = panelChoice("auto_accept", "auto_accept", AUTO_ACCEPT, "favorites")

local function effectiveMode()
  return tempUntil > 0 and "everyone" or visibility.mode
end

local function visState()
  return { mode = effectiveMode(), base = visibility.mode, tempUntil = tempUntil, seq = visSeq }
end

-- Set while localsend-controller is missing or too old: the command that
-- builds it from the sources shipped with this plugin.
local installCommand = nil

-- Publishes the state while no daemon answers. A running daemon's
-- snapshot stays in place; only the plugin's own fields change on it.
local function publish()
  local ls = noctalia.state.get("ls")
  if phase == "running" and type(ls) == "table" and ls.up then
    ls.vis = visState()
    ls.autoAcceptChoice = autoAccept.mode
    noctalia.state.set("ls", ls)
    return
  end
  noctalia.state.set("ls", {
    up = false,
    phase = phase,
    startError = startError,
    install = installCommand,
    vis = visState(),
    autoAcceptChoice = autoAccept.mode,
  })
end

local function fail(message)
  phase = "failed"
  ticks = 0
  startError = message
  lib.removeSecret("pin") -- in case the controller never read it
  publish()
end

-- Retries repeat the same error; the widget tooltip and panel keep it, so
-- one notification covers the whole run of failed starts.
local function failAndNotify(message)
  fail(message)
  if not failureNotified then
    failureNotified = true
    noctalia.notifyError(tr("notify.title"), startError)
  end
end

-- Finding the controller. A graphical session's PATH often lacks
-- ~/.cargo/bin, where `cargo install` puts it, so that is tried too.
local CONTROLLER_SOURCES = lib.PLUGIN_DIR .. "/controller"

-- The version of the bundled sources: an installed controller must be at
-- least that new, so a plugin update that changes it asks for a rebuild.
local function requiredVersion()
  local raw = noctalia.readFile(CONTROLLER_SOURCES .. "/Cargo.toml") or ""
  return lib.versionParts(raw:match('\nversion%s*=%s*"([%d%.]+)"'))
end

-- The controller controller/update.sh last built, for a CARGO_HOME or
-- CARGO_INSTALL_ROOT that only the user's shell knows about.
local BUILT_FILE = lib.dataFile("controller-built")

-- Existing controllers to try, in order of preference. The setting, when
-- given, is the only one.
local function candidates(onPath)
  local list, seen = {}, {}
  local function add(path)
    path = lib.trim(path or "")
    if path:sub(1, 1) == "/" and not seen[path] and noctalia.fileExists(path) then
      seen[path] = true
      table.insert(list, path)
    end
  end
  local configured = lib.trim(noctalia.getConfig("controller_path") or "")
  if configured ~= "" then
    add(noctalia.expandPath(configured))
    return list
  end
  add(BUILT_FILE and noctalia.readFile(BUILT_FILE))
  add(onPath)
  for _, name in ipairs({ "CARGO_INSTALL_ROOT", "CARGO_HOME" }) do
    local root = noctalia.getenv(name)
    if root ~= nil and root ~= "" then add(root .. "/bin/localsend-controller") end
  end
  add(noctalia.expandPath("~/.cargo/bin/localsend-controller"))
  add(noctalia.expandPath("~/.local/bin/localsend-controller"))
  return list
end

local function controllerMissing(message)
  noctalia.state.set("controller", nil)
  installCommand = lib.updateCommand(false)
  failAndNotify(message)
end

-- Passes onChecked the version a controller reports, or nil when it is not one.
local function checkVersion(path, onChecked)
  noctalia.runAsync({ path, "--version" }, function(res)
    local data = noctalia.json.decode(lib.trim(res.stdout or ""))
    onChecked(lib.versionParts(type(data) == "table" and data.result and data.result.help))
  end)
end

-- Finds a usable controller, publishes it as state "controller" and calls
-- onFound; otherwise fails with the update command.
local function locateController(onFound)
  noctalia.runAsync("command -v localsend-controller", function(res)
    local paths = candidates(res.stdout)
    if #paths == 0 then
      controllerMissing(tr("error.no_controller"))
      return
    end
    local found = {}
    local function checkNext(i)
      if i <= #paths then
        checkVersion(paths[i], function(version)
          table.insert(found, { path = paths[i], version = version })
          checkNext(i + 1)
        end)
        return
      end
      local needed = requiredVersion()
      local usable, newest = lib.pickController(found, needed)
      if usable ~= nil then
        installCommand = nil
        noctalia.state.set("controller", { path = usable.path, version = table.concat(usable.version, ".") })
        onFound()
      elseif newest ~= nil then
        controllerMissing(tr("error.old_controller", {
          found = table.concat(newest.version, "."),
          needed = table.concat(needed, "."),
        }))
      else
        controllerMissing(tr("error.bad_controller", { path = paths[1] }))
      end
    end
    checkNext(1)
  end)
end

local PIN_FILE = lib.dataFile("pin")

local function storedPin()
  local pin = PIN_FILE and noctalia.readFile(PIN_FILE)
  if pin == nil or pin == "" then return nil end
  return pin
end

local function daemonCommand()
  local dest = noctalia.expandPath(noctalia.getConfig("save_dir") or "~/Downloads/LocalSend")
  local parts = {
    "exec",
    lib.shq(lib.bin()),
    "--socket",
    lib.shq(lib.SOCK),
    "daemon",
    "--port",
    tostring(math.floor(tonumber(noctalia.getConfig("port")) or DEFAULT_PORT)),
    "--destination",
    lib.shq(dest),
    "--state-directory",
    lib.shq(lib.dataFile("controller")),
    "--auto-accept",
    autoAccept.mode,
  }
  local alias = lib.trim(noctalia.getConfig("alias") or "")
  if alias ~= "" then
    table.insert(parts, "--alias")
    table.insert(parts, lib.shq(alias))
  end
  local model = lib.trim(noctalia.getConfig("device_model") or "")
  if model ~= "" then
    table.insert(parts, "--device-model")
    table.insert(parts, lib.shq(model))
  end
  local pin = storedPin()
  local pinPath = pin and lib.writeSecret("pin", pin)
  if pinPath ~= nil then
    table.insert(parts, "--pin-file")
    table.insert(parts, lib.shq(pinPath))
  end
  -- The favorites follow in the first set-visibility, which keeps their
  -- addresses off the command line.
  table.insert(parts, "--visibility")
  table.insert(parts, effectiveMode())
  return table.concat(parts, " ") .. " 2>&1"
end

-- The settings that need a daemon restart; visibility switches live.
local function daemonSettings()
  local keys = { "save_dir", "port", "alias", "auto_accept", "device_model", "controller_path" }
  local values = {}
  for _, key in ipairs(keys) do
    table.insert(values, tostring(noctalia.getConfig(key)))
  end
  return table.concat(values, "\0")
end
local lastDaemonSettings = daemonSettings()

local function describeStartError(message)
  message = tostring(message or "")
  if message:find("LocalSend receiver", 1, true) then
    return tr("error.port_busy", { port = tostring(noctalia.getConfig("port") or DEFAULT_PORT) })
  end
  if message:find("already running", 1, true) then return tr("error.already_running") end
  return message ~= "" and message or tr("error.unknown")
end

local function findTransfer(snap, id)
  for _, t in ipairs(snap.transfers or {}) do
    if t.id == id then return t end
  end
  return nil
end

local function notifyIncoming(snap)
  local incoming = snap.incoming
  if seenIncoming ~= nil and (incoming == nil or incoming.id ~= seenIncoming) then
    local previous = findTransfer(snap, seenIncoming)
    if previous ~= nil and previous.state == "cancelled" and previous.peer ~= nil then
      quietBy[previous.peer.fingerprint] = os.time() + ABORT_QUIET_SECONDS
    end
  end
  for fp, untilTime in pairs(quietBy) do
    if os.time() >= untilTime then quietBy[fp] = nil end
  end
  if incoming == nil then
    seenIncoming = nil
    return
  end
  if incoming.id == seenIncoming then return end
  seenIncoming = incoming.id
  local sender = incoming.sender and incoming.sender.fingerprint
  if not primed or (sender ~= nil and quietBy[sender] ~= nil) then return end
  if lib.favoriteOf(sender) == nil and not strangerMayAlert() then return end
  local name = lib.peerLabel(incoming.sender)
  if incoming.messagePreview ~= nil then
    noctalia.notify(tr("notify.title"), tr("notify.incoming_text", { name = name }))
  else
    noctalia.notify(
      tr("notify.title"),
      tr("notify.incoming", { name = name, count = tostring(#(incoming.files or {})) })
    )
  end
  lib.openPanel()
end

-- Tells about a transfer that reached a new state.
local function notifyTransfer(t, firstSeen)
  local name = lib.peerLabel(t.peer)
  local count = tostring(t.fileCount or #(t.files or {}))
  local code = t.error and t.error.code
  if firstSeen and t.autoAccepted and lib.ACTIVE[t.state] then
    noctalia.notify(tr("notify.title"), tr("notify.auto_receiving", { name = name, count = count }))
  elseif t.state == "failed" and lib.PIN_ERRORS[code] then
    -- The panel asks for the PIN on this transfer's row.
    noctalia.notify(tr("notify.title"), tr("notify." .. code, { name = name }))
    lib.openPanel()
  elseif t.state == "completed" then
    if t.direction == "incoming" and t.textMessage then
      noctalia.notify(tr("notify.title"), tr("notify.text_copied", { name = name }))
    else
      local key = t.direction == "incoming" and "notify.received" or "notify.sent"
      noctalia.notify(tr("notify.title"), tr(key, { name = name, count = count }))
    end
  elseif t.state == "failed" then
    noctalia.notifyError(
      tr("notify.title"),
      tr("notify.failed", { name = name, reason = lib.transferError(t.error) or "" })
    )
  elseif t.state == "declined" and t.direction == "outgoing" then
    noctalia.notify(tr("notify.title"), tr("notify.declined", { name = name }))
  end
end

local function notifyChanges(snap)
  notifyIncoming(snap)
  -- Only ids the controller still lists are kept, so the table stays small.
  local seenNow = {}
  for _, t in ipairs(snap.transfers or {}) do
    local previous = seenTransfers[t.id]
    seenNow[t.id] = t.state
    if primed and previous ~= t.state then notifyTransfer(t, previous == nil) end
  end
  seenTransfers = seenNow
  primed = true
end

local function busy(snap)
  if snap.incoming ~= nil then return true end
  for _, t in ipairs(snap.transfers or {}) do
    if lib.ACTIVE[t.state] then return true end
  end
  return false
end

local function poll()
  if phase ~= "running" then return end
  if polling then
    pollAgain = true
    return
  end
  polling = true
  pollAgain = false
  lib.rpc({ "snapshot" }, function(ok, snap)
    polling = false
    if phase ~= "running" then return end
    -- The snapshot in flight may predate the change, so fetch a fresh one.
    if pollAgain then poll() end
    if not ok or type(snap) ~= "table" then
      failures = failures + 1
      if failures >= MAX_POLL_FAILURES then
        noctalia.log("localsend: daemon not answering, restarting")
        fail(tr("error.not_answering"))
      end
      return
    end
    failures = 0
    lastBusy = busy(snap)
    snap.up = true
    snap.phase = phase
    snap.vis = visState()
    snap.autoAcceptChoice = autoAccept.mode
    noctalia.state.set("ls", snap)
    notifyChanges(snap)
    lib.rememberAddresses(snap.devices)
  end)
end

-- Sends the current mode and favorites to a running daemon. A starting one
-- gets them as soon as it reports ready.
local function applyVisibility()
  publish()
  if phase ~= "running" then return end
  local favorites = lib.favoriteArgs()
  local args = table.move(favorites, 1, #favorites, 4, { "set-visibility", "--mode", effectiveMode() })
  lib.rpc(args, function(ok, _, err)
    if not ok then noctalia.notifyError(tr("notify.title"), describeStartError(err and err.message)) end
    poll()
  end)
end

local spawn -- and onDaemonLine call each other

local function onDaemonLine(g, line)
  local data = noctalia.json.decode(line)
  if type(data) ~= "table" then
    noctalia.log("localsend-controller: " .. line)
    return
  end
  if g ~= gen then return end -- a stream we already replaced
  if data.event == "ready" then
    phase = "running"
    ticks = 0
    startError = nil
    failures = 0
    backoff = FIRST_BACKOFF
    failureNotified = false
    -- The mode or favorites may have changed while it was starting; one
    -- set-visibility syncs both.
    applyVisibility()
  elseif data.event == "changed" then
    poll()
  elseif data.event == "stopped" then
    if phase == "stopping" then
      spawn()
    else
      fail(tr("error.stopped"))
    end
  elseif data.ok == false and data.error ~= nil then
    failAndNotify(describeStartError(data.error.message))
  end
end

function spawn()
  if lib.SOCK == nil then
    fail(tr("error.no_runtime_dir"))
  elseif lib.DATA_DIR == nil then
    fail(tr("error.no_data_dir"))
  elseif lib.bin() ~= nil then -- otherwise locateController has reported why
    gen = gen + 1
    local g = gen
    phase = "starting"
    ticks = 0
    publish()
    local started = noctalia.runStream(daemonCommand(), function(line)
      onDaemonLine(g, line)
    end)
    if not started then fail(tr("error.unknown")) end
  end
end

-- Stops whatever daemon answers on our socket (ours, or one left over from an
-- earlier run with old settings), then starts a fresh one. A refused
-- connection means nothing was running, so we can start right away.
local function restart()
  phase = "stopping"
  ticks = 0
  stopAcked = false
  publish()
  -- Looked up on every restart, so Retry picks up a controller installed
  -- in the meantime.
  locateController(function()
    lib.rpc({ "shutdown" }, function(ok)
      if phase ~= "stopping" then return end
      if ok then
        stopAcked = true
      else
        spawn()
      end
    end)
  end)
end

-- A restart the user asked for, without waiting out the backoff.
local function restartNow()
  backoff = FIRST_BACKOFF
  restart()
end

-- True when every path is absolute and exists; otherwise tells the user.
local function validPaths(paths)
  if type(paths) ~= "table" or #paths == 0 then
    noctalia.notifyError(tr("notify.title"), tr("error.no_paths"))
    return false
  end
  for _, path in ipairs(paths) do
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" or not noctalia.fileExists(path) then
      noctalia.notifyError(tr("notify.title"), tr("error.bad_path", { path = tostring(path) }))
      return false
    end
  end
  return true
end

local function pathArgs(fingerprint, paths)
  local args = { "send-files", "--device", fingerprint }
  for _, path in ipairs(paths) do
    table.insert(args, "--path")
    table.insert(args, path)
  end
  return args
end

-- `send` takes absolute paths, one per line (Noctalia joins IPC arguments
-- with spaces, so a line is the only safe separator; see lib.payloadPaths),
-- and lets the panel ask which device gets them.
local function askWhereToSend(payload)
  local paths = lib.payloadPaths(payload)
  if paths == nil then
    noctalia.notifyError(tr("notify.title"), tr("error.line_break"))
    return
  end
  if not validPaths(paths) then return end
  lib.post("send_ask", { paths = paths, at = os.time() })
  lib.openPanel()
end

-- The last send, so a receiver asking for a PIN can get the same files
-- again: { id = transfer id, args = controller arguments without a PIN }.
-- Published as state "retry_id" for the panel.
local lastSend = nil

-- `pinPath` is a one-shot PIN file for a receiver that asked for one.
local function send(args, pinPath)
  local argv = table.clone(args)
  if pinPath ~= nil then
    table.insert(argv, "--pin-file")
    table.insert(argv, pinPath)
  end
  lib.rpc(argv, function(ok, result, err)
    if pinPath ~= nil then lib.removeSecret("send-pin") end
    if ok then
      local id = result and result.transfer and result.transfer.id
      lastSend = id and { id = id, args = args } or nil
      noctalia.state.set("retry_id", id)
      poll()
      lib.openPanel()
    elseif err and (err.code == "clipboard_secret" or err.code == "clipboard_changed") then
      noctalia.notifyError(tr("notify.title"), tr("error." .. err.code))
    else
      noctalia.notifyError(tr("notify.title"), lib.errorText(err))
    end
  end)
end

-- The file dialog. runAsync kills its process after 60 s at most, too short
-- for browsing, so the dialog runs as a stream that ends with a marker
-- carrying its exit code. A random nonce in the marker keeps a picked file
-- name from faking it.
local picking = false
local pickStarted = 0 -- os.time() the open file dialog was started

-- A picker stream that ended without its exit marker (killed dialog,
-- crashed shell) would block every later pick; give up on it after a while.
local PICK_TIMEOUT_SECONDS = 15 * 60

-- Separates the picked paths. A file name can hold a newline, so splitting
-- on lines could turn one odd name into two paths; the unit separator is
-- practically never part of a name.
local PATH_SEPARATOR = "\31"

local function runPicker(req)
  if picking then
    noctalia.notify(tr("notify.title"), tr("error.picker_open"))
    return
  end
  if not noctalia.commandExists("zenity") then
    noctalia.notifyError(tr("notify.title"), tr("error.no_zenity"))
    return
  end
  local parts = { "zenity", "--file-selection" }
  if req.kind == "folder" then
    table.insert(parts, "--directory")
    table.insert(parts, "--title=" .. lib.shq(tr("panel.pick_folder", { name = req.alias })))
  else
    table.insert(parts, "--multiple")
    table.insert(parts, "--separator=" .. lib.shq(PATH_SEPARATOR))
    table.insert(parts, "--title=" .. lib.shq(tr("panel.pick_files", { name = req.alias })))
  end
  local marker = string.format("__LS_EXIT_%d_%d__", os.time(), math.random(1, 2 ^ 30))
  local cmd = table.concat(parts, " ") .. ' 2>/dev/null; echo "' .. marker .. '$?"'
  local lines = {}
  picking = true
  pickStarted = os.time()
  local started = noctalia.runStream(cmd, function(line)
    local code = line:sub(1, #marker) == marker and line:sub(#marker + 1):match("^(%d+)$") or nil
    if code == nil then
      table.insert(lines, line)
      return
    end
    picking = false
    if code ~= "0" then return end -- 1 means cancelled
    local paths = {}
    for _, path in ipairs(table.concat(lines, "\n"):split(PATH_SEPARATOR)) do
      if path ~= "" then
        if path:sub(1, 1) ~= "/" then
          noctalia.notifyError(tr("notify.title"), tr("error.bad_selection"))
          return
        end
        table.insert(paths, path)
      end
    end
    if #paths > 0 then send(pathArgs(req.fingerprint, paths)) end
  end)
  if not started then picking = false end
end

-- Calls `handler` with each new request posted in state `key` (lib.post).
-- State outlives a restart, so the request present at startup is old.
local function watchRequest(key, handler)
  local last = (noctalia.state.get(key) or {}).seq or 0
  noctalia.state.watch(key, function(req)
    if type(req) ~= "table" or (req.seq or 0) <= last then return end
    last = req.seq
    handler(req)
  end)
end

-- Sends from the panel and launcher: { kind, fingerprint, alias, sha, paths }
-- with kind = files | folder | clipboard | paths.
watchRequest("pick", function(req)
  if req.kind == "paths" then
    -- Copied files or an IPC send: the paths are already chosen.
    if validPaths(req.paths) then send(pathArgs(req.fingerprint, req.paths)) end
  elseif req.kind == "clipboard" then
    -- Only a clipboard the panel previewed is sent: the hash pins that text.
    if type(req.sha) ~= "string" or not req.sha:match("^%x+$") or #req.sha ~= 64 then
      noctalia.notifyError(tr("notify.title"), tr("error.clipboard_changed"))
      return
    end
    send({ "send-clipboard", "--device", req.fingerprint, "--expect-sha256", req.sha })
  else
    runPicker(req)
  end
end)

-- Visibility changes from the panel and launcher: { mode, temp }.
watchRequest("visibility_req", function(req)
  if req.temp then
    tempUntil = os.time() + lib.TEMP_SECONDS
  elseif lib.VISIBILITY[req.mode] then
    tempUntil = 0
    visibility.set(req.mode)
  else
    return
  end
  visSeq = visSeq + 1
  applyVisibility()
  if not noctalia.state.get("panel_open") then
    local mode = tr(req.temp and "visibility.temp" or "visibility." .. visibility.mode)
    noctalia.notify(tr("notify.title"), tr("visibility.title", { mode = mode }))
  end
end)

-- The receive PIN, set or removed in the panel: { pin }. It is kept in the
-- private data dir, never in the settings, and the state entry is cleared
-- once the PIN is stored. A new PIN needs a new receiver.
watchRequest("pin_req", function(req)
  noctalia.state.set("pin_req", { seq = req.seq })
  if PIN_FILE == nil then return end
  if type(req.pin) == "string" and req.pin ~= "" then
    -- The PIN is stored only in a directory nobody else can read.
    if not dataPrivate then
      noctalia.notifyError(tr("notify.title"), tr("error.data_not_private"))
      return
    end
    local ok, err = noctalia.writeFile(PIN_FILE, req.pin)
    if not ok then
      noctalia.notifyError(tr("notify.title"), tostring(err))
      return
    end
    lib.restrictFile(PIN_FILE)
  else
    noctalia.removeFile(PIN_FILE)
  end
  primed = false
  restartNow()
end)

-- "Accept when the PIN is right" from the PIN card: { on }. Turning it off
-- goes back to the settings value, or favorites if that is everyone.
watchRequest("auto_req", function(req)
  local fallback = autoAccept.setting ~= "everyone" and autoAccept.setting or "favorites"
  local mode = req.on and "everyone" or fallback
  if mode == autoAccept.mode then return end
  autoAccept.set(mode)
  primed = false
  restartNow()
end)

-- A send retried with the PIN the receiver asked for: { id, pin }.
watchRequest("pin_retry", function(req)
  noctalia.state.set("pin_retry", { seq = req.seq })
  if lastSend == nil or lastSend.id ~= req.id or type(req.pin) ~= "string" or req.pin == "" then return end
  local pinPath = lib.writeSecret("send-pin", req.pin)
  if pinPath == nil then return end
  -- The failed attempt makes way for the retry in the list.
  local hidden = table.clone(lib.hiddenTransfers())
  hidden[req.id] = true
  noctalia.state.set("hidden", hidden)
  send(lastSend.args, pinPath)
end)

-- The favorites mode needs the current list (and addresses) in the daemon.
noctalia.state.watch("favorites", applyVisibility)
noctalia.state.watch("poke", poll)
noctalia.state.watch("restart", restartNow)

function update()
  ticks = ticks + 1
  if picking and os.time() - pickStarted > PICK_TIMEOUT_SECONDS then picking = false end
  if tempUntil > 0 and os.time() >= tempUntil then
    tempUntil = 0
    visSeq = visSeq + 1
    applyVisibility()
    noctalia.notify(tr("notify.title"), tr("notify.temp_ended", { mode = tr("visibility." .. visibility.mode) }))
  end
  if phase == "stopping" then
    -- Fallback when no "stopped" line arrives (a daemon from an earlier run
    -- has no stream here); the port may still be held briefly, which the
    -- failed/backoff path absorbs.
    local waited = stopAcked and ticks >= STOP_GRACE_TICKS or ticks >= STOP_TIMEOUT_TICKS
    if lib.bin() ~= nil and waited then spawn() end
  elseif phase == "starting" then
    if ticks >= START_TIMEOUT_TICKS then fail(tr("error.no_ready")) end
  elseif phase == "running" then
    if noctalia.state.get("panel_open") or lastBusy or ticks % IDLE_POLL_TICKS == 0 then poll() end
  elseif phase == "failed" then
    if ticks >= backoff then
      backoff = math.min(backoff * 2, MAX_BACKOFF)
      restart()
    end
  end
end

function onConfigChanged()
  extras.sync()
  if visibility.sync() then
    tempUntil = 0
    visSeq = visSeq + 1
  end
  autoAccept.sync() -- the restart below picks it up
  local settings = daemonSettings()
  if settings ~= lastDaemonSettings then
    lastDaemonSettings = settings
    primed = false
    restart() -- the new daemon starts in the current mode
  else
    applyVisibility()
  end
end

function onIpc(event, payload)
  if event == "refresh" then
    lib.rpc({ "refresh" }, poll)
  elseif event == "restart" then
    restartNow()
  elseif event == "updated" then
    -- From controller/update.sh, with the path of the controller it built.
    local path = lib.trim(payload or "")
    if BUILT_FILE ~= nil and path:sub(1, 1) == "/" and lib.basename(path) == "localsend-controller" then
      noctalia.writeFile(BUILT_FILE, path)
    end
    restartNow()
  elseif event == "send" then
    askWhereToSend(payload)
  end
end

function onExit()
  -- Detached so it still runs after this VM is gone; the runtime also ends
  -- the stream, which the daemon handles as a graceful SIGTERM.
  if lib.SOCK ~= nil and lib.bin() ~= nil then noctalia.runAsync({ lib.bin(), "--socket", lib.SOCK, "shutdown" }) end
end

-- A retry needs the arguments this run remembers, and state outlives it.
noctalia.state.set("retry_id", nil)
lib.removeSecret("pin")
lib.removeSecret("send-pin")
noctalia.setUpdateInterval(1000)

-- The data directory holds the PIN, the device key and the favorites'
-- addresses, so it is made private before the daemon starts.
if lib.DATA_DIR ~= nil then
  noctalia.runAsync({ "chmod", "700", lib.DATA_DIR }, function(res)
    dataPrivate = res.exitCode == 0
    if not dataPrivate then noctalia.log("localsend: could not make the data directory private") end
    lib.restrictFile(PIN_FILE)
    lib.restrictFile(lib.dataFile("favorites.json"))
    extras.sync()
    restart()
  end)
else
  extras.sync()
  restart()
end
