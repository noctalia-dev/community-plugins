--!nonstrict
-- Background service: owns the localsend-controller daemon and mirrors its
-- snapshot to the widget and panel through noctalia.state ("ls").

local lib = require("./lib.luau")

-- phase: "stopping" -> "starting" -> "running"; "failed" retries with backoff
local phase = "stopping"
local ticks = 0
local gen = 0            -- generation of the daemon stream we own
local stopAcked = false  -- a daemon answered our shutdown request
local polling = false
local failures = 0
local backoff = 5
local lastBusy = false
local startError = nil
local failureNotified = false -- one error notification per run of failed starts

local seenTransfers = {} -- transfer id -> last state seen
local seenIncoming = nil -- id of the pending request we notified about
local primed = false     -- the first snapshot only records state
local dataPrivate = false -- the data directory is known to be 0700
local quietBy = {}       -- sender fingerprint -> os.time() before which its requests do not alert

-- A request its sender withdrew before we answered silences that sender's
-- alerts for a while, so a peer that keeps offering and withdrawing cannot
-- flood notifications or keep popping the panel open. Other senders still
-- alert. (The controller also declines its requests for a minute.)
local ABORT_QUIET_SECONDS = 30

local function tr(key, args) return noctalia.tr(key, args) end

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
    local ok, err = noctalia.writeFile(file, noctalia.json.encode({ mode = mode, setting = choice.setting }))
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
local visSeq = 0    -- counts visibility changes, so the panel can show each one once

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
  noctalia.state.set("ls", { up = false, phase = phase, startError = startError, install = installCommand,
    vis = visState(), autoAcceptChoice = autoAccept.mode })
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
local CONTROLLER_SOURCES = noctalia.pluginDir() .. "/controller"

local function versionParts(text)
  local major, minor, patch = tostring(text or ""):match("(%d+)%.(%d+)%.(%d+)")
  if major == nil then return nil end
  return { tonumber(major), tonumber(minor), tonumber(patch) }
end

local function olderThan(a, b)
  for i = 1, 3 do
    if a[i] ~= b[i] then return a[i] < b[i] end
  end
  return false
end

-- The version of the bundled sources: an installed controller must be at
-- least that new, so a plugin update that changes it asks for a rebuild.
local function requiredVersion()
  local raw = noctalia.readFile(CONTROLLER_SOURCES .. "/Cargo.toml") or ""
  return versionParts(raw:match('\nversion%s*=%s*"([%d%.]+)"'))
end

local function candidates(onPath)
  local configured = lib.trim(noctalia.getConfig("controller_path") or "")
  if configured ~= "" then return { noctalia.expandPath(configured) } end
  return { onPath, noctalia.expandPath("~/.cargo/bin/localsend-controller"),
    noctalia.expandPath("~/.local/bin/localsend-controller") }
end

local function controllerMissing(message)
  noctalia.state.set("controller", nil)
  installCommand = "cargo install --locked --path " .. lib.shq(CONTROLLER_SOURCES)
    .. " --target-dir ~/.cache/localsend-plus/target"
  failAndNotify(message)
end

-- Finds a usable controller, publishes it as state "controller" and calls
-- onFound; otherwise fails with the install command.
local function locateController(onFound)
  noctalia.runAsync("command -v localsend-controller", function(res)
    local path = nil
    for _, candidate in ipairs(candidates(lib.trim(res.stdout or ""))) do
      if candidate ~= "" and candidate:sub(1, 1) == "/" and noctalia.fileExists(candidate) then
        path = candidate
        break
      end
    end
    if path == nil then return controllerMissing(tr("error.no_controller")) end
    noctalia.runAsync({ path, "--version" }, function(ver)
      local data = noctalia.json.decode(lib.trim(ver.stdout or ""))
      local found = versionParts(type(data) == "table" and data.result and data.result.help)
      local needed = requiredVersion()
      if found == nil then
        return controllerMissing(tr("error.bad_controller", { path = path }))
      end
      if needed ~= nil and olderThan(found, needed) then
        return controllerMissing(tr("error.old_controller", { found = table.concat(found, "."),
          needed = table.concat(needed, ".") }))
      end
      installCommand = nil
      noctalia.state.set("controller", { path = path, version = table.concat(found, ".") })
      onFound()
    end)
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
    "exec", lib.shq(lib.bin()), "--socket", lib.shq(lib.SOCK), "daemon",
    "--port", tostring(math.floor(tonumber(noctalia.getConfig("port")) or 53317)),
    "--destination", lib.shq(dest),
    "--state-directory", lib.shq(lib.dataFile("controller")),
    "--auto-accept", autoAccept.mode,
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
  for _, key in ipairs(keys) do table.insert(values, tostring(noctalia.getConfig(key))) end
  return table.concat(values, "\0")
end
local lastDaemonSettings = daemonSettings()

local function describeStartError(message)
  message = tostring(message or "")
  if message:find("LocalSend receiver", 1, true) then
    return tr("error.port_busy", { port = tostring(noctalia.getConfig("port") or 53317) })
  end
  if message:find("already running", 1, true) then return tr("error.already_running") end
  return message ~= "" and message or tr("error.unknown")
end

local spawn
local poll
local releaseStalePicker

-- Sends the current mode and favorites to a running daemon. A starting one
-- gets them as soon as it reports ready.
local function applyVisibility()
  publish()
  if phase ~= "running" then return end
  local args = { "set-visibility", "--mode", effectiveMode() }
  for _, arg in ipairs(lib.favoriteArgs()) do table.insert(args, arg) end
  lib.rpc(args, function(ok, _, err)
    if not ok then
      noctalia.notifyError(tr("notify.title"), describeStartError(err and err.message))
    end
    poll()
  end)
end

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
    backoff = 5
    failureNotified = false
    -- The mode or favorites may have changed while it was starting; one
    -- set-visibility syncs both.
    applyVisibility()
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

spawn = function()
  if lib.SOCK == nil then return fail(tr("error.no_runtime_dir")) end
  if lib.DATA_DIR == nil then return fail(tr("error.no_data_dir")) end
  if lib.bin() == nil then return end -- locateController has reported why
  gen = gen + 1
  local g = gen
  phase = "starting"
  ticks = 0
  publish()
  if not noctalia.runStream(daemonCommand(), function(line) onDaemonLine(g, line) end) then
    fail(tr("error.unknown"))
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
      if ok then stopAcked = true else spawn() end
    end)
  end)
end

local function findTransfer(snap, id)
  for _, t in ipairs(snap.transfers or {}) do
    if t.id == id then return t end
  end
  return nil
end

-- Failed sends the panel can retry with a PIN (pin_locked cannot be).
local PIN_ERRORS = { pin_required = true, pin_invalid = true }

local function notifyChanges(snap)
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
  if incoming ~= nil and incoming.id ~= seenIncoming then
    seenIncoming = incoming.id
    local sender = incoming.sender and incoming.sender.fingerprint
    if primed and (sender == nil or quietBy[sender] == nil) then
      local name = incoming.sender and incoming.sender.alias or "?"
      if incoming.messagePreview ~= nil then
        noctalia.notify(tr("notify.title"), tr("notify.incoming_text", { name = name }))
      else
        noctalia.notify(tr("notify.title"),
          tr("notify.incoming", { name = name, count = tostring(#(incoming.files or {})) }))
      end
      if not noctalia.state.get("panel_open") then noctalia.togglePanel(lib.PANEL) end
    end
  elseif incoming == nil then
    seenIncoming = nil
  end

  -- Only ids the controller still lists are kept, so the table stays small.
  local seenNow = {}
  for _, t in ipairs(snap.transfers or {}) do seenNow[t.id] = seenTransfers[t.id] end
  seenTransfers = seenNow

  for _, t in ipairs(snap.transfers or {}) do
    if seenTransfers[t.id] ~= t.state then
      local firstSeen = seenTransfers[t.id] == nil
      seenTransfers[t.id] = t.state
      if primed then
        local name = t.peer and t.peer.alias or "?"
        local count = tostring(t.fileCount or #(t.files or {}))
        local code = t.error and t.error.code
        if firstSeen and t.autoAccepted and lib.ACTIVE[t.state] then
          noctalia.notify(tr("notify.title"), tr("notify.auto_receiving", { name = name, count = count }))
        elseif t.state == "failed" and PIN_ERRORS[code] then
          -- The panel asks for the PIN on this transfer's row.
          noctalia.notify(tr("notify.title"), tr("notify." .. code, { name = name }))
          if not noctalia.state.get("panel_open") then noctalia.togglePanel(lib.PANEL) end
        elseif t.state == "completed" then
          if t.direction == "incoming" and t.textMessage then
            noctalia.notify(tr("notify.title"), tr("notify.text_copied", { name = name }))
          else
            local key = t.direction == "incoming" and "notify.received" or "notify.sent"
            noctalia.notify(tr("notify.title"), tr(key, { name = name, count = count }))
          end
        elseif t.state == "failed" then
          noctalia.notifyError(tr("notify.title"), tr("notify.failed", {
            name = name, reason = lib.transferError(t.error) or "" }))
        elseif t.state == "declined" and t.direction == "outgoing" then
          noctalia.notify(tr("notify.title"), tr("notify.declined", { name = name }))
        end
      end
    end
  end
  primed = true
end

local function busy(snap)
  if snap.incoming ~= nil then return true end
  for _, t in ipairs(snap.transfers or {}) do
    if lib.ACTIVE[t.state] then return true end
  end
  return false
end

poll = function()
  if polling or phase ~= "running" then return end
  polling = true
  lib.rpc({ "snapshot" }, function(ok, snap)
    polling = false
    if phase ~= "running" then return end
    if not ok or type(snap) ~= "table" then
      failures = failures + 1
      if failures >= 3 then
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

function update()
  ticks = ticks + 1
  releaseStalePicker()
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
    if lib.bin() ~= nil and ((stopAcked and ticks >= 3) or ticks >= 6) then spawn() end
  elseif phase == "starting" then
    if ticks >= 15 then fail(tr("error.no_ready")) end
  elseif phase == "running" then
    if noctalia.state.get("panel_open") or lastBusy or ticks % 3 == 0 then poll() end
  elseif phase == "failed" then
    if ticks >= backoff then
      backoff = math.min(backoff * 2, 60)
      restart()
    end
  end
end

-- Integrations copied outside the plugin's folders while their setting is
-- on: the Dolphin context menu entry, and the `localsend` command with
-- completion for fish, bash and zsh. Each shell loads its folder by itself
-- (zsh once ~/.local/share/zsh/site-functions is in fpath), so no shell
-- config is touched. A file that is already there with other content is
-- left alone. Turning a setting off removes only files the plugin wrote
-- itself, noted in a marker file in the data dir.
local EXTRAS = {
  {
    setting = "dolphin_menu",
    files = {
      -- KDE skips service menus in the home folder that are not executable.
      ["extras/localsend-plus.desktop"] = { path = "~/.local/share/kio/servicemenus/localsend-plus.desktop",
        executable = true },
    },
  },
  {
    setting = "terminal_command",
    files = {
      ["extras/terminal/localsend"] = { path = "~/.local/bin/localsend", executable = true },
      ["extras/terminal/localsend.fish"] = { path = "~/.local/share/fish/vendor_completions.d/localsend.fish" },
      ["extras/terminal/localsend.bash"] = { path = "~/.local/share/bash-completion/completions/localsend" },
      ["extras/terminal/_localsend"] = { path = "~/.local/share/zsh/site-functions/_localsend" },
    },
  },
}

local extraWarned = {} -- settings whose blocked install was reported this run

local function syncExtra(extra)
  local mark = lib.dataFile(extra.setting)
  local installed = mark ~= nil and noctalia.fileExists(mark)
  local wanted = noctalia.getConfig(extra.setting) == true
  if not wanted then extraWarned[extra.setting] = nil end
  if wanted then
    local plan = {}
    for source, file in pairs(extra.files) do
      local content = noctalia.readFile(noctalia.pluginDir() .. "/" .. source)
      if content == nil then return end
      local path = noctalia.expandPath(file.path)
      local current = noctalia.readFile(path)
      if current ~= nil and current ~= content and not installed then
        if not extraWarned[extra.setting] then
          extraWarned[extra.setting] = true
          noctalia.notifyError(tr("notify.title"), tr("error.extra_exists", { path = path }))
        end
        return
      end
      table.insert(plan, { path = path, content = content, write = current ~= content,
        executable = file.executable })
    end
    for _, item in ipairs(plan) do
      if item.write then
        local ok, err = noctalia.mkdirAll(lib.dirname(item.path))
        if ok then ok, err = noctalia.writeFile(item.path, item.content) end
        if not ok then
          noctalia.notifyError(tr("notify.title"), tr("error.install_extra", { path = item.path, reason = tostring(err) }))
          return
        end
      end
      if item.executable then noctalia.runAsync({ "chmod", "755", item.path }) end
    end
    if mark ~= nil then noctalia.writeFile(mark, "installed") end
  elseif installed then
    for _, file in pairs(extra.files) do
      local path = noctalia.expandPath(file.path)
      if noctalia.fileExists(path) then noctalia.removeFile(path) end
    end
    noctalia.removeFile(mark)
  end
end

local function syncExtras()
  for _, extra in ipairs(EXTRAS) do syncExtra(extra) end
end

function onConfigChanged()
  syncExtras()
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
-- with spaces, so a line is the only safe separator), and lets the panel
-- ask which device gets them. Only a carriage return is stripped: spaces
-- at either end belong to the file name.
local function askWhereToSend(payload)
  local paths = {}
  for _, line in ipairs(tostring(payload or ""):split("\n")) do
    local path = line:gsub("\r$", "")
    if path ~= "" then table.insert(paths, path) end
  end
  if not validPaths(paths) then return end
  local seq = ((noctalia.state.get("send_ask") or {}).seq or 0) + 1
  noctalia.state.set("send_ask", { seq = seq, paths = paths, at = os.time() })
  if not noctalia.state.get("panel_open") then noctalia.togglePanel(lib.PANEL) end
end

function onIpc(event, payload)
  if event == "refresh" then
    lib.rpc({ "refresh" }, function() poll() end)
  elseif event == "restart" then
    backoff = 5
    restart()
  elseif event == "send" then
    askWhereToSend(payload)
  end
end

function onExit(signal, reason)
  -- Detached so it still runs after this VM is gone; the runtime also ends
  -- the stream, which the daemon handles as a graceful SIGTERM.
  if lib.SOCK ~= nil and lib.bin() ~= nil then
    noctalia.runAsync({ lib.bin(), "--socket", lib.SOCK, "shutdown" })
  end
end

-- Send requests from the panel and launcher ({ seq, kind, fingerprint, alias },
-- kind = files | folder | clipboard). They carry an increasing seq; anything at
-- or below the value present at startup is stale (state outlives restarts).
local lastPick = (noctalia.state.get("pick") or {}).seq or 0
local picking = false
local pickStarted = 0 -- os.time() the open file dialog was started

-- A picker stream that ended without its exit marker (killed dialog,
-- crashed shell) would block every later pick; give up on it after a while.
local PICK_TIMEOUT_SECONDS = 15 * 60

releaseStalePicker = function()
  if picking and os.time() - pickStarted > PICK_TIMEOUT_SECONDS then picking = false end
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
      if not noctalia.state.get("panel_open") then noctalia.togglePanel(lib.PANEL) end
    elseif err and err.code == "clipboard_secret" then
      noctalia.notifyError(tr("notify.title"), tr("error.clipboard_secret"))
    elseif err and err.code == "clipboard_changed" then
      noctalia.notifyError(tr("notify.title"), tr("error.clipboard_changed"))
    else
      noctalia.notifyError(tr("notify.title"), (err and err.message ~= "" and err.message) or tr("error.unknown"))
    end
  end)
end

-- Separates the picked paths. A file name can hold a newline, so splitting
-- on lines could turn one odd name into two paths; the unit separator is
-- practically never part of a name.
local PATH_SEPARATOR = "\31"

math.randomseed(noctalia.nowMs())

-- runAsync kills its process after 5 s by default and 60 s at most, too
-- short for browsing in a file dialog, so the picker runs as a stream that
-- reports its exit code.
-- The exit marker carries a random nonce, so no picked file name can fake it.
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
  local cmd = table.concat(parts, " ") .. " 2>/dev/null; echo \"" .. marker .. "$?\""
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
    local args = { "send-files", "--device", req.fingerprint }
    for _, path in ipairs(table.concat(lines, "\n"):split(PATH_SEPARATOR)) do
      if path ~= "" then
        if path:sub(1, 1) ~= "/" then
          noctalia.notifyError(tr("notify.title"), tr("error.bad_selection"))
          return
        end
        table.insert(args, "--path")
        table.insert(args, path)
      end
    end
    if #args > 3 then send(args) end
  end)
  if not started then picking = false end
end

noctalia.state.watch("pick", function(req)
  if type(req) ~= "table" or (req.seq or 0) <= lastPick then return end
  lastPick = req.seq
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

-- Visibility changes from the panel and launcher ({ seq, mode, temp }).
local lastVisibilityReq = (noctalia.state.get("visibility_req") or {}).seq or 0

noctalia.state.watch("visibility_req", function(req)
  if type(req) ~= "table" or (req.seq or 0) <= lastVisibilityReq then return end
  lastVisibilityReq = req.seq
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
    noctalia.notify(tr("notify.title"), tr("visibility.title", { mode = tr(req.temp and "visibility.temp" or "visibility." .. visibility.mode) }))
  end
end)

-- The favorites mode needs the current list (and addresses) in the daemon.
noctalia.state.watch("favorites", function() applyVisibility() end)

-- The receive PIN, set or removed in the panel ({ seq, pin }). It is kept
-- in the private data dir, never in the settings, and the state entry is
-- cleared once the PIN is stored. A new PIN needs a new receiver.
local lastPinReq = (noctalia.state.get("pin_req") or {}).seq or 0

noctalia.state.watch("pin_req", function(req)
  if type(req) ~= "table" or (req.seq or 0) <= lastPinReq then return end
  lastPinReq = req.seq
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
  backoff = 5
  restart()
end)

-- "Accept when the PIN is right" from the PIN card ({ seq, on }). Turning
-- it off goes back to the settings value, or favorites if that is everyone.
local lastAutoReq = (noctalia.state.get("auto_req") or {}).seq or 0

noctalia.state.watch("auto_req", function(req)
  if type(req) ~= "table" or (req.seq or 0) <= lastAutoReq then return end
  lastAutoReq = req.seq
  local fallback = autoAccept.setting ~= "everyone" and autoAccept.setting or "favorites"
  local mode = req.on and "everyone" or fallback
  if mode == autoAccept.mode then return end
  autoAccept.set(mode)
  primed = false
  backoff = 5
  restart()
end)

-- A send retried with the PIN the receiver asked for ({ seq, id, pin }).
local lastPinRetry = (noctalia.state.get("pin_retry") or {}).seq or 0

noctalia.state.watch("pin_retry", function(req)
  if type(req) ~= "table" or (req.seq or 0) <= lastPinRetry then return end
  lastPinRetry = req.seq
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

noctalia.state.watch("poke", function() poll() end)
noctalia.state.watch("restart", function()
  backoff = 5
  restart()
end)

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
    syncExtras()
    restart()
  end)
else
  syncExtras()
  restart()
end
