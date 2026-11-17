--!nonstrict
-- Resurrect service: saves the system's setup into a git repository (lib/save.luau), once a
-- day, when Noctalia starts with sharing on, and when asked, and opens restore.sh from that
-- repository in a terminal. With sharing on, each save also takes in what other devices
-- changed; files changed on two devices wait for the owner's choice, which goes with the next
-- save. Packages and services other devices have and this one does not are listed; install.sh
-- sets them up in a terminal, and names the owner leaves out go with the next save. Those
-- another device removed and this one still has are listed too; the owner shares them again,
-- or keeps them only here.
--
-- The save runs as a coroutine: it pauses while each command runs, and at the end of each
-- update tick's share of time, so no callback goes over its CPU time. A git command that
-- reaches the network may take longer than the 60 s limit of runAsync callbacks, so it runs
-- detached through LONG, which writes its output and exit code to the data directory.
--
-- Publishes "resurrect.model" and takes commands on "resurrect.command".

local Save = require("./lib/save.luau")
local Settings = require("./lib/settings.luau")

local DAY_MS = 24 * 60 * 60 * 1000
-- A network command that runs longer than this is given up.
local RUN_LIMIT_MS = 30 * 60 * 1000

-- How long the save runs in one callback before it waits for the next update tick.
local SLICE_SECONDS = 0.008
local SAVING_TICK_MS = 50
local IDLE_TICK_MS = 2000

-- $1 is the path prefix of the command's files, the rest is the command.
local LONG = 'prefix=$1; shift; "$@" >"$prefix.log" 2>&1; echo $? >"$prefix.exit"'

local dataDir = noctalia.pluginDataDir() or ""
local stateFile = dataDir .. "/state.json"
-- The settings this device kept for itself, which restore.sh leaves for the service.
local restoreFile = dataDir .. "/restore-device.toml"
local installFile = dataDir .. "/install.txt"
-- The save steps this device approved, as "<checksum> <path>" lines; see review.sh.
local approvedFile = dataDir .. "/approved-steps"

-- result: "saved", "unchanged" or "pushed"; counts: what the last save held, by kind.
-- conflicts and held: shared files that wait for the owner, by path under the home folder.
-- incoming: shared files only another device changed, which wait until the owner takes them;
-- incomingSettings: how many Noctalia settings wait the same way.
-- missing: packages and services other devices have, as { list = "pacman", name = "foo" };
-- left: those another device removed and this one still has, the same way.
local state = {
  lastMs = nil, result = nil, error = nil, counts = nil, conflicts = {}, held = {}, missing = {}, left = {},
  incoming = {}, incomingSettings = 0,
}
-- Choices not yet passed to a save: path -> "mine" or "theirs", and the same for the
-- settings that wait.
local choices = {}
local settingsChoice = nil
-- The waiting files, one path per line, for changes.sh to show.
local incomingFile = dataDir .. "/incoming.txt"
-- Names to leave off this device, and { list, name } items to share again or keep only
-- here, not yet passed to a save.
local skips = {}
local again = {}
local only = {}
local running = false
local saveAgain = false
-- The file lists the running save started with. When the save takes in other ones from
-- another device, it saves once more with them.
local runLists = ""
local loaded = false
-- The save under way: { co, waiting = "tick" or "call", out = { lines }, done }.
local job = nil
local sliceStart = 0

local function repo()
  return noctalia.expandPath(noctalia.getConfig("folder") or "~/resurrect")
end

local function save()
  local text = noctalia.json.encode(state)
  if text then
    noctalia.writeFile(stateFile, text)
  end
end

local function list(key)
  local items = {}
  for _, path in ipairs(noctalia.getConfig(key) or {}) do
    table.insert(items, path)
  end
  return items
end

local function sharing()
  return noctalia.getConfig("share") == true
end

local function publish()
  local files = list("files")
  noctalia.state.set("resurrect.model", {
    ready = noctalia.commandExists("git"),
    running = running,
    lastMs = state.lastMs,
    result = state.result,
    error = state.error,
    folder = noctalia.getConfig("folder") or "~/resurrect",
    remote = noctalia.getConfig("remote") or "",
    packages = noctalia.getConfig("packages") ~= false,
    services = noctalia.getConfig("services") ~= false,
    noctalia = noctalia.getConfig("noctalia") ~= false,
    files = files,
    share = sharing(),
    deviceFiles = list("device_files"),
    conflicts = state.conflicts or {},
    held = state.held or {},
    incoming = state.incoming or {},
    incomingSettings = state.incomingSettings or 0,
    choices = choices,
    settingsChoice = settingsChoice,
    missing = state.missing or {},
    left = state.left or {},
    canRestore = noctalia.fileExists(repo() .. "/restore.sh"),
    counts = state.counts or {},
    hooks = repo() .. "/hooks",
    canOpen = noctalia.commandExists("xdg-open"),
  })
end

local function lists()
  return noctalia.json.encode({ list("files"), list("device_files"), list("leave_out") })
end

local finish
local snapshot
local restoreSettings

-- Runs the save until it waits for a command or the next tick, or ends.
local function resume(...)
  local current = job
  sliceStart = os.clock()
  local ok, why = coroutine.resume(current.co, ...)
  if job ~= current then
    return
  end
  if not ok then
    if type(why) == "table" and why.stopCode then
      current.done(why.stopCode, current.out)
    else
      table.insert(current.out, tostring(why))
      current.done(1, current.out)
    end
  elseif coroutine.status(current.co) == "dead" then
    current.done(0, current.out)
  else
    current.waiting = why
  end
end

-- What the save uses to run commands and to pause; see lib/save.luau.
local function newJob(out)
  local jobApi = {}
  function jobApi.emit(line)
    table.insert(out, line)
  end
  function jobApi.stop(code)
    error({ stopCode = code }, 0)
  end
  function jobApi.breathe()
    if os.clock() - sliceStart >= SLICE_SECONDS then
      coroutine.yield("tick")
    end
  end
  function jobApi.wait(ms)
    local untilMs = noctalia.nowMs() + ms
    repeat
      coroutine.yield("tick")
    until noctalia.nowMs() >= untilMs
  end
  function jobApi.run(argv)
    local box = { co = coroutine.running(), paused = false, result = nil }
    local started = noctalia.runAsync(argv, function(result)
      if box.paused and job and job.co == box.co then
        resume(result)
      else
        box.result = result
      end
    end, 60000)
    if not started then
      return { exitCode = 127, stdout = "", stderr = "could not run " .. argv[1] }
    end
    if box.result then
      return box.result
    end
    box.paused = true
    return coroutine.yield("call")
  end
  function jobApi.long(argv)
    local prefix = dataDir .. "/net-" .. noctalia.nowMs()
    local full = { "sh", "-c", LONG, "resurrect", prefix }
    table.move(argv, 1, #argv, #full + 1, full)
    noctalia.runAsync(full)
    local startMs = noctalia.nowMs()
    while not noctalia.fileExists(prefix .. ".exit") do
      if noctalia.nowMs() - startMs >= RUN_LIMIT_MS then
        return { exitCode = 1, output = "timed out: " .. table.concat(argv, " ") }
      end
      coroutine.yield("tick")
    end
    local code = tonumber(noctalia.string.trim(noctalia.readFile(prefix .. ".exit") or "")) or 1
    local output = noctalia.readFile(prefix .. ".log") or ""
    noctalia.removeFile(prefix .. ".exit")
    noctalia.removeFile(prefix .. ".log")
    return { exitCode = code, output = output }
  end
  return jobApi
end

local function expanded(key)
  local paths = {}
  for _, path in ipairs(list(key)) do
    table.insert(paths, noctalia.expandPath(path))
  end
  return paths
end

-- Starts <work> as the job under way; <done> reads its exit code and output lines.
local function startJob(work, done)
  local out = {}
  local api = newJob(out)
  job = { co = coroutine.create(function()
    work(api)
  end), out = out, done = done }
  noctalia.setUpdateInterval(SAVING_TICK_MS)
  resume()
end

-- Puts back the settings this device kept for itself, which restore.sh leaves in
-- restoreFile; the shared ones are already in place. They join the settings as they are now.
restoreSettings = function()
  running = true
  startJob(function(api)
    Settings.breathe = api.breathe
    local path = noctalia.expandPath("~/.local/state/noctalia/settings.toml")
    local before = noctalia.readFile(path) or ""
    local ok, merged = pcall(Settings.merge, noctalia.readFile(restoreFile) or "", before, "")
    if not ok then
      api.emit(tostring(merged))
      api.stop(1)
    end
    if merged.settings then
      local backup = noctalia.expandPath("~/.local/state/resurrect/backup-" .. os.date("%Y%m%d-%H%M%S")
        .. "/.local/state/noctalia")
      noctalia.mkdirAll(backup)
      local tmp = path .. ".resurrect-tmp"
      if not (noctalia.writeFile(backup .. "/settings.toml", before) and noctalia.writeFile(tmp, merged.settings)
        and noctalia.renameFile(tmp, path)) then
        api.emit("could not write " .. path)
        api.stop(1)
      end
      api.run({ "noctalia", "msg", "config-reload" })
    end
  end, function(code, out)
    job = nil
    running = false
    noctalia.setUpdateInterval(IDLE_TICK_MS)
    noctalia.removeFile(restoreFile)
    if code ~= 0 then
      noctalia.notifyError(noctalia.tr("notify.failed"), out[#out] or noctalia.tr("error.unknown"))
    end
    if sharing() then
      snapshot()
    end
  end)
end

snapshot = function()
  if running or not noctalia.commandExists("git") then
    return
  end
  running = true
  saveAgain = false
  runLists = lists()
  noctalia.mkdirAll(dataDir)
  -- Files a save stopped by a reload left behind.
  for _, name in ipairs(noctalia.listDir(dataDir) or {}) do
    if name:match("^net%-") then
      noctalia.removeFile(dataDir .. "/" .. name)
    end
  end
  local opt = {
    repo = repo(),
    remote = noctalia.getConfig("remote") or "",
    packages = noctalia.getConfig("packages") ~= false,
    services = noctalia.getConfig("services") ~= false,
    noctalia = noctalia.getConfig("noctalia") ~= false,
    share = sharing(),
    secretCheck = noctalia.getConfig("secret_check") ~= false,
    files = expanded("files"),
    deviceFiles = expanded("device_files"),
    leaveOut = expanded("leave_out"),
    approved = approvedFile,
    dataDir = dataDir,
    resolve = choices,
    settingsChoice = settingsChoice,
    exclude = skips,
    again = again,
    only = only,
  }
  choices, skips, again, only = {}, {}, {}, {}
  settingsChoice = nil
  publish()
  startJob(function(api)
    Save.run(api, opt)
  end, finish)
end

-- Saves now, or right after the save that runs.
local function saveSoon()
  if running then
    saveAgain = true
  else
    snapshot()
  end
end

-- The last line of the save's output that is not a "skipped" note or a shared file's state,
-- as the error to show.
local function lastLine(text)
  local found = nil
  for line in (text or ""):gmatch("[^\n]+") do
    if not line:match("^skipped") and not line:match("^applied ") and not line:match("^removed ")
      and not line:match("^conflict ") and not line:match("^held ") and not line:match("^settings ")
      and not line:match("^incoming")
      and not line:match("^missing ") and not line:match("^left ") and not line:match("^kept ") then
      found = line
    end
  end
  return found
end

-- Reads what a save did, from its exit code and output lines.
finish = function(code, out)
  job = nil
  running = false
  noctalia.setUpdateInterval(IDLE_TICK_MS)
  local log = table.concat(out, "\n")
  -- Kept for the owner to read when a save fails.
  noctalia.writeFile(dataDir .. "/save.log", log .. "\n")
  state.lastMs = noctalia.nowMs()
  local counts = {}
  for what, number in (log or ""):gmatch("count (%a+) (%d+)") do
    counts[what] = tonumber(number)
  end
  if next(counts) then
    state.counts = counts
  end
  -- What the save did with the other devices' files. A file held back was also applied
  -- first, then put back.
  local applied, conflicts, held, heldSet, incoming = {}, {}, {}, {}, {}
  local lines = {}
  for line in (log or ""):gmatch("[^\n]+") do
    local word, path = line:match("^(%a+) (.+)$")
    if word then
      table.insert(lines, { word = word, path = path })
    end
  end
  for _, line in ipairs(lines) do
    if line.word == "held" then
      heldSet[line.path] = true
      table.insert(held, line.path)
    elseif line.word == "conflict" then
      table.insert(conflicts, line.path)
    elseif line.word == "incoming" then
      table.insert(incoming, line.path)
    end
  end
  for _, line in ipairs(lines) do
    if (line.word == "applied" or line.word == "removed") and not heldSet[line.path] then
      table.insert(applied, line.path)
    end
  end
  -- Choices made while this run went are not in its lists yet; the next run adds them.
  local chosen = {}
  for _, name in ipairs(skips) do
    chosen[name] = true
  end
  for _, item in ipairs(again) do
    chosen[item.name] = true
  end
  for _, item in ipairs(only) do
    chosen[item.name] = true
  end
  local missing, left = {}, {}
  for _, line in ipairs(lines) do
    if line.word == "missing" or line.word == "left" then
      local listName, name = line.path:match("^(%S+) (%S+)$")
      if listName and not chosen[name] then
        table.insert(line.word == "missing" and missing or left, { list = listName, name = name })
      end
    end
  end
  local newlyHeld = #held > #(state.held or {})
  local incomingSettings = tonumber((log or ""):match("incoming%-settings (%d+)") or "0") or 0
  local newlyIncoming = #incoming > #(state.incoming or {}) or incomingSettings > (state.incomingSettings or 0)
  state.conflicts, state.held = conflicts, held
  state.incoming, state.incomingSettings = incoming, incomingSettings
  noctalia.writeFile(incomingFile, table.concat(incoming, "\n") .. "\n")
  if code == 0 then
    state.missing, state.left = missing, left
  end
  if #applied > 0 then
    noctalia.notify(noctalia.trp("notify.applied", #applied), table.concat(applied, "\n"))
  end
  local settingsTaken = tonumber((log or ""):match("settings applied (%d+)") or "0") or 0
  if settingsTaken > 0 then
    noctalia.notify(noctalia.trp("notify.settings", settingsTaken))
  end
  if newlyIncoming then
    noctalia.notify(noctalia.tr("notify.incoming"), table.concat(incoming, "\n"))
  end
  if newlyHeld then
    noctalia.notifyError(noctalia.tr("notify.held"), table.concat(held, "\n"))
  end
  if code == 0 then
    state.error = nil
    state.result = (log or ""):find("pushed") and "pushed"
      or (log or ""):find("unchanged") and "unchanged" or "saved"
  else
    -- Exit code 2 is a failed push: the snapshot itself is saved.
    state.result = code == 2 and "saved" or nil
    state.error = lastLine(log) or noctalia.tr("error.unknown")
    noctalia.notifyError(noctalia.tr("notify.failed"), state.error)
  end
  save()
  publish()
  if settingsTaken > 0 and lists() ~= runLists then
    saveAgain = true
  end
  if saveAgain then
    snapshot()
  end
end


-- Opens a terminal that installs every missing package, then saves again.
local function install()
  local lines = {}
  for _, package in ipairs(state.missing or {}) do
    table.insert(lines, package.list .. " " .. package.name)
  end
  if #lines == 0 then
    return
  end
  noctalia.mkdirAll(dataDir)
  noctalia.writeFile(installFile, table.concat(lines, "\n") .. "\n")
  local script = (noctalia.pluginDir() or "") .. "/install.sh"
  noctalia.runInTerminal("sh '" .. script:gsub("'", "'\\''") .. "' '" .. installFile:gsub("'", "'\\''") .. "'")
end

-- A path in single quotes, with any single quote in it closed and escaped.
local function quoted(path)
  return "'" .. path:gsub("'", "'\\''") .. "'"
end

-- Restores with the plugin's own restore.sh, not the repository's copy, which the remote
-- could have changed.
local function restore()
  if noctalia.fileExists(repo() .. "/restore.sh") then
    noctalia.runInTerminal("sh " .. quoted((noctalia.pluginDir() or "") .. "/restore.sh") .. " " .. quoted(repo()))
  end
end

-- Opens a terminal that shows what changed in each file and setting that waits.
local function changes()
  noctalia.runInTerminal("sh " .. quoted((noctalia.pluginDir() or "") .. "/changes.sh") .. " " .. quoted(repo())
    .. " " .. quoted(dataDir))
end

-- Opens a terminal that shows each save step waiting for approval and asks about it.
local function review()
  noctalia.runInTerminal("sh " .. quoted((noctalia.pluginDir() or "") .. "/review.sh") .. " " .. quoted(repo())
    .. " " .. quoted(approvedFile))
end

noctalia.state.watch("resurrect.command", function(command)
  if type(command) ~= "table" then
    return
  end
  if command.action == "save" then
    snapshot()
  elseif command.action == "resolve" and type(command.path) == "string"
    and (command.choice == "mine" or command.choice == "theirs") then
    -- The choice goes with the next save, which starts now or after the one running.
    choices[command.path] = command.choice
    saveSoon()
  elseif command.action == "settings" and (command.choice == "mine" or command.choice == "theirs") then
    settingsChoice = command.choice
    saveSoon()
  elseif command.action == "take_all" then
    for _, path in ipairs(state.incoming or {}) do
      choices[path] = "theirs"
    end
    if (state.incomingSettings or 0) > 0 then
      settingsChoice = "theirs"
    end
    saveSoon()
  elseif command.action == "changes" then
    changes()
  elseif command.action == "skip" and type(command.names) == "table" then
    -- Left off this device: gone from the list now, written to skip.txt with the next save.
    local leave = {}
    for _, name in ipairs(command.names) do
      if type(name) == "string" then
        table.insert(skips, name)
        leave[name] = true
      end
    end
    local kept = {}
    for _, package in ipairs(state.missing or {}) do
      if not leave[package.name] then
        table.insert(kept, package)
      end
    end
    state.missing = kept
    save()
    saveSoon()
  elseif (command.action == "again" or command.action == "only") and type(command.items) == "table" then
    -- Shared again or kept only here: gone from the list now, passed with the next save.
    local chosen = {}
    for _, item in ipairs(command.items) do
      if type(item) == "table" and type(item.list) == "string" and type(item.name) == "string" then
        table.insert(command.action == "again" and again or only, { list = item.list, name = item.name })
        chosen[item.list .. " " .. item.name] = true
      end
    end
    local kept = {}
    for _, item in ipairs(state.left or {}) do
      if not chosen[item.list .. " " .. item.name] then
        table.insert(kept, item)
      end
    end
    state.left = kept
    save()
    saveSoon()
  elseif command.action == "install" then
    install()
  elseif command.action == "review" then
    review()
  elseif command.action == "restore" then
    restore()
  elseif command.action == "open" and noctalia.commandExists("xdg-open") then
    noctalia.mkdirAll(repo())
    noctalia.runAsync({ "xdg-open", repo() })
  elseif command.action == "hooks" and noctalia.commandExists("xdg-open") then
    noctalia.mkdirAll(repo() .. "/hooks/save")
    noctalia.mkdirAll(repo() .. "/hooks/restore")
    noctalia.runAsync({ "xdg-open", repo() .. "/hooks" })
  end
  publish()
end)

-- noctalia msg plugin omerfuyar/resurrect:service all save
function onIpc(event)
  if event == "save" then
    snapshot()
  end
end

function update()
  if job then
    if job.waiting == "tick" then
      resume()
    end
    return
  end
  if noctalia.fileExists(restoreFile) then
    restoreSettings()
  elseif loaded and noctalia.getConfig("daily") ~= false
    and (state.lastMs == nil or noctalia.nowMs() - state.lastMs >= DAY_MS) then
    snapshot()
  end
end

function onConfigChanged()
  publish()
end

noctalia.readFileAsync(stateFile, function(text)
  local saved = text and noctalia.json.decode(text)
  if type(saved) == "table" then
    state = saved
  end
  state.runMs = nil
  state.conflicts = state.conflicts or {}
  state.held = state.held or {}
  state.incoming = state.incoming or {}
  state.incomingSettings = state.incomingSettings or 0
  state.missing = state.missing or {}
  state.left = state.left or {}
  -- Files of versions that saved with shell scripts.
  for _, name in ipairs({ "snapshot.log", "snapshot.exit", "resolve", "exclude", "again", "only" }) do
    noctalia.removeFile(dataDir .. "/" .. name)
  end
  loaded = true
  publish()
  noctalia.setUpdateInterval(IDLE_TICK_MS)
  -- Settings restore.sh left come first, so the save does not drop them.
  if noctalia.fileExists(restoreFile) then
    restoreSettings()
  elseif sharing() then
    -- With sharing on, what other devices changed comes in as soon as Noctalia starts.
    snapshot()
  end
end)
