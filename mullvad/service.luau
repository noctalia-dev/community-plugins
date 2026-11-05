--!nonstrict
-- Mullvad service - the only entry that runs `mullvad`.
--
--   noctalia.state.set("mullvad.state", snapshot)     bar and panel render this
--   noctalia.state.watch("mullvad.request", handler)  actions from bar/panel
--   noctalia msg plugin 3dprogramin/mullvad:service all request '<json>'   same, over IPC
--
-- State comes from three places:
--   * refreshAll(): every reader in READERS, in order, then one publish. Runs at
--     start, after every action, and on a 30 s poll (the backstop for changes made
--     outside the plugin and for the daemon stopping or starting).
--   * refreshAccount(): `account get` / `account list-devices` in a pass of their
--     own with its own publish. They reach Mullvad's API and can hang for their
--     whole timeout offline, so nothing else waits on them. They run at start, on a
--     refresh request (the panel opening), after an account action, and otherwise
--     at most every 10 minutes (the poll).
--   * `mullvad status listen`: each line re-reads the tunnel status at once. The
--     stream dies silently with the daemon (runStream has no close callback), so a
--     poll that finds the daemon running again restarts it.
--   * persisted data: the real (non-VPN) location, so "my country" works while
--     connected.
--
-- One action at a time: a request while another runs is refused with error.busy.
-- Detached launches (commands.detached: open_app) are the exception: they start a
-- program without waiting for it, never make the service busy, and run any time.
-- `requestSeq` in the snapshot goes up by one each time a request has been fully
-- handled (refused, or run and re-read), so a client can tell fresh state from old.
-- `serviceBootId` is unique per service start (a hot reload starts a new instance
-- with requestSeq back at 0), so a client holding an old requestSeq can tell a
-- reload from slow progress and stop waiting.
-- The UI always shows what the daemon reports after the action, never a guess.
--
-- The account number: `account get` prints it; the service keeps only
-- model.maskAccount() of it. A login request carries it into the argv and nowhere
-- else: the request is wiped from the "mullvad.request" channel on arrival, and
-- only model.scrub()bed stderr is ever logged or published.
--
-- Files: <pluginDataDir>/real-location.json is the only file written in normal use.
-- <pluginDataDir>/state.json (a scrubbed copy of every published snapshot, read by
-- tests/e2e-live.py) is written only while the marker file <pluginDataDir>/debug
-- exists: the snapshot holds the IP and location, so it is never left on disk
-- otherwise. The script creates the marker at its start and removes both files at
-- its end. The only read outside the data dir is the /usr/lib/modules check.

local parse = require("./parse.luau")
local model = require("./model.luau")
local relays = require("./relays.luau")
local commands = require("./commands.luau")

local TICK_MS = 1000
local POLL_TICKS = 30
local READ_TIMEOUT_MS = 15000
-- `relay list` is ~50 KB and changes rarely: read on start, then at most this often.
local RELAYS_MAX_AGE_MS = 6 * 3600 * 1000
-- `account get` / `account list-devices` ask Mullvad's API: the poll reads them at
-- most this often (see accountReadDue).
local ACCOUNT_MAX_AGE_MS = 10 * 60 * 1000
local LIST_DEVICES = { "mullvad", "account", "list-devices" }
local REQUEST_KEY = "mullvad.request"
-- A callback that never arrives (the callback itself failed) must not wedge the
-- service: busy is cleared this long after every step's timeout has passed.
local WATCHDOG_SLACK_MS = 5000
local REFRESH_STALE_MS = 120000
-- The host gives each callback 25 ms of CPU and marks a runtime unhealthy after a
-- few overruns, and Luau line parsing there costs ~40 us a line. Parsing the whole
-- relay list in one callback overruns it, so the service drops the relay-host
-- lines first (one C-level gsub; nothing here uses hostnames) and the parse yields
-- to a fresh callback (nextCallback) after this much time.
local SLICE_MS = 5
-- Read through readFileAsync only so its completion arrives as a new callback.
local YIELD_FILE = "plugin.toml"
-- A stream started this recently may not be visible in the process list yet.
local STREAM_SETTLE_MS = 5000
local LISTEN_CMD = "mullvad status listen"
local REAL_LOCATION_FILE = "real-location.json"
local DEBUG_FILE = "state.json"
local DEBUG_MARKER = "debug"

-- ── state ────────────────────────────────────────────────────────────────────

local daemon = "unknown" -- "running" | "down" | "unknown"
local bootEnabled = nil
local kernelRelease = nil
local kernelModulesPresent = nil
local tunnel = nil
local settings = nil -- { relay, lockdown, autoConnect }; nil until read, and while the daemon is down
local customListNames = nil -- parse.customListNames(); lets relay get recognise a custom list
-- { loggedIn, masked?, expiresAt?, expiry?, deviceName?, devices? }; nil until read,
-- and while the daemon is down. Never the account number itself.
local account = nil
-- The last `account get` failed or was unreadable (offline): the tab says so and
-- offers a retry instead of "reading" forever. account keeps its last value.
local accountReadFailed = false
local accountReadAtMs = nil
local accountDue = true -- the poll reads the account next time, whatever its age
local relayList = nil -- relays.parse() list with coordinates (no hostnames), for commands
local relaysForState = {} -- already scrubbed (see publish)
local relaysReadAtMs = nil
local realLocation = nil
local lastError = nil -- { key, detail? }
local requestSeq = 0
-- Start time + a random part + a table address: unique even for two loads in one ms.
local serviceBootId = tostring(noctalia.nowMs()) .. "-" .. tostring(math.random(0, 16777215)) .. "-" .. tostring({}):gsub("[^%w]", "")

local busy = false
local busyAction = nil
local busyDeadlineMs = nil
local actionId = 0 -- bumped per action; a late callback of an older one is ignored

local streamStarted = false -- since the daemon was last seen down
local streamStartedAtMs = nil
local ticks = 0
local TERMINAL_REFRESH_MS = 5000
local terminalRefreshAtMs = nil -- re-read the daemon once this time has passed
local tickQueue = {} -- nextCallback continuations the host refused; run from update()

-- ── helpers ──────────────────────────────────────────────────────────────────

local function dataFile(name)
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/" .. name
end

local function trim(text)
  return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

local function firstLine(result)
  for _, text in ipairs({ result.stderr, result.stdout }) do
    for line in tostring(text or ""):gmatch("[^\n]+") do
      local trimmed = trim(line)
      if trimmed ~= "" then
        return trimmed
      end
    end
  end
  return nil
end

local function log(message)
  noctalia.log("mullvad: " .. model.scrub(message))
end

-- runAsync returns false and never calls back when the process cannot start.
local function run(argv, timeoutMs, onResult)
  if noctalia.runAsync(argv, onResult, timeoutMs) == false then
    onResult({
      exitCode = 127, stdout = "", stderr = tostring(argv[1]) .. ": could not be started",
      timedOut = false, stdoutTruncated = false, stderrTruncated = false,
    })
  end
end

-- Runs fn in a fresh host callback, with its own CPU budget. Work too large for one
-- callback (parsing big CLI output) does a slice, then nextCallback(continue).
-- When the host refuses the read (it caps reads in flight), fn waits for the next
-- update() tick rather than running on in the current callback.
local function nextCallback(fn)
  local dir = noctalia.pluginDir()
  local path = dir and (dir .. "/" .. YIELD_FILE) or YIELD_FILE
  if noctalia.readFileAsync(path, function()
    fn()
  end) ~= true then
    tickQueue[#tickQueue + 1] = fn
  end
end

-- Copy with every string passed through model.scrub (account numbers -> '#').
local function scrubbed(value)
  local kind = type(value)
  if kind == "string" then
    return model.scrub(value)
  end
  if kind ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = scrubbed(v)
  end
  return out
end

-- ── publish ──────────────────────────────────────────────────────────────────

-- Every string is scrubbed. The relay list is scrubbed once when it is read: it is
-- the bulk of the snapshot, and publish runs on every `status listen` line.
local function publish()
  local snapshot = scrubbed({
    daemon = daemon,
    bootEnabled = bootEnabled,
    kernelModulesPresent = kernelModulesPresent,
    busy = busy,
    busyAction = busyAction,
    tunnel = tunnel,
    settings = settings,
    account = account,
    accountReadFailed = accountReadFailed,
    realLocation = realLocation,
    lastError = lastError,
    requestSeq = requestSeq,
    serviceBootId = serviceBootId,
  })
  snapshot.relays = relaysForState
  noctalia.state.set("mullvad.state", snapshot)
  -- One stat per publish (a few a minute) is far cheaper than the encode it saves,
  -- and checking every time means no write can follow the marker's removal.
  local marker = dataFile(DEBUG_MARKER)
  local path = dataFile(DEBUG_FILE)
  if marker ~= nil and path ~= nil and noctalia.fileExists(marker) == true then
    local encoded = noctalia.json.encode(snapshot, true)
    if encoded ~= nil then
      noctalia.writeFile(path, encoded)
    end
  end
end

-- ── real location ────────────────────────────────────────────────────────────

local function loadRealLocation()
  local path = dataFile(REAL_LOCATION_FILE)
  if path == nil or not noctalia.fileExists(path) then
    return nil
  end
  local text = noctalia.readFile(path)
  local decoded = text and noctalia.json.decode(text)
  if type(decoded) ~= "table" or type(decoded.country) ~= "string" or decoded.country == "" then
    return nil
  end
  return {
    country = decoded.country,
    latitude = type(decoded.latitude) == "number" and decoded.latitude or nil,
    longitude = type(decoded.longitude) == "number" and decoded.longitude or nil,
  }
end

-- Only a disconnected status off the VPN shows where the user really is.
local function rememberRealLocation(status)
  if status.state ~= "disconnected" or status.mullvadExit ~= false or status.country == nil then
    return
  end
  local seen = { country = status.country, latitude = status.latitude, longitude = status.longitude }
  if realLocation ~= nil and realLocation.country == seen.country
    and realLocation.latitude == seen.latitude and realLocation.longitude == seen.longitude then
    return
  end
  realLocation = seen
  local path = dataFile(REAL_LOCATION_FILE)
  local encoded = path and noctalia.json.encode(seen)
  if encoded ~= nil then
    noctalia.writeFile(path, encoded)
  end
end

-- relays.parse() one country block at a time, yielding between slices. Cities
-- come back with empty `hostnames`. done(list), or done(nil) when a slice failed.
local function parseRelaysSliced(raw, done)
  local text = string.gsub(raw, "\n\t\t[^\n]*", "")
  local list = {}
  local pos = 1
  local slice
  local function resume()
    local ok, err = pcall(slice)
    if not ok then
      log("relay list parse failed: " .. tostring(err))
      done(nil)
    end
  end
  slice = function()
    local started = noctalia.nowMs()
    while pos <= #text do
      -- A country header is a line that does not start with a tab.
      local nextHeader = string.find(text, "\n[^\t\n]", pos)
      local stop = nextHeader or #text
      for _, country in ipairs(relays.parse(string.sub(text, pos, stop))) do
        list[#list + 1] = country
      end
      pos = stop + 1
      if pos <= #text and noctalia.nowMs() - started >= SLICE_MS then
        return nextCallback(resume)
      end
    end
    done(list)
  end
  -- The gsub alone is a few ms: parse from a fresh callback.
  nextCallback(resume)
end

-- ── status stream ────────────────────────────────────────────────────────────

local refreshStatus -- forward

local function ensureStream()
  if streamStarted or daemon ~= "running" then
    return
  end
  streamStarted = noctalia.runStream(LISTEN_CMD, function()
    refreshStatus()
  end) == true
  streamStartedAtMs = noctalia.nowMs()
end

-- The stream also dies when the daemon restarts between two polls, which no
-- status read ever sees as "down". Each poll asks the host whether the process
-- is still there (processMatches: one command line containing the needle) and
-- restarts it if not.
local function checkStream()
  if not streamStarted or daemon ~= "running" then
    return
  end
  if streamStartedAtMs ~= nil and noctalia.nowMs() - streamStartedAtMs < STREAM_SETTLE_MS then
    return
  end
  noctalia.processMatches(function(running)
    if not running and streamStarted then
      log("status listen stream is gone; restarting it")
      streamStarted = false
      ensureStream()
    end
  end, LISTEN_CMD)
end

-- ── readers ──────────────────────────────────────────────────────────────────
--
-- Each reader is { argv, apply(result) | applyAsync(result, done), when?(), probe? }.
-- applyAsync is for work too big for one callback; it calls done() when finished.
-- A reader without argv runs apply() inline. While the daemon is down, the probe
-- (status) is the only `mullvad` reader that runs. Later tasks append to READERS.

local function applyStatus(result)
  if parse.isDaemonDown(result) then
    daemon = "down"
    tunnel = nil
    settings = nil
    customListNames = nil
    account = nil
    accountReadFailed = false
    accountDue = true
    streamStarted = false
    return
  end
  if result.exitCode ~= 0 or result.timedOut then
    return
  end
  local status = parse.status(noctalia.json.decode(result.stdout))
  if status == nil then
    return
  end
  daemon = "running"
  tunnel = status
  rememberRealLocation(status)
  ensureStream()
end

local STATUS_READER = { argv = { "mullvad", "status", "--json" }, probe = true, apply = applyStatus }

-- A settings reader: parse(stdout) goes into settings[field]. A failed read or
-- output that does not parse keeps the last value.
local function settingReader(argv, field, parseFn)
  return {
    argv = argv,
    apply = function(result)
      if result.exitCode ~= 0 or result.timedOut then
        return
      end
      local value = parseFn(result.stdout)
      if value == nil then
        return
      end
      settings = settings or {}
      settings[field] = value
    end,
  }
end

-- `account get`, then (logged in) `account list-devices`. A failed or unreadable
-- read keeps the last value. The parsed number is masked here and dropped.
local function applyAccount(result, done)
  if parse.isDaemonDown(result) then
    -- Not a read: leave the schedule alone so the next pass retries.
    return done()
  end
  accountDue = false
  accountReadAtMs = noctalia.nowMs()
  local parsed = nil
  if result.exitCode == 0 and not result.timedOut then
    parsed = parse.account(result.stdout)
  end
  accountReadFailed = parsed == nil
  if parsed == nil then
    return done()
  end
  if not parsed.loggedIn then
    account = { loggedIn = false }
    return done()
  end
  local fresh = {
    loggedIn = true,
    masked = model.maskAccount(parsed.number),
    expiresAt = parsed.expiresAt,
    expiry = model.expiryLevel(parsed.expiresAt, noctalia.nowMs() / 1000),
    deviceName = parsed.deviceName,
    devices = account and account.loggedIn and account.devices or nil,
  }
  parsed = nil
  run(LIST_DEVICES, READ_TIMEOUT_MS, function(devices)
    if devices.exitCode == 0 and not devices.timedOut then
      fresh.devices = parse.devices(devices.stdout) or fresh.devices
    end
    account = fresh
    done()
  end)
end

local ACCOUNT_READERS = { { argv = { "mullvad", "account", "get" }, applyAsync = applyAccount } }

local function accountReadDue()
  return accountDue or accountReadAtMs == nil or noctalia.nowMs() - accountReadAtMs >= ACCOUNT_MAX_AGE_MS
end

local READERS = {
  STATUS_READER,
  {
    argv = { "mullvad", "relay", "list" },
    when = function()
      return relaysReadAtMs == nil or noctalia.nowMs() - relaysReadAtMs >= RELAYS_MAX_AGE_MS
    end,
    applyAsync = function(result, done)
      if result.exitCode ~= 0 or result.timedOut then
        return done()
      end
      if result.stdoutTruncated then
        log("relay list output was truncated")
      end
      parseRelaysSliced(result.stdout, function(list)
        if list == nil then
          return done()
        end
        relayList = list
        relaysForState = scrubbed(relays.forState(list))
        -- An empty list (relays not downloaded yet) is retried on the next refresh.
        if #list > 0 then
          relaysReadAtMs = noctalia.nowMs()
        end
        done()
      end)
    end,
  },
  {
    -- Read before relay get: a custom-list constraint prints as the bare list name.
    argv = { "mullvad", "custom-list", "list" },
    apply = function(result)
      if result.exitCode == 0 and not result.timedOut then
        customListNames = parse.customListNames(result.stdout)
      end
    end,
  },
  settingReader({ "mullvad", "relay", "get" }, "relay", function(text)
    return parse.relayConstraints(text, customListNames)
  end),
  settingReader({ "mullvad", "lockdown-mode", "get" }, "lockdown", parse.onOff),
  settingReader({ "mullvad", "auto-connect", "get" }, "autoConnect", parse.onOff),
  {
    argv = { "systemctl", "is-enabled", "mullvad-daemon" },
    -- Only "disabled" offers Start at boot. Every other word (enabled, static,
    -- indirect, alias, generated, enabled-runtime, masked, …) means there is
    -- nothing to enable from here; no word (a timeout, a failed call) is unknown.
    -- `is-enabled` exits 1 for disabled, so the exit code is not the test.
    apply = function(result)
      local word = trim(result.stdout)
      if result.timedOut or word == "" then
        bootEnabled = nil
      else
        bootEnabled = word ~= "disabled"
      end
    end,
  },
  {
    argv = { "uname", "-r" },
    when = function()
      return kernelRelease == nil
    end,
    apply = function(result)
      local release = trim(result.stdout)
      if result.exitCode == 0 and release ~= "" then
        kernelRelease = release
      end
    end,
  },
  {
    -- A kernel upgraded without a reboot removes the running kernel's modules.
    apply = function()
      if kernelRelease ~= nil then
        kernelModulesPresent = noctalia.fileExists("/usr/lib/modules/" .. kernelRelease)
      end
    end,
  },
}

local function runReaders(list, done)
  local index = 0
  local function nextReader()
    index = index + 1
    local reader = list[index]
    if reader == nil then
      return done()
    end
    if reader.when ~= nil and not reader.when() then
      return nextReader()
    end
    local function applied(result)
      if reader.applyAsync ~= nil then
        local ok, err = pcall(reader.applyAsync, result, nextReader)
        if not ok then
          log("reader failed: " .. tostring(err))
          nextReader()
        end
        return
      end
      local ok, err = pcall(reader.apply, result)
      if not ok then
        log("reader failed: " .. tostring(err))
      end
      nextReader()
    end
    if reader.argv == nil then
      return applied(nil)
    end
    if daemon == "down" and reader.argv[1] == "mullvad" and not reader.probe then
      return nextReader()
    end
    run(reader.argv, READ_TIMEOUT_MS, applied)
  end
  nextReader()
end

-- A pass over a reader list, then one publish. Overlapping calls coalesce: one
-- more pass runs after the current one. after(), when given, runs just before the
-- publish of a pass that started after the call, so what it changes is published
-- together with freshly read state. A pass older than REFRESH_STALE_MS (a lost
-- callback) no longer blocks a new one.
local function coalescedPass(readers)
  local runningSinceMs = nil
  local queued = false
  local waiting = {}
  local pass
  pass = function(after)
    if runningSinceMs ~= nil and noctalia.nowMs() - runningSinceMs < REFRESH_STALE_MS then
      queued = true
      waiting[#waiting + 1] = after
      return
    end
    runningSinceMs = noctalia.nowMs()
    runReaders(readers, function()
      runningSinceMs = nil
      if after ~= nil then
        after()
      end
      publish()
      if queued then
        queued = false
        local fns = waiting
        waiting = {}
        pass(function()
          for _, fn in ipairs(fns) do
            fn()
          end
        end)
      end
    end)
  end
  return pass
end

local refreshAll = coalescedPass(READERS)
local refreshAccount = coalescedPass(ACCOUNT_READERS)
refreshStatus = coalescedPass({ STATUS_READER })

-- ── actions ──────────────────────────────────────────────────────────────────

local function handled()
  requestSeq = requestSeq + 1
end

local function context()
  return {
    relays = relayList,
    realLocation = realLocation,
    currentCountryCode = tunnel and tunnel.countryCode or nil,
    rand = math.random,
    account = account,
  }
end

local DAEMON_ACTIONS = { start_service = true, enable_service = true, restart_service = true }
local ACCOUNT_ACTIONS = { login = true, logout = true, revoke_device = true, redeem = true }

local function finishAction(id, err)
  if id ~= actionId then
    return
  end
  local name = busyAction
  busy = false
  busyAction = nil
  busyDeadlineMs = nil
  lastError = err
  if err ~= nil then
    log(err.key .. (err.detail and (": " .. err.detail) or ""))
  end
  if ACCOUNT_ACTIONS[name] then
    -- Handled once both the settings and the account re-reads have landed; the
    -- service is already free for the next action meanwhile.
    local pending = 2
    local function joined()
      pending = pending - 1
      if pending == 0 then
        handled()
      end
    end
    refreshAll(joined)
    refreshAccount(joined)
    return
  end
  if DAEMON_ACTIONS[name] then
    -- The daemon may be back: check the status stream now, not at the next poll.
    refreshAll(function()
      streamStartedAtMs = nil
      checkStream()
      handled()
    end)
    refreshAccount()
    return
  end
  refreshAll(handled)
end

local function runAction(request)
  local argvs, errKey = commands.build(request, context())
  if argvs == nil then
    lastError = { key = errKey }
    handled()
    publish()
    return
  end
  if #argvs == 0 then
    refreshAll(handled)
    return
  end

  actionId = actionId + 1
  local id = actionId
  local budget = WATCHDOG_SLACK_MS
  for _, argv in ipairs(argvs) do
    budget = budget + commands.timeoutMs(argv)
  end
  busy = true
  busyAction = request.action
  busyDeadlineMs = noctalia.nowMs() + budget
  lastError = nil
  publish()

  local index = 0
  local function step()
    index = index + 1
    local argv = argvs[index]
    if argv == nil then
      return finishAction(id, nil)
    end
    run(argv, commands.timeoutMs(argv), function(result)
      if id ~= actionId then
        return
      end
      if result.timedOut then
        return finishAction(id, { key = "error.timeout" })
      end
      if argv[1] == "pkexec" and result.exitCode ~= 0 then
        -- 127, or stderr naming the authentication agent: nothing could show a
        -- password prompt. 126: the prompt was dismissed or not authorized.
        local stderr = string.lower(result.stderr or "")
        if result.exitCode == 127 or string.find(stderr, "authentication agent", 1, true) ~= nil then
          return finishAction(id, { key = "error.no_polkit_agent", action = request.action })
        elseif result.exitCode == 126 then
          return finishAction(id, { key = "error.auth_cancelled" })
        end
      end
      if result.exitCode ~= 0 then
        local detail = model.scrub(firstLine(result) or "")
        return finishAction(id, { key = parse.commandError(result) or "error.command_failed", detail = detail })
      end
      step()
    end)
  end
  step()
end

-- Launches a program (the Mullvad app) without waiting for it. It does not touch
-- the daemon, so it runs even while an action is busy and is not re-read.
local function launchDetached(request)
  local argvs, errKey = commands.build(request, context())
  if argvs == nil then
    lastError = { key = errKey }
  else
    lastError = nil
    for _, argv in ipairs(argvs) do
      if noctalia.runAsync(argv) == false then
        lastError = { key = "error.command_failed", detail = tostring(argv[1]) .. ": could not be started" }
        log(lastError.key .. ": " .. lastError.detail)
        break
      end
    end
  end
  handled()
  publish()
end

-- Opens a terminal running the daemon command, for when no polkit agent can ask
-- for the password. The header is re-read once the user has had time to type it,
-- and the regular poll follows.
local function runInTerminal(request)
  local cmd, errKey = commands.terminalCommand(request)
  if cmd == nil then
    lastError = { key = errKey }
  elseif noctalia.runInTerminal(cmd) == false then
    lastError = { key = "error.command_failed", detail = "terminal: could not be started" }
    log(lastError.key .. ": " .. lastError.detail)
  else
    lastError = nil
    terminalRefreshAtMs = noctalia.nowMs() + TERMINAL_REFRESH_MS
  end
  handled()
  publish()
end

-- Turns on Noctalia's built-in polkit agent so pkexec can show a password prompt.
local function enablePolkitAgent(request)
  local argvs = commands.build(request, context())
  local argv = argvs[1]
  lastError = nil
  local started = noctalia.runAsync(argv, function(result)
    if result.exitCode == 0 and not result.timedOut then
      noctalia.notify(noctalia.tr("plugin.name"), noctalia.tr("notice.polkit_agent_on"))
    else
      lastError = { key = "error.command_failed", detail = model.scrub(firstLine(result) or "noctalia: config-set failed") }
      log(lastError.key .. ": " .. lastError.detail)
    end
    handled()
    publish()
  end, commands.timeoutMs(argv))
  if started == false then
    lastError = { key = "error.command_failed", detail = "noctalia: could not be started" }
    handled()
    publish()
  end
end

-- A login request holds the account number: take it off the shared channel at
-- once. Every set is queued to its watchers with its own value, so this cannot
-- swallow a request that came after it.
local function wipeLoginRequest()
  local stored = noctalia.state.get(REQUEST_KEY)
  if type(stored) == "table" and stored.action == "login" then
    noctalia.state.set(REQUEST_KEY, nil)
  end
end

local function handleRequest(request)
  if type(request) ~= "table" then
    return
  end
  if request.action == "login" then
    wipeLoginRequest()
  elseif request.action == "refresh" then
    -- Ruling R6: a refresh while busy runs nothing; the next poll reads the account.
    if busy then
      accountDue = true
    else
      refreshAccount()
    end
  elseif request.action == "dismiss_error" then
    -- The panel's dismiss button: clears the error the user saw (by key and detail; no key
    -- clears whatever is shown), never a newer one. Runs nothing, so it is allowed while busy.
    if lastError ~= nil and (request.key == nil or (request.key == lastError.key and request.detail == lastError.detail)) then
      lastError = nil
    end
    handled()
    publish()
    return
  end
  if commands.detached(request) then
    launchDetached(request)
    return
  end
  if busy then
    -- Ruling (Task 4 review): refresh is exempt from error.busy. The bar and panel
    -- send it on load, and a panel opened mid-action must not show a busy error.
    -- It only re-publishes the current snapshot: the running action's own re-read
    -- follows when it ends.
    if request.action ~= "refresh" then
      lastError = { key = "error.busy" }
    end
    handled()
    publish()
    return
  end
  if request.action == "run_in_terminal" then
    runInTerminal(request)
    return
  elseif request.action == "enable_polkit_agent" then
    enablePolkitAgent(request)
    return
  end
  runAction(request)
end

noctalia.state.watch(REQUEST_KEY, handleRequest)

function onIpc(event, payload)
  if event ~= "request" or type(payload) ~= "string" then
    return
  end
  local value = noctalia.json.decode(payload)
  if type(value) == "table" then
    handleRequest(value)
  end
end

function update()
  if busy and busyDeadlineMs ~= nil and noctalia.nowMs() > busyDeadlineMs then
    actionId = actionId + 1 -- orphan the lost callback
    busy = false
    busyAction = nil
    busyDeadlineMs = nil
    lastError = { key = "error.timeout" }
    log("action callback never arrived; busy cleared")
    refreshAll(handled)
  end
  if terminalRefreshAtMs ~= nil and not busy and noctalia.nowMs() >= terminalRefreshAtMs then
    terminalRefreshAtMs = nil
    refreshAll()
  end
  -- One refused continuation per tick, each with this tick's budget.
  local queued = table.remove(tickQueue, 1)
  if queued ~= nil then
    queued()
  end
  ticks = ticks + 1
  if ticks >= POLL_TICKS and not busy then
    ticks = 0
    checkStream()
    refreshAll()
    if daemon ~= "down" and accountReadDue() then
      refreshAccount()
    end
  end
end

noctalia.setUpdateInterval(TICK_MS)

realLocation = loadRealLocation()
log("service started, data dir " .. tostring((noctalia.pluginDataDir())))
publish()
refreshAll()
refreshAccount()
