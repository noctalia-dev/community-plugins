-- service.luau against the fake noctalia. Each test boots a fresh service.
local DIR = "/fake/plugin-data"
local SIXTEEN = string.rep("%d", 16)

local function queueStatus(fake, name)
  fake.queue({ "mullvad", "status", "--json" }, { stdout = fixture(name) })
end

local function queueDown(fake)
  fake.queue({ "mullvad", "status" }, { exitCode = 1, stderr = fixture("synthetic-daemon-down.txt") })
end

local function queueRelays(fake)
  fake.queue({ "mullvad", "relay", "list" }, { stdout = fixture("relay-list.txt") })
end

-- The settings readers (custom-list list, relay get, lockdown-mode get, auto-connect get).
local function queueSettings(f, relayFixture, lockdownFixture, autoText, relayText, listsText)
  f.queue({ "mullvad", "custom-list", "list" }, { stdout = listsText or fixture("custom-list-list-disconnected.txt") })
  f.queue({ "mullvad", "relay", "get" }, { stdout = relayText or fixture(relayFixture or "relay-get-disconnected.txt") })
  f.queue({ "mullvad", "lockdown-mode", "get" }, { stdout = fixture(lockdownFixture or "lockdown-mode-get-disconnected.txt") })
  f.queue({ "mullvad", "auto-connect", "get" }, { stdout = autoText or fixture("auto-connect-get-disconnected.txt") })
end

-- boot(setup) -> fake, with the service loaded and the fake installed as `noctalia`.
local current
local function boot(setup)
  if current then current.uninstall() end
  local fake = stubs.newNoctalia()
  if setup then setup(fake) end
  fake.install()
  loadFresh("service.luau")
  current = fake
  return fake
end

local function state(fake)
  return fake.state["mullvad.state"] or {}
end

local function send(fake, request)
  fake.noctalia.state.set("mullvad.request", request)
end

local function poll()
  for _ = 1, 30 do update() end
end

local function callsMatching(fake, prefix)
  local n = 0
  for _, call in ipairs(fake.calls) do
    local match = true
    for i, part in ipairs(prefix) do
      if call.argv[i] ~= part then match = false end
    end
    if match then n = n + 1 end
  end
  return n
end

local function indexOf(fake, joined, from)
  for i = from or 1, #fake.calls do
    if table.concat(fake.calls[i].argv, " ") == joined then return i end
  end
  return nil
end

local function bootRunning(extra)
  return boot(function(fake)
    queueStatus(fake, "status-disconnected.json")
    queueRelays(fake)
    if extra then extra(fake) end
  end)
end

-- refresh / daemon
local fake = boot(function(f) queueStatus(f, "status-disconnected.json") end)
eq("service: refresh publishes tunnel", state(fake).tunnel and state(fake).tunnel.state, "disconnected")
eq("service: daemon running after a status", state(fake).daemon, "running")
eq("service: not busy at start", state(fake).busy, false)
eq("service: polls on a 1 s tick", fake.updateInterval, 1000)
eq("service: settings unset until read", state(fake).settings, nil)
eq("service: account unset until read", state(fake).account, nil)

fake = boot(queueDown)
eq("service: daemon down publishes daemon=down", state(fake).daemon, "down")
eq("service: daemon down has no tunnel", state(fake).tunnel, nil)

fake = boot()
eq("service: daemon unknown when status fails otherwise", state(fake).daemon, "unknown")

-- readers
fake = bootRunning(function(f)
  f.queue({ "systemctl", "is-enabled", "mullvad-daemon" }, { exitCode = 1, stdout = "disabled\n" })
  f.queue({ "uname", "-r" }, { stdout = "7.2.14-zen1-1-zen\n" })
  f.files["/usr/lib/modules/7.2.14-zen1-1-zen"] = ""
end)
eq("service: bootEnabled false when disabled", state(fake).bootEnabled, false)
eq("service: kernel modules present", state(fake).kernelModulesPresent, true)
eq("service: relays published", #state(fake).relays, 50)
check("service: published relays carry no hostnames", state(fake).relays[1].cities[1].hostnames == nil)

fake = bootRunning(function(f)
  f.queue({ "systemctl", "is-enabled", "mullvad-daemon" }, { stdout = "enabled\n" })
  f.queue({ "uname", "-r" }, { stdout = "7.3.0-zen1-1-zen\n" })
end)
eq("service: bootEnabled true when enabled", state(fake).bootEnabled, true)
eq("service: kernel modules missing after an upgrade", state(fake).kernelModulesPresent, false)
queueStatus(fake, "status-disconnected.json")
poll()
eq("service: uname read once", callsMatching(fake, { "uname", "-r" }), 1)
eq("service: relay list not re-read every poll", callsMatching(fake, { "mullvad", "relay", "list" }), 1)
fake.advance(6 * 3600 * 1000)
queueStatus(fake, "status-disconnected.json")
queueRelays(fake)
poll()
eq("service: relay list re-read after 6 hours", callsMatching(fake, { "mullvad", "relay", "list" }), 2)

-- Only the word "disabled" offers Start at boot; a failed call is unknown (R6).
local function bootEnabledFor(result)
  local f = bootRunning(function(x) x.queue({ "systemctl", "is-enabled", "mullvad-daemon" }, result) end)
  return state(f).bootEnabled
end
for _, word in ipairs({ "static", "indirect", "alias", "generated", "enabled-runtime", "linked", "masked" }) do
  eq("service: is-enabled " .. word .. " is not disabled", bootEnabledFor({ exitCode = word == "masked" and 1 or 0, stdout = word .. "\n" }) ~= false, true)
end
eq("service: is-enabled static is true", bootEnabledFor({ stdout = "static\n" }), true)
eq("service: is-enabled disabled is false", bootEnabledFor({ exitCode = 1, stdout = "disabled\n" }), false)
eq("service: is-enabled timeout is unknown", bootEnabledFor({ timedOut = true, exitCode = 1, stdout = "" }), nil)
eq("service: is-enabled not started is unknown", bootEnabledFor({ exitCode = 127, stdout = "", stderr = "systemctl: could not be started" }), nil)
eq("service: is-enabled failure with no word is unknown",
  bootEnabledFor({ exitCode = 1, stdout = "", stderr = "Failed to get unit file state for mullvad-daemon.service\n" }), nil)

fake = bootRunning()
local before = #fake.calls
for _ = 1, 29 do update() end
eq("service: no poll before 30 ticks", #fake.calls, before)
update()
check("service: poll on the 30th tick", callsMatching(fake, { "mullvad", "status", "--json" }) == 2)

-- connect
fake = bootRunning(function(f)
  f.queue({ "mullvad", "relay", "set", "location" }, {})
  f.queue({ "mullvad", "connect" }, {})
  queueSettings(f)
  f.queue({ "mullvad", "account", "get" }, { stdout = fixture("synthetic-account-logged-out.txt") })
end)
local start = #fake.calls
queueStatus(fake, "status-connected.json")
queueSettings(fake)
send(fake, { action = "connect", mode = "country", country = "se", city = "got" })
local setAt = indexOf(fake, "mullvad relay set location se got", start + 1)
local connectAt = setAt and indexOf(fake, "mullvad connect", setAt + 1)
local statusAt = connectAt and indexOf(fake, "mullvad status --json", connectAt + 1)
check("service: connect runs set-location then connect", setAt ~= nil and connectAt == setAt + 1)
check("service: connect re-reads status afterwards", statusAt ~= nil)
eq("service: connect gets a 30 s timeout", connectAt and fake.calls[connectAt].timeoutMs, 30000)
eq("service: set location gets a 15 s timeout", setAt and fake.calls[setAt].timeoutMs, 15000)
eq("service: state shows the re-read tunnel", state(fake).tunnel.state, "connected")
eq("service: busy cleared after connect", state(fake).busy, false)
eq("service: no error after connect", state(fake).lastError, nil)
local unmatchedMullvad = 0
for _, call in ipairs(fake.unmatched) do
  if call.argv[1] == "mullvad" then unmatchedMullvad = unmatchedMullvad + 1 end
end
eq("service: no unmatched mullvad calls during connect", unmatchedMullvad, 0)

-- a failure stops the sequence
fake = bootRunning(function(f)
  f.queue({ "mullvad", "relay", "set", "location" }, { exitCode = 1, stderr = "Error: bad location\nmore\n" })
end)
send(fake, { action = "connect", mode = "country", country = "se" })
eq("service: failed step stops the sequence", callsMatching(fake, { "mullvad", "connect" }), 0)
eq("service: failure sets command_failed", state(fake).lastError and state(fake).lastError.key, "error.command_failed")
eq("service: failure detail is stderr's first line", state(fake).lastError and state(fake).lastError.detail, "Error: bad location")

-- validation errors run nothing
fake = bootRunning()
start = #fake.calls
send(fake, { action = "connect", mode = "country", country = "xx" })
eq("service: unknown location runs nothing", #fake.calls, start)
eq("service: unknown location error", state(fake).lastError and state(fake).lastError.key, "error.unknown_location")
send(fake, { action = "format_disk" })
eq("service: unknown action runs nothing", #fake.calls, start)
eq("service: unknown action error", state(fake).lastError and state(fake).lastError.key, "error.unknown_action")
send(fake, "not a table")
eq("service: non-table request ignored", #fake.calls, start)

-- busy
fake = bootRunning(function(f)
  f.queue({ "mullvad", "relay", "set", "location" }, { defer = true })
end)
send(fake, { action = "connect", mode = "country", country = "se" })
eq("service: busy while an action runs", state(fake).busy, true)
eq("service: busyAction names the action", state(fake).busyAction, "connect")
local inFlight = #fake.calls
send(fake, { action = "disconnect" })
eq("service: second request while busy is rejected", state(fake).lastError and state(fake).lastError.key, "error.busy")
eq("service: rejected request runs nothing", #fake.calls, inFlight)
local polledWhileBusy = #fake.calls
poll()
eq("service: no poll while busy", #fake.calls, polledWhileBusy)
fake.queue({ "mullvad", "connect" }, {})
queueStatus(fake, "status-connected.json")
fake.flush()
eq("service: busy clears when the action ends", state(fake).busy, false)
eq("service: busyAction cleared", state(fake).busyAction, nil)
eq("service: a finished action clears the busy error", state(fake).lastError, nil)

-- open_app: a detached launch, never busy, no callback
fake = bootRunning()
start = #fake.calls
local seqBeforeApp = state(fake).requestSeq
send(fake, { action = "open_app" })
local launch = fake.calls[start + 1]
eq("service: open_app launches mullvad-vpn", launch and table.concat(launch.argv, " "), "mullvad-vpn")
eq("service: open_app launch is detached", launch and launch.hasCallback, false)
eq("service: open_app runs only the launch", #fake.calls, start + 1)
eq("service: open_app is not busy", state(fake).busy, false)
eq("service: open_app clears lastError", state(fake).lastError, nil)
eq("service: open_app counts as handled", state(fake).requestSeq, seqBeforeApp + 1)

fake = bootRunning(function(f)
  f.queue({ "mullvad", "relay", "set", "location" }, { defer = true })
end)
send(fake, { action = "connect", mode = "country", country = "se" })
start = #fake.calls
send(fake, { action = "open_app" })
eq("service: open_app runs while busy", fake.calls[start + 1] and fake.calls[start + 1].argv[1], "mullvad-vpn")
eq("service: open_app while busy is not a busy error", state(fake).lastError, nil)
eq("service: open_app leaves the running action busy", state(fake).busy, true)

fake = bootRunning()
fake.noctalia.runAsync = function() return false end
send(fake, { action = "open_app" })
eq("service: open_app that cannot start is an error",
  state(fake).lastError and state(fake).lastError.key, "error.command_failed")

-- refresh while busy (ruling: exempt from error.busy) re-publishes and runs nothing
fake = bootRunning(function(f)
  f.queue({ "mullvad", "relay", "set", "location" }, { defer = true })
end)
send(fake, { action = "connect", mode = "country", country = "se" })
eq("service: busy before the refresh", state(fake).busy, true)
eq("service: no error before the refresh", state(fake).lastError, nil)
local callsBefore, seqBefore = #fake.calls, state(fake).requestSeq
fake.state["mullvad.state"] = nil
send(fake, { action = "refresh" })
check("service: refresh while busy re-publishes", fake.state["mullvad.state"] ~= nil)
eq("service: refresh while busy is not an error", state(fake).lastError, nil)
eq("service: refresh while busy runs no command", #fake.calls, callsBefore)
eq("service: refresh while busy keeps busy", state(fake).busy, true)
eq("service: refresh while busy counts as handled", state(fake).requestSeq, seqBefore + 1)

-- serviceBootId: unique per service start, so clients notice a hot reload
local bootA = bootRunning()
local bootB = bootRunning(function(f) f.files[DIR .. "/debug"] = "" end)
local idA, idB = state(bootA).serviceBootId, state(bootB).serviceBootId
check("service: snapshot carries serviceBootId", type(idA) == "string" and idA ~= "")
check("service: serviceBootId differs between two loads", idA ~= idB)
check("service: state.json carries serviceBootId", (bootB.files[DIR .. "/state.json"] or ""):find('"serviceBootId"', 1, true) ~= nil)

-- requestSeq: bumped once a request is fully handled
fake = bootRunning(function(f) f.files[DIR .. "/debug"] = "" end)
eq("service: requestSeq starts at 0", state(fake).requestSeq, 0)
check("service: state.json carries requestSeq", (fake.files[DIR .. "/state.json"] or ""):find('"requestSeq"', 1, true) ~= nil)
queueStatus(fake, "status-disconnected.json")
send(fake, { action = "refresh" })
eq("service: refresh bumps requestSeq", state(fake).requestSeq, 1)
send(fake, { action = "connect", mode = "country", country = "xx" })
eq("service: refused request bumps requestSeq", state(fake).requestSeq, 2)
poll()
eq("service: a poll does not bump requestSeq", state(fake).requestSeq, 2)
fake.queue({ "mullvad", "disconnect" }, { defer = true })
send(fake, { action = "disconnect" })
eq("service: running action has not bumped yet", state(fake).requestSeq, 2)
fake.queue({ "mullvad", "status", "--json" }, { defer = true, stdout = fixture("status-connected.json") })
fake.flush() -- disconnect ends; its re-read is now in flight
eq("service: old snapshot stands until the re-read lands", state(fake).tunnel.state, "disconnected")
eq("service: no bump until the re-read lands", state(fake).requestSeq, 2)
fake.flush()
eq("service: finished action bumps requestSeq", state(fake).requestSeq, 3)
eq("service: bump published with the re-read", state(fake).tunnel.state, "connected")

-- timeout
fake = bootRunning(function(f)
  f.queue({ "mullvad", "disconnect" }, { exitCode = -1, timedOut = true })
end)
send(fake, { action = "disconnect" })
eq("service: timeout clears busy", state(fake).busy, false)
eq("service: timeout error", state(fake).lastError and state(fake).lastError.key, "error.timeout")
eq("service: disconnect gets a 30 s timeout", fake.calls[indexOf(fake, "mullvad disconnect")].timeoutMs, 30000)
queueStatus(fake, "status-disconnected.json")
local afterTimeout = callsMatching(fake, { "mullvad", "status", "--json" })
poll()
eq("service: next poll still runs after a timeout", callsMatching(fake, { "mullvad", "status", "--json" }), afterTimeout + 1)

-- a callback that never fires still frees the service
fake = bootRunning(function(f)
  f.queue({ "mullvad", "disconnect" }, { defer = true })
end)
send(fake, { action = "disconnect" })
fake.advance(40000)
update()
eq("service: lost callback clears busy", state(fake).busy, false)
eq("service: lost callback reports a timeout", state(fake).lastError and state(fake).lastError.key, "error.timeout")

-- refresh / reconnect / ipc
fake = bootRunning()
start = callsMatching(fake, { "mullvad", "status", "--json" })
queueStatus(fake, "status-connected.json")
send(fake, { action = "refresh" })
eq("service: refresh re-reads status", callsMatching(fake, { "mullvad", "status", "--json" }), start + 1)
fake.queue({ "mullvad", "reconnect" }, {})
send(fake, { action = "reconnect" })
eq("service: reconnect runs", callsMatching(fake, { "mullvad", "reconnect" }), 1)
fake.queue({ "mullvad", "disconnect" }, {})
onIpc("request", '{"action":"disconnect"}')
eq("service: ipc request runs", callsMatching(fake, { "mullvad", "disconnect" }), 1)
local ipcCalls = #fake.calls
onIpc("request", "{broken")
onIpc("other", '{"action":"disconnect"}')
eq("service: bad ipc ignored", #fake.calls, ipcCalls)

-- status listen
fake = bootRunning()
eq("service: listen stream started", #fake.runStreams, 1)
eq("service: listen command", fake.runStreams[1] and fake.runStreams[1].cmd, "mullvad status listen")
local statusCalls = callsMatching(fake, { "mullvad", "status", "--json" })
queueStatus(fake, "status-connected.json")
fake.runStreams[1].onLine("Connected to se-sto-wg-011")
eq("service: listen line triggers refresh", callsMatching(fake, { "mullvad", "status", "--json" }), statusCalls + 1)
eq("service: listen refresh publishes", state(fake).tunnel.state, "connected")

fake = bootRunning()
queueDown(fake)
poll()
eq("service: down poll keeps one stream", #fake.runStreams, 1)
eq("service: down poll publishes down", state(fake).daemon, "down")
queueStatus(fake, "status-disconnected.json")
poll()
eq("service: stream restarts after daemon returns", #fake.runStreams, 2)
queueStatus(fake, "status-disconnected.json")
poll()
eq("service: stream not restarted while running", #fake.runStreams, 2)

fake = bootRunning()
fake.kill("mullvad status listen") -- daemon restarted between polls: the stream died, status never read down
fake.advance(30000)
queueStatus(fake, "status-disconnected.json")
poll()
eq("service: dead stream restarted on the next poll", #fake.runStreams, 2)
fake.advance(30000)
queueStatus(fake, "status-disconnected.json")
poll()
eq("service: live stream left alone", #fake.runStreams, 2)

fake = bootRunning()
fake.kill("mullvad status listen")
queueStatus(fake, "status-disconnected.json")
poll()
eq("service: a just-started stream is not second-guessed", #fake.runStreams, 1)

-- real location
fake = bootRunning()
local saved = fake.files[DIR .. "/real-location.json"]
check("service: real location persisted only when not on VPN", saved ~= nil and saved:find("Romania", 1, true) ~= nil)
eq("service: realLocation published", state(fake).realLocation and state(fake).realLocation.country, "Romania")
queueStatus(fake, "status-connected.json")
poll()
saved = fake.files[DIR .. "/real-location.json"]
check("service: connected status does not overwrite real location", saved and saved:find("Romania", 1, true) ~= nil and not saved:find("Sweden", 1, true))
eq("service: realLocation kept while connected", state(fake).realLocation.country, "Romania")

fake = boot(function(f)
  f.files[DIR .. "/real-location.json"] = '{"country":"Romania","latitude":44.4,"longitude":26.1}'
  queueStatus(f, "status-disconnected-nolocation.json")
end)
eq("service: real location loaded from disk", state(fake).realLocation and state(fake).realLocation.country, "Romania")

-- debug snapshot (R30): state.json holds the IP and location, so it is written only
-- while the live-check script's marker file <data dir>/debug exists.
fake = bootRunning(function(f)
  f.queue({ "mullvad", "disconnect" }, {})
end)
queueStatus(fake, "status-disconnected.json")
send(fake, { action = "disconnect" })
check("debug: no marker, no state.json", fake.files[DIR .. "/state.json"] == nil)
check("debug: no marker still publishes", state(fake).tunnel ~= nil and state(fake).requestSeq == 1)
fake.files[DIR .. "/debug"] = ""
queueStatus(fake, "status-disconnected.json")
send(fake, { action = "refresh" })
check("debug: a marker created later turns the dump on", fake.files[DIR .. "/state.json"] ~= nil)
fake.files[DIR .. "/debug"] = nil
fake.files[DIR .. "/state.json"] = nil
queueStatus(fake, "status-disconnected.json")
send(fake, { action = "refresh" })
check("debug: marker removed, no more writes", fake.files[DIR .. "/state.json"] == nil)

-- debug snapshot and scrubbing
fake = bootRunning(function(f)
  f.files[DIR .. "/debug"] = ""
  f.queue({ "mullvad", "disconnect" }, { exitCode = 1, stderr = "Error: account 1234567890123456 is invalid\n" })
end)
send(fake, { action = "disconnect" })
local encoded = json.encode(state(fake))
check("service: snapshot never contains 16-digit runs", encoded ~= nil and encoded:find(SIXTEEN) == nil)
check("service: scrubbed detail kept", state(fake).lastError.detail:find("################", 1, true) ~= nil)
local dumped = fake.files[DIR .. "/state.json"]
check("service: state.json written", dumped ~= nil)
check("service: state.json never contains 16-digit runs", dumped and dumped:find(SIXTEEN) == nil)
local decoded = dumped and json.decode(dumped)
eq("service: state.json mirrors the snapshot", decoded and decoded.daemon, "running")
local leaked = false
for _, line in ipairs(fake.logs) do
  if line:find(SIXTEEN) then leaked = true end
end
check("service: failure was logged", #fake.logs > 1)
check("service: logs never contain 16-digit runs", not leaked)

-- the relay list parse yields between slices (the host's per-callback CPU budget)
fake = boot(function(f)
  queueStatus(f, "status-disconnected.json")
  queueRelays(f)
  f.noctalia.nowMs = function()
    f.now = f.now + 3
    return f.now
  end
end)
check("service: relay parse yields across callbacks", #fake.fileReads > 1)
eq("service: yielding spawns no process", callsMatching(fake, { "true" }), 0)
eq("service: sliced parse keeps every country", #state(fake).relays, 50)
local whole = loadModule("relays.luau").parse(fixture("relay-list.txt"))
local same = #whole == #state(fake).relays
for i, c in ipairs(whole) do
  local got = state(fake).relays[i]
  if not got or got.code ~= c.code or #got.cities ~= #c.cities then same = false end
end
check("service: sliced parse matches a whole parse", same)

-- a refused yield waits for the next update() tick instead of running on
fake = boot(function(f)
  queueStatus(f, "status-disconnected.json")
  queueRelays(f)
  f.refuseFileReads = true
  f.noctalia.nowMs = function()
    f.now = f.now + 3
    return f.now
  end
end)
eq("service: refused yield does not continue in the same callback", #state(fake).relays, 0)
local ticksUsed = 0
while #state(fake).relays == 0 and ticksUsed < 200 do
  update()
  ticksUsed = ticksUsed + 1
end
eq("service: refused yields resume on ticks", #state(fake).relays, 50)
check("service: one slice per tick", ticksUsed > 1)

-- settings readers (Task 7): relay constraints, lockdown, auto-connect
fake = bootRunning(function(f) queueSettings(f) end)
local settings = state(fake).settings or {}
eq("service: settings.relay read", settings.relay and settings.relay.location.country, "ro")
eq("service: settings.relay.multihop", settings.relay and settings.relay.multihop, false)
eq("service: settings.relay.entry", settings.relay and settings.relay.entry.country, "se")
eq("service: settings.lockdown", settings.lockdown, false)
eq("service: settings.autoConnect", settings.autoConnect, false)

fake.queue({ "mullvad", "relay", "set", "multihop" }, {})
queueStatus(fake, "status-disconnected.json")
queueSettings(fake, "relay-get-multihop-on.txt", "synthetic-lockdown-mode-get-on.txt", "Autoconnect: on\n")
start = #fake.calls
send(fake, { action = "set_multihop", on = true })
local setMultihop = indexOf(fake, "mullvad relay set multihop on", start + 1)
check("service: set_multihop runs its argv", setMultihop ~= nil)
check("service: set_multihop re-reads relay get", setMultihop and indexOf(fake, "mullvad relay get", setMultihop + 1) ~= nil)
settings = state(fake).settings or {}
eq("service: re-read multihop shown", settings.relay and settings.relay.multihop, true)
eq("service: re-read lockdown shown", settings.lockdown, true)
eq("service: re-read auto-connect shown", settings.autoConnect, true)

-- a failed settings read keeps the last value; daemon down drops them
queueStatus(fake, "status-disconnected.json")
fake.queue({ "mullvad", "relay", "get" }, { exitCode = 1, stderr = "boom" })
fake.queue({ "mullvad", "lockdown-mode", "get" }, { exitCode = 1, stderr = "boom" })
fake.queue({ "mullvad", "auto-connect", "get" }, { stdout = "garbage" })
poll()
settings = state(fake).settings or {}
eq("service: failed relay read keeps the last value", settings.relay and settings.relay.multihop, true)
eq("service: failed lockdown read keeps the last value", settings.lockdown, true)
eq("service: unparsable auto-connect keeps the last value", settings.autoConnect, true)
queueDown(fake)
poll()
eq("service: daemon down drops settings", state(fake).settings, nil)
eq("service: daemon down skips the settings readers", callsMatching(fake, { "mullvad", "relay", "get" }), 3)

-- a custom-list constraint is recognised only by a name from custom-list list
local listRelay = "Generic constraints\n    Location:               my servers\nWireGuard constraints\n"
  .. "    Multihop state:         disabled\n    Multihop entry:         country se\n"
local lf = bootRunning(function(f) queueSettings(f, nil, nil, nil, listRelay, "my servers\n\tSweden (se)\n") end)
local loc = (state(lf).settings or {}).relay
eq("service: custom list read from custom-list list", loc and loc.location.kind .. ":" .. tostring(loc.location.list),
  "custom_list:my servers")
check("service: custom-list list read before relay get",
  (indexOf(lf, "mullvad custom-list list") or 99) < (indexOf(lf, "mullvad relay get") or 0))
lf = bootRunning(function(f)
  f.queue({ "mullvad", "custom-list", "list" }, { exitCode = 1, stderr = "boom" })
  f.queue({ "mullvad", "relay", "get" }, { stdout = listRelay })
end)
loc = (state(lf).settings or {}).relay
eq("service: no list names, a bare name is unknown", loc and loc.location.kind, "unknown")

current.uninstall()

-- daemon control (Task 14)
fake = bootRunning(function(f)
  f.queue({ "pkexec", "systemctl", "enable" }, { exitCode = 126, stderr = "Error: Not authorized\n" })
end)
send(fake, { action = "start_service" })
eq("service: pkexec 126 gives auth_cancelled", state(fake).lastError and state(fake).lastError.key, "error.auth_cancelled")
fake = bootRunning(function(f)
  f.queue({ "pkexec", "systemctl", "restart" }, { exitCode = 127, stderr = "" })
end)
send(fake, { action = "restart_service" })
eq("service: pkexec 127 without stderr gives no_polkit_agent", state(fake).lastError and state(fake).lastError.key, "error.no_polkit_agent")
fake = bootRunning(function(f)
  f.queue({ "pkexec", "systemctl", "restart" }, { exitCode = 1, stderr = "Failed to restart mullvad-daemon.service\nmore\n" })
end)
send(fake, { action = "restart_service" })
eq("service: other pkexec failure is command_failed", state(fake).lastError and state(fake).lastError.key, "error.command_failed")
eq("service: failure detail is stderr's first line", state(fake).lastError and state(fake).lastError.detail, "Failed to restart mullvad-daemon.service")
fake = bootRunning(function(f)
  f.queue({ "pkexec", "systemctl", "enable" }, {})
end)
local before = callsMatching(fake, { "mullvad", "status", "--json" })
send(fake, { action = "enable_service" })
eq("service: enable_service has no error", state(fake).lastError, nil)
check("service: enable_service re-reads status", callsMatching(fake, { "mullvad", "status", "--json" }) > before)
eq("service: enable_service ran pkexec once", callsMatching(fake, { "pkexec", "systemctl", "enable", "--now", "mullvad-daemon" }), 1)

-- headline path: daemon down -> start_service -> pkexec -> re-read -> stream restarted at once
fake = boot(queueDown)
eq("service: start path begins with the daemon down", state(fake).daemon, "down")
eq("service: no stream while the daemon is down", #fake.runStreams, 0)
fake.queue({ "pkexec", "systemctl", "enable", "--now", "mullvad-daemon" }, {})
queueStatus(fake, "status-disconnected.json")
queueRelays(fake)
send(fake, { action = "start_service" })
check("service: start_service ran pkexec",
  callsMatching(fake, { "pkexec", "systemctl", "enable", "--now", "mullvad-daemon" }) == 1)
eq("service: start_service no error", state(fake).lastError, nil)
eq("service: daemon running after start_service", state(fake).daemon, "running")
eq("service: stream restarted without waiting for a poll", #fake.runStreams, 1)
eq("service: restarted stream is status listen", fake.runStreams[1] and fake.runStreams[1].cmd, "mullvad status listen")

-- a second request while start_service runs is busy
fake = boot(queueDown)
fake.queue({ "pkexec", "systemctl", "enable" }, { defer = true })
send(fake, { action = "start_service" })
eq("service: start_service holds the busy slot", state(fake).busyAction, "start_service")
send(fake, { action = "restart_service" })
eq("service: request during start_service is busy", state(fake).lastError and state(fake).lastError.key, "error.busy")
eq("service: busy request ran no second pkexec", callsMatching(fake, { "pkexec" }), 1)

-- auth_cancelled now means only a dismissed prompt
local catalog = json.decode(io.open("mullvad/translations/en.json"):read("a"))
check("service: auth_cancelled text mentions the prompt being cancelled",
  catalog.error.auth_cancelled:find("prompt was cancelled", 1, true) ~= nil)

-- no polkit agent (Task 14c)
local AGENT_STDERR = "Error creating textual authentication agent: Error opening current controlling terminal for the process (`/dev/tty'): No such device or address\n"
fake = bootRunning(function(f)
  f.queue({ "pkexec", "systemctl", "enable" }, { exitCode = 127, stderr = AGENT_STDERR })
end)
send(fake, { action = "start_service" })
eq("service: pkexec 127 with the agent error gives no_polkit_agent", state(fake).lastError and state(fake).lastError.key, "error.no_polkit_agent")
eq("service: no_polkit_agent records the failed action", state(fake).lastError and state(fake).lastError.action, "start_service")
fake = bootRunning(function(f)
  f.queue({ "pkexec", "systemctl", "restart" }, { exitCode = 1, stderr = "Some Authentication Agent problem\n" })
end)
send(fake, { action = "restart_service" })
eq("service: stderr naming the authentication agent gives no_polkit_agent", state(fake).lastError and state(fake).lastError.key, "error.no_polkit_agent")
eq("service: restart failure recorded", state(fake).lastError and state(fake).lastError.action, "restart_service")

fake = bootRunning()
send(fake, { action = "run_in_terminal", ["for"] = "start_service" })
eq("service: run_in_terminal start runs once", #fake.terminalCalls, 1)
eq("service: run_in_terminal start command", fake.terminalCalls[1], "sudo systemctl enable --now mullvad-daemon")
send(fake, { action = "run_in_terminal", ["for"] = "enable_service" })
eq("service: run_in_terminal enable command", fake.terminalCalls[2], "sudo systemctl enable --now mullvad-daemon")
send(fake, { action = "run_in_terminal", ["for"] = "restart_service" })
eq("service: run_in_terminal restart command", fake.terminalCalls[3], "sudo systemctl restart mullvad-daemon")
local statusBefore = callsMatching(fake, { "mullvad", "status", "--json" })
fake.advance(5000)
update()
check("service: refreshes about 5 s after the terminal opens", callsMatching(fake, { "mullvad", "status", "--json" }) > statusBefore)
send(fake, { action = "run_in_terminal", ["for"] = "rm -rf /" })
eq("service: unknown for gives unknown_action", state(fake).lastError and state(fake).lastError.key, "error.unknown_action")
eq("service: unknown for runs no terminal", #fake.terminalCalls, 3)
send(fake, { action = "run_in_terminal" })
eq("service: missing for gives unknown_action", state(fake).lastError and state(fake).lastError.key, "error.unknown_action")
eq("service: missing for runs no terminal", #fake.terminalCalls, 3)

fake = bootRunning(function(f)
  f.queue({ "noctalia", "msg", "config-set" }, {})
end)
send(fake, { action = "enable_polkit_agent" })
eq("service: enable_polkit_agent ran config-set once",
  callsMatching(fake, { "noctalia", "msg", "config-set", "shell.polkit_agent", "true" }), 1)
check("service: enable_polkit_agent shows a notice", #fake.notifications == 1 and fake.notifications[1].error == false)
eq("service: enable_polkit_agent no error", state(fake).lastError, nil)
fake = bootRunning(function(f)
  f.queue({ "noctalia", "msg", "config-set" }, { exitCode = 1, stderr = "bad" })
end)
send(fake, { action = "enable_polkit_agent" })
eq("service: failed config-set is command_failed", state(fake).lastError and state(fake).lastError.key, "error.command_failed")
eq("service: failed config-set gives no success notice", #fake.notifications, 0)

-- the polkit fallbacks obey the busy gate (review fix)
fake = boot(queueDown)
fake.queue({ "pkexec", "systemctl", "enable" }, { defer = true })
send(fake, { action = "start_service" })
local callsBusy = #fake.calls
send(fake, { action = "run_in_terminal", ["for"] = "start_service" })
eq("service: run_in_terminal while busy is busy", state(fake).lastError and state(fake).lastError.key, "error.busy")
eq("service: run_in_terminal while busy runs no terminal", #fake.terminalCalls, 0)
send(fake, { action = "enable_polkit_agent" })
eq("service: enable_polkit_agent while busy is busy", state(fake).lastError and state(fake).lastError.key, "error.busy")
eq("service: enable_polkit_agent while busy runs nothing", #fake.calls, callsBusy)

-- launch failures
fake = bootRunning()
fake.terminalFails = true
send(fake, { action = "run_in_terminal", ["for"] = "restart_service" })
eq("service: terminal launch failure is command_failed", state(fake).lastError and state(fake).lastError.key, "error.command_failed")
fake = bootRunning()
local realRun = fake.noctalia.runAsync
fake.noctalia.runAsync = function(argv, cb, t)
  if argv[1] == "noctalia" then return false end
  return realRun(argv, cb, t)
end
send(fake, { action = "enable_polkit_agent" })
eq("service: agent launch failure is command_failed", state(fake).lastError and state(fake).lastError.key, "error.command_failed")
eq("service: agent launch failure gives no success notice", #fake.notifications, 0)

-- the delayed refresh waits while busy
fake = bootRunning()
send(fake, { action = "run_in_terminal", ["for"] = "start_service" })
fake.queue({ "pkexec", "systemctl", "enable" }, { defer = true })
send(fake, { action = "start_service" })
fake.advance(6000)
local sBusy = callsMatching(fake, { "mullvad", "status", "--json" })
update()
eq("service: delayed refresh waits while busy", callsMatching(fake, { "mullvad", "status", "--json" }), sBusy)
fake.flush()
local sIdle = callsMatching(fake, { "mullvad", "status", "--json" })
update()
check("service: delayed refresh fires once idle", callsMatching(fake, { "mullvad", "status", "--json" }) > sIdle)

local manifest = io.open("mullvad/plugin.toml"):read("a")
check("manifest: depends on noctalia", manifest:find('"noctalia"', 1, true) ~= nil)
check("catalog: no_polkit_agent text", type(catalog.error.no_polkit_agent) == "string")
check("catalog: polkit actions", catalog.error.action.run_in_terminal == "Run in terminal" and catalog.error.action.enable_polkit_agent == "Turn on password prompt")
check("catalog: polkit notice", type(catalog.notice) == "table" and type(catalog.notice.polkit_agent_on) == "string")

-- account (Task 13) ---------------------------------------------------------
local function queueAccount(f, getText, devicesText)
  f.queue({ "mullvad", "account", "get" }, { stdout = getText or fixture("account-get-connected.txt") })
  if devicesText ~= false then
    f.queue({ "mullvad", "account", "list-devices" }, { stdout = devicesText or fixture("account-list-devices-connected.txt") })
  end
end
local LOGGED_OUT = fixture("synthetic-account-logged-out.txt")

-- No 16-digit run anywhere the service can write: every noctalia.state key (the
-- snapshot and the request channel), every data file, every log line and notification.
local function leaks(f)
  local found = {}
  local function scan(where, text)
    if type(text) == "string" and text:find(SIXTEEN) then found[#found + 1] = where end
  end
  scan("noctalia.state", json.encode(f.state))
  for path, contents in pairs(f.files) do scan(path, contents) end
  for i, line in ipairs(f.logs) do scan("log " .. i, line) end
  for i, note in ipairs(f.notifications) do scan("notification " .. i, tostring(note.title) .. tostring(note.body)) end
  return table.concat(found, ", ")
end

fake = bootRunning(function(f) queueAccount(f) end)
local acc = state(fake).account or {}
eq("service: account read at start", acc.loggedIn, true)
eq("service: account number published masked", acc.masked, "•••• •••• •••• 0000")
eq("service: account number itself not published", acc.number, nil)
eq("service: account expiry text", acc.expiresAt, "2030-01-01 00:00:00 +00:00")
eq("service: account expiry level", acc.expiry, "ok")
eq("service: account device name", acc.deviceName, "Test Device")
eq("service: account devices", acc.devices and #acc.devices, 4)
eq("service: account read leaks no number", leaks(fake), "")

fake = bootRunning(function(f) queueAccount(f, LOGGED_OUT, false) end)
eq("service: logged out published", state(fake).account and state(fake).account.loggedIn, false)
eq("service: logged out skips list-devices", callsMatching(fake, { "mullvad", "account", "list-devices" }), 0)
eq("service: a good account read is no failure", state(fake).accountReadFailed, false)

-- R8: a failed account read (offline) is published, so the tab stops "reading" forever
fake = bootRunning(function(f)
  f.queue({ "mullvad", "account", "get" }, { exitCode = 1, stderr = "Error: API unreachable\n" })
end)
eq("service: failed account read leaves the account unset", state(fake).account, nil)
eq("service: failed account read is published", state(fake).accountReadFailed, true)
queueStatus(fake, "status-disconnected.json")
queueAccount(fake, LOGGED_OUT, false)
send(fake, { action = "refresh" })
eq("service: a later good read clears the failure", state(fake).accountReadFailed, false)
eq("service: and publishes the account", state(fake).account and state(fake).account.loggedIn, false)
fake = bootRunning(function(f)
  f.queue({ "mullvad", "account", "get" }, { timedOut = true, exitCode = 1 })
end)
eq("service: a timed-out account read is a failure", state(fake).accountReadFailed, true)

-- R17: the account readers reach Mullvad's API, so they run at start, on a refresh
-- request, after an account action, and otherwise at most every 10 minutes.
fake = bootRunning(function(f) queueAccount(f) end)
local function accountReads() return callsMatching(fake, { "mullvad", "account", "get" }) end
eq("cadence: one account read at start", accountReads(), 1)
queueStatus(fake, "status-disconnected.json")
poll()
eq("cadence: a 30 s poll does not re-read the account", accountReads(), 1)
eq("cadence: nor the devices", callsMatching(fake, { "mullvad", "account", "list-devices" }), 1)
fake.advance(9 * 60 * 1000)
queueStatus(fake, "status-disconnected.json")
poll()
eq("cadence: not after 9 minutes", accountReads(), 1)
fake.advance(60 * 1000)
queueStatus(fake, "status-disconnected.json")
queueAccount(fake)
poll()
eq("cadence: re-read after 10 minutes", accountReads(), 2)
eq("cadence: devices re-read with it", callsMatching(fake, { "mullvad", "account", "list-devices" }), 2)
queueStatus(fake, "status-disconnected.json")
queueAccount(fake)
send(fake, { action = "refresh" })
eq("cadence: a refresh request re-reads the account", accountReads(), 3)
fake.queue({ "mullvad", "disconnect" }, {})
queueStatus(fake, "status-disconnected.json")
send(fake, { action = "disconnect" })
eq("cadence: a non-account action does not", accountReads(), 3)
fake.queue({ "mullvad", "account", "redeem" }, { exitCode = 1, stderr = fixture("synthetic-account-redeem-invalid.txt") })
queueStatus(fake, "status-disconnected.json")
queueAccount(fake)
send(fake, { action = "redeem", voucher = "INVALID0000" })
eq("cadence: an account action re-reads the account", accountReads(), 4)
eq("service: invalid voucher maps to its key", state(fake).lastError and state(fake).lastError.key, "error.invalid_voucher")
eq("service: a mapped CLI error keeps the CLI line as detail", state(fake).lastError and state(fake).lastError.detail,
  "Error: This voucher code is invalid")

-- a failed account read keeps the last value; daemon down drops it and reads again on return
fake.advance(10 * 60 * 1000)
queueStatus(fake, "status-disconnected.json")
fake.queue({ "mullvad", "account", "get" }, { exitCode = 1, stderr = "Error: API unreachable\n" })
poll()
eq("service: failed account read keeps the last value", state(fake).account and state(fake).account.loggedIn, true)
queueDown(fake)
poll()
eq("service: daemon down drops the account", state(fake).account, nil)
local readsWhileDown = accountReads()
queueStatus(fake, "status-disconnected.json")
queueAccount(fake)
poll()
eq("service: account re-read when the daemon is back", accountReads(), readsWhileDown + 1)

-- login: the number goes into the argv and nowhere else
fake = bootRunning(function(f) queueAccount(f, LOGGED_OUT, false) end)
fake.calls = {}
send(fake, { action = "login", number = "1234" })
eq("service: login rejects bad number without running", #fake.calls, 0)
eq("service: bad number error", state(fake).lastError and state(fake).lastError.key, "error.invalid_account")
eq("service: a validation error has no detail", state(fake).lastError and state(fake).lastError.detail, nil)

fake.queue({ "mullvad", "account", "login" }, { stdout = 'Mullvad account "1234567890123456" set\n' })
queueStatus(fake, "status-disconnected.json")
queueAccount(fake)
send(fake, { action = "login", number = "1234567890123456" }) -- unspaced, so a leak would trip the 16-digit scan
check("service: login runs the number", indexOf(fake, "mullvad account login 1234567890123456") ~= nil)
eq("service: login re-reads the account", state(fake).account and state(fake).account.loggedIn, true)
eq("service: login no error", state(fake).lastError, nil)
eq("service: the login request is cleared from the request channel", fake.state["mullvad.request"], nil)
eq("service: login number not in state or logs", leaks(fake), "")

fake.queue({ "mullvad", "account", "login" }, { exitCode = 1, stderr = "Error: account 1234567890123456 was rejected\n" })
queueStatus(fake, "status-disconnected.json")
queueAccount(fake)
send(fake, { action = "login", number = "1234567890123456" })
eq("service: failed login is command_failed", state(fake).lastError and state(fake).lastError.key, "error.command_failed")
check("service: failed login detail scrubbed", state(fake).lastError and state(fake).lastError.detail:find("#", 1, true) ~= nil)
eq("service: failed login leaks no number", leaks(fake), "")

fake.queue({ "mullvad", "account", "login" }, { exitCode = 1, stderr = "Error: The account does not exist\n" })
queueStatus(fake, "status-disconnected.json")
queueAccount(fake, LOGGED_OUT, false)
onIpc("request", '{"action":"login","number":"1234567890123456"}')
eq("service: ipc login runs", callsMatching(fake, { "mullvad", "account", "login" }), 3)
eq("service: unknown account maps to its key", state(fake).lastError and state(fake).lastError.key, "error.account_not_found")
eq("service: ipc login leaks no number", leaks(fake), "")

-- busy: a login refused while busy still leaves the request channel clean
fake = bootRunning(function(f) f.queue({ "mullvad", "disconnect" }, { defer = true }) end)
send(fake, { action = "disconnect" })
send(fake, { action = "login", number = "1234567890123456" })
eq("service: login while busy is refused", state(fake).lastError and state(fake).lastError.key, "error.busy")
eq("service: refused login cleared from the channel", fake.state["mullvad.request"], nil)

-- revoke: only another device of this account, validated before anything runs
fake = bootRunning(function(f) queueAccount(f) end)
local beforeRevoke = #fake.calls
send(fake, { action = "revoke_device", name = "Test Device" })
eq("service: revoking the current device runs nothing", #fake.calls, beforeRevoke)
eq("service: revoking the current device error", state(fake).lastError and state(fake).lastError.key, "error.unknown_device")
send(fake, { action = "revoke_device", name = "No Such Device" })
eq("service: unknown device runs nothing", #fake.calls, beforeRevoke)
fake.queue({ "mullvad", "account", "revoke-device" }, {})
queueStatus(fake, "status-disconnected.json")
queueAccount(fake)
send(fake, { action = "revoke_device", name = "Other Device 1" })
check("service: revoke runs for another device", indexOf(fake, "mullvad account revoke-device -- Other Device 1") ~= nil)
fake.queue({ "mullvad", "account", "revoke-device" }, { exitCode = 1, stderr = fixture("synthetic-account-revoke-device-unknown.txt") })
queueStatus(fake, "status-disconnected.json")
queueAccount(fake)
send(fake, { action = "revoke_device", name = "Other Device 2" })
eq("service: CLI unknown device maps to its key", state(fake).lastError and state(fake).lastError.key, "error.unknown_device")

-- logout
fake.queue({ "mullvad", "account", "logout" }, {})
queueStatus(fake, "status-disconnected.json")
queueAccount(fake, LOGGED_OUT, false)
send(fake, { action = "logout" })
eq("service: logout shows the re-read state", state(fake).account and state(fake).account.loggedIn, false)

-- open_account_page: detached, like open_app
fake = bootRunning()
start = #fake.calls
send(fake, { action = "open_account_page" })
launch = fake.calls[start + 1]
eq("service: open_account_page argv", launch and table.concat(launch.argv, " "), "xdg-open https://mullvad.net/account")
eq("service: open_account_page is detached", launch and launch.hasCallback, false)
eq("service: open_account_page is not busy", state(fake).busy, false)

current.uninstall()

-- fix round 1: the account readers run in their own pass, so a hung API call never
-- holds up an action's re-read, a refresh, or the busy flag
fake = bootRunning(function(f)
  f.queue({ "mullvad", "account", "get" }, { defer = true, stdout = fixture("account-get-connected.txt") })
end)
check("split: boot publishes while the account read hangs", fake.state["mullvad.state"] ~= nil and state(fake).daemon == "running")
fake.queue({ "mullvad", "lockdown-mode", "set" }, {})
queueStatus(fake, "status-disconnected.json")
queueSettings(fake, nil, "synthetic-lockdown-mode-get-on.txt")
local seqBeforeLockdown = state(fake).requestSeq
send(fake, { action = "set_lockdown", on = true })
eq("split: set_lockdown publishes busy=false behind a hung account read", state(fake).busy, false)
eq("split: set_lockdown shows the re-read setting", state(fake).settings and state(fake).settings.lockdown, true)
eq("split: set_lockdown bumps requestSeq", state(fake).requestSeq, seqBeforeLockdown + 1)
queueStatus(fake, "status-disconnected.json")
send(fake, { action = "refresh" })
eq("split: a refresh is handled behind a hung account read", state(fake).requestSeq, seqBeforeLockdown + 2)
eq("split: no account yet", state(fake).account, nil)
fake.queue({ "mullvad", "account", "list-devices" }, { stdout = fixture("account-list-devices-connected.txt") })
fake.flush()
eq("split: the late account read publishes on its own", state(fake).account and state(fake).account.loggedIn, true)

-- an account action is handled only once its account re-read has landed
fake = bootRunning(function(f) queueAccount(f) end)
fake.queue({ "mullvad", "account", "logout" }, {})
queueStatus(fake, "status-disconnected.json")
fake.queue({ "mullvad", "account", "get" }, { defer = true, stdout = LOGGED_OUT })
local seqBeforeLogout = state(fake).requestSeq
send(fake, { action = "logout" })
eq("split: logout frees busy at once", state(fake).busy, false)
eq("split: logout not handled before the account re-read", state(fake).requestSeq, seqBeforeLogout)
fake.flush()
eq("split: logout handled with the re-read account", state(fake).requestSeq, seqBeforeLogout + 1)
eq("split: logout shows logged out", state(fake).account and state(fake).account.loggedIn, false)

-- dismiss_error clears the shown error (only the one the user saw), runs nothing
fake = bootRunning()
send(fake, { action = "revoke_device", name = "x" })
eq("dismiss: an error to dismiss", state(fake).lastError and state(fake).lastError.key, "error.unknown_device")
local callsBeforeDismiss, seqBeforeDismiss = #fake.calls, state(fake).requestSeq
send(fake, { action = "dismiss_error", key = "error.busy" })
eq("dismiss: another key leaves the error", state(fake).lastError and state(fake).lastError.key, "error.unknown_device")
send(fake, { action = "dismiss_error", key = "error.unknown_device", detail = "other" })
eq("dismiss: same key, different detail leaves the error", state(fake).lastError and state(fake).lastError.key, "error.unknown_device")
send(fake, { action = "dismiss_error", key = "error.unknown_device", detail = state(fake).lastError.detail })
eq("dismiss: clears the error", state(fake).lastError, nil)
eq("dismiss: runs nothing", #fake.calls, callsBeforeDismiss)
eq("dismiss: counts as handled", state(fake).requestSeq, seqBeforeDismiss + 3)
fake = bootRunning(function(f) f.queue({ "mullvad", "disconnect" }, { defer = true }) end)
send(fake, { action = "disconnect" })
send(fake, { action = "login", number = "1" })
send(fake, { action = "dismiss_error", key = "error.busy" })
eq("dismiss: works while busy", state(fake).lastError, nil)
eq("dismiss: while busy keeps the action busy", state(fake).busy, true)

current.uninstall()

-- R6 holds for the account pass: a refresh while busy reads nothing now, the account comes at the next poll
fake = bootRunning(function(f)
  queueAccount(f)
  f.queue({ "mullvad", "disconnect" }, { defer = true })
end)
send(fake, { action = "disconnect" })
local readsBusy = callsMatching(fake, { "mullvad", "account", "get" })
send(fake, { action = "refresh" })
eq("split: refresh while busy does not read the account", callsMatching(fake, { "mullvad", "account", "get" }), readsBusy)
queueStatus(fake, "status-disconnected.json")
fake.flush()
queueStatus(fake, "status-disconnected.json")
queueAccount(fake)
poll()
eq("split: the next poll reads it", callsMatching(fake, { "mullvad", "account", "get" }), readsBusy + 1)
current.uninstall()

-- daemon down at boot: the account read fails fast and does not count as a read;
-- start_service reads the account right away
fake = boot(queueDown)
eq("daemon-down: account stays unread", state(fake).account, nil)
fake.queue({ "pkexec", "systemctl", "enable", "--now", "mullvad-daemon" }, {})
queueStatus(fake, "status-disconnected.json")
queueRelays(fake)
queueAccount(fake)
local accountReadsBefore = callsMatching(fake, { "mullvad", "account", "get" })
send(fake, { action = "start_service" })
check("daemon-down: start_service reads the account at once",
  callsMatching(fake, { "mullvad", "account", "get" }) > accountReadsBefore)
eq("daemon-down: the account is published", state(fake).account and state(fake).account.loggedIn, true)
current.uninstall()

-- a daemon-down account result is not a read: the next poll retries it
fake = boot(queueDown)
fake.queue({ "pkexec", "systemctl", "enable", "--now", "mullvad-daemon" }, {})
queueStatus(fake, "status-disconnected.json")
queueRelays(fake)
fake.queue({ "mullvad", "account", "get" }, { exitCode = 1, stderr = fixture("synthetic-daemon-down.txt") })
send(fake, { action = "start_service" })
eq("daemon-down: a down result leaves the account unread", state(fake).account, nil)
queueStatus(fake, "status-disconnected.json")
queueAccount(fake)
poll()
eq("daemon-down: the next poll reads the account", state(fake).account and state(fake).account.loggedIn, true)
current.uninstall()

-- a key-less dismiss clears whatever error is shown, even one with a detail
fake = bootRunning(function(f) f.queue({ "mullvad", "disconnect" }, { exitCode = 1, stderr = "boom" }) end)
send(fake, { action = "disconnect" })
check("dismiss: an error with a detail to dismiss", state(fake).lastError ~= nil and state(fake).lastError.detail ~= nil)
send(fake, { action = "dismiss_error" })
eq("dismiss: key-less clears an error with a detail", state(fake).lastError, nil)
current.uninstall()
