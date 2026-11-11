-- service.luau against the fake noctalia. Each test boots a fresh service.
local model = loadModule("model.luau")

local DIR = "/fake/plugin-data"
local CLI = "logonbox-vpn-cli"
local GUI = "logonbox-vpn-gui"
local OPT_CLI = "/opt/logonbox-vpn-client/logonbox-vpn-cli"
local OPT_GUI = "/opt/logonbox-vpn-client/logonbox-vpn-gui"
local OWNER = { "gdbus", "call" }
local SHOW = { CLI, "show" }
local CONNECT = { CLI, "connect" }
local DISCONNECT = { CLI, "disconnect" }
local MONITOR = "gdbus monitor --system --dest com.logonbox.vpn"
local OSRELEASE = "/proc/sys/kernel/osrelease"
local REL = "7.2.14-zen1-1-zen"
local CONNECTING_LINE = "/com/logonbox/vpn/0: com.logonbox.vpn.Connection.Connecting ()"
local CONNECTED_LINE = "/com/logonbox/vpn/0: com.logonbox.vpn.Connection.Connected ()"

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
  return fake.state["logonbox.state"] or {}
end

local function send(fake, request)
  fake.noctalia.state.set("logonbox.request", request)
end

local function poll()
  for _ = 1, 60 do update() end
end

local function count(fake, prefix)
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

local function lastCall(fake, prefix)
  for i = #fake.calls, 1, -1 do
    local call = fake.calls[i]
    local match = true
    for j, part in ipairs(prefix) do
      if call.argv[j] ~= part then match = false end
    end
    if match then return call end
  end
  return nil
end

local function queueOwner(f, value)
  f.queue(OWNER, { stdout = "(" .. value .. ",)\n" })
end

local function queueShow(f, name, extra)
  local result = { stdout = name and fixture(name) or "" }
  for k, v in pairs(extra or {}) do result[k] = v end
  f.queue(SHOW, result)
end

local function queueRead(f, name)
  queueOwner(f, "true")
  queueShow(f, name)
end

local function wgLoaded(f)
  f.files[OSRELEASE] = REL .. "\n"
  f.exists["/sys/module/wireguard"] = true
end

local function bootWith(name, extra)
  return boot(function(f)
    queueRead(f, name)
    if extra then extra(f) end
  end)
end

local function row(fake, id)
  for _, c in ipairs(state(fake).connections or {}) do
    if c.id == id then return c end
  end
  return nil
end

local function rowError(fake, id)
  return (state(fake).rowErrors or {})[tostring(id)]
end

local function inFlight(fake, id)
  return (state(fake).inFlight or {})[tostring(id)]
end

-- ── discovery ────────────────────────────────────────────────────────────────

local fake = boot(function(f)
  f.commands[CLI] = false
  f.commands[GUI] = false
end)
eq("service: not installed runs nothing", #fake.calls, 0)
eq("service: not installed publishes installed=false", state(fake).installed, false)
eq("service: not installed starts no stream", #fake.runStreams, 0)
eq("service: not installed panel state", model.panelState(state(fake)), "not_installed")
poll()
eq("service: not installed poll runs nothing", #fake.calls, 0)
fake.commands[CLI] = nil
queueRead(fake, "show-disconnected.txt")
poll()
eq("service: install picked up on the next poll", state(fake).installed, true)
eq("service: install picked up reads show", count(fake, SHOW), 1)

fake = boot(function(f)
  f.commands[CLI] = false
  f.commands[GUI] = false
  f.exists[OPT_CLI] = true
  f.exists[OPT_GUI] = true
  queueOwner(f, "true")
  f.queue({ OPT_CLI, "show" }, { stdout = fixture("show-disconnected.txt") })
end)
eq("service: /opt fallback installed", state(fake).installed, true)
eq("service: /opt fallback runs the /opt cli", count(fake, { OPT_CLI, "show", ".*" }), 1)
eq("service: /opt fallback reads connections", #(state(fake).connections or {}), 1)
send(fake, { action = "open_gui" })
eq("service: /opt fallback gui", lastCall(fake, { OPT_GUI }) ~= nil, true)

-- ── refresh ──────────────────────────────────────────────────────────────────

fake = bootWith("show-disconnected.txt")
eq("service: running after a good read", state(fake).service, "running")
eq("service: polls on a 1 s tick", fake.updateInterval, 1000)
eq("service: not busy at start", state(fake).busy, false)
eq("service: connections read", row(fake, 0) and row(fake, 0).status, "DISCONNECTED")
eq("service: show argv", table.concat(lastCall(fake, SHOW).argv, " "), "logonbox-vpn-cli show .*")
eq("service: show timeout", lastCall(fake, SHOW).timeoutMs, 15000)
eq("service: owner check runs first", table.concat(fake.calls[1].argv, " "),
  "gdbus call --system --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner com.logonbox.vpn")
check("service: snapshot has a boot id", type(state(fake).serviceBootId) == "string" and state(fake).serviceBootId ~= "")
check("service: snapshot has a seq", type(state(fake).seq) == "number")
local before = #fake.calls
for _ = 1, 59 do update() end
eq("service: no poll before 60 ticks", #fake.calls, before)
queueRead(fake, "show-disconnected.txt")
update()
eq("service: poll on the 60th tick", count(fake, SHOW), 2)
-- any pass restarts the poll count, so no poll lands right after an action's re-read
for _ = 1, 59 do update() end
queueRead(fake, "show-disconnected.txt")
send(fake, { action = "refresh" })
eq("service: refresh request reads", count(fake, SHOW), 3)
update()
eq("service: a pass resets the poll count", count(fake, SHOW), 3)

fake = boot(function(f) queueOwner(f, "false") end)
eq("service: name owner false gives service_down", state(fake).service, "down")
eq("service: name owner false runs no show", count(fake, SHOW), 0)
eq("service: name owner false starts no stream", #fake.runStreams, 0)
eq("service: service down panel state", model.panelState(state(fake)), "service_down")
queueRead(fake, "show-disconnected.txt")
poll()
eq("service: service back gives the list again", model.panelState(state(fake)), "list")
eq("service: service back starts the stream", #fake.runStreams, 1)

-- a stream just started by the read that finds the service back is not checked at once
fake = boot(function(f) queueOwner(f, "false") end)
local realRunStream = fake.noctalia.runStream
fake.noctalia.runStream = function(cmd, onLine)
  local started = realRunStream(cmd, onLine)
  fake.kill(cmd) -- not in the process list yet
  return started
end
queueRead(fake, "show-disconnected.txt")
poll()
eq("service: service back starts exactly one stream", #fake.runStreams, 1)

-- owner unknown (gdbus failed): show decides
fake = boot(function(f)
  f.queue(OWNER, { exitCode = 1, stderr = "gdbus: error" })
  queueShow(f, nil, { exitCode = 1, stderr = "cannot reach service" })
end)
eq("service: owner unknown and show fails gives down", state(fake).service, "down")
fake = boot(function(f)
  f.queue(OWNER, { exitCode = 127 })
  queueShow(f, "show-disconnected.txt")
end)
eq("service: owner unknown and show ok gives running", state(fake).service, "running")

-- a failed FIRST read with an owner: error.read, not an endless "loading"
fake = boot(function(f)
  queueOwner(f, "true")
  queueShow(f, nil, { exitCode = 1, stderr = "boom" })
end)
eq("service: first show fails, error.read", state(fake).lastError and state(fake).lastError.key, "error.read")
eq("service: first show fails, service unknown", state(fake).service, "unknown")
eq("service: first show fails, not loading", model.isLoading(state(fake)), false)
eq("service: first show fails, read_error panel", model.panelState(state(fake)), "read_error")
eq("service: first show fails, tile is !", model.barView(state(fake)).label, "!")
fake = boot(function(f)
  queueOwner(f, "true")
  queueShow(f, nil, { timedOut = true, exitCode = -1 })
end)
eq("service: first show times out, error.read", state(fake).lastError and state(fake).lastError.key, "error.read")
eq("service: first show times out, not loading", model.isLoading(state(fake)), false)
eq("service: first show times out, read_error panel", model.panelState(state(fake)), "read_error")
queueRead(fake, "show-disconnected.txt")
poll()
eq("service: read error heals on the next poll", model.panelState(state(fake)), "list")
eq("service: read error heals, error gone", state(fake).lastError, nil)

-- bad reads keep the previous connections
fake = bootWith("show-connected.txt")
queueRead(fake, "show-garbage.txt")
send(fake, { action = "refresh" })
eq("service: bad read keeps previous connections", #(state(fake).connections or {}), 1)
eq("service: bad read keeps status", row(fake, 0) and row(fake, 0).status, "CONNECTED")
eq("service: bad read sets error.read", state(fake).lastError and state(fake).lastError.key, "error.read")
queueOwner(fake, "true")
queueShow(fake, nil, { exitCode = 1, stderr = "boom" })
send(fake, { action = "refresh" })
eq("service: failed show with an owner keeps connections", #(state(fake).connections or {}), 1)
eq("service: failed show with an owner is error.read", state(fake).lastError and state(fake).lastError.key, "error.read")
eq("service: failed show with an owner stays running", state(fake).service, "running")
queueRead(fake, "show-connected.txt")
send(fake, { action = "refresh" })
eq("service: good read clears error.read", state(fake).lastError, nil)

-- R7: an empty read after a non-empty one is read again before it is believed
fake = bootWith("show-connected.txt")
queueRead(fake, "show-empty.txt")
queueShow(fake, "show-connected.txt")
send(fake, { action = "refresh" })
eq("service: empty read after a good one is re-read", count(fake, SHOW), 3)
eq("service: empty then good keeps the list", #(state(fake).connections or {}), 1)
queueRead(fake, "show-empty.txt")
queueShow(fake, "show-empty.txt")
send(fake, { action = "refresh" })
eq("service: empty twice is believed", #(state(fake).connections or {}), 0)
eq("service: empty twice is no_connections", model.panelState(state(fake)), "no_connections")
eq("service: empty twice is not an error", state(fake).lastError, nil)
queueRead(fake, "show-empty.txt")
send(fake, { action = "refresh" })
eq("service: empty after empty is not re-read", count(fake, SHOW), 6)

fake = bootWith("show-empty.txt")
eq("service: empty first read is zero connections", #(state(fake).connections or {}), 0)
eq("service: empty first read reads once", count(fake, SHOW), 1)

-- coalescing
fake = boot(function(f)
  queueOwner(f, "true")
  queueShow(f, "show-disconnected.txt", { defer = true })
end)
send(fake, { action = "refresh" })
send(fake, { action = "refresh" })
eq("service: refresh is coalesced while one runs", count(fake, SHOW), 1)
queueRead(fake, "show-disconnected.txt")
fake.flush()
eq("service: refresh is coalesced (exactly two show calls)", count(fake, SHOW), 2)
eq("service: coalesced refreshes are both handled", state(fake).requestSeq, 2)

-- ── stream ───────────────────────────────────────────────────────────────────

fake = bootWith("show-disconnected.txt")
eq("service: stream starts after first good read", #fake.runStreams, 1)
eq("service: stream command", fake.runStreams[1] and fake.runStreams[1].cmd, MONITOR)
queueRead(fake, "show-disconnected.txt")
poll()
eq("service: stream not started twice", #fake.runStreams, 1)

before = #fake.calls
fake.streamLine(1, CONNECTING_LINE)
eq("service: Connecting line sets inFlight without a read", inFlight(fake, 0), "connecting")
eq("service: Connecting line runs nothing", #fake.calls, before)
eq("service: Connecting line shows … on the tile", model.barView(state(fake)).label, "…")

queueRead(fake, "show-connected.txt")
fake.streamLine(1, CONNECTED_LINE)
eq("service: Connected signal triggers refresh", #fake.calls, before + 2)
eq("service: Connected signal reads CONNECTED", row(fake, 0) and row(fake, 0).status, "CONNECTED")
eq("service: CONNECTED clears inFlight", inFlight(fake, 0), nil)
fake.streamLine(1, "something unrelated")
eq("service: unrelated stream line runs nothing", #fake.calls, before + 2)

-- a transition started elsewhere that fails ends DISCONNECTED: the next read clears it
fake = bootWith("show-disconnected.txt")
fake.streamLine(1, CONNECTING_LINE)
queueRead(fake, "show-disconnected.txt")
fake.streamLine(1, "/com/logonbox/vpn/0: com.logonbox.vpn.Connection.Failed ('x', 'y', 'z')")
eq("service: outside transition cleared by a later read", inFlight(fake, 0), nil)

-- a transition read that started before the signal does not clear it
fake = boot(function(f)
  queueOwner(f, "true")
  queueShow(f, "show-disconnected.txt")
end)
queueOwner(fake, "true")
queueShow(fake, "show-disconnected.txt", { defer = true })
send(fake, { action = "refresh" })
fake.streamLine(1, CONNECTING_LINE)
fake.flush()
eq("service: a read started before the signal keeps inFlight", inFlight(fake, 0), "connecting")

-- stale inFlight for a connection that no longer exists is dropped
fake = bootWith("show-disconnected.txt")
fake.streamLine(1, "/com/logonbox/vpn/5: com.logonbox.vpn.Connection.Connecting ()")
eq("service: transition for an unknown row is recorded", inFlight(fake, 5), "connecting")
queueRead(fake, "show-disconnected.txt")
send(fake, { action = "refresh" })
eq("service: stale inFlight for a missing row is dropped", inFlight(fake, 5), nil)

-- dead stream
fake = bootWith("show-disconnected.txt")
fake.kill(MONITOR)
queueRead(fake, "show-disconnected.txt")
poll()
eq("service: dead stream waits for the settle time", #fake.runStreams, 1)
fake.advance(6000)
queueRead(fake, "show-disconnected.txt")
poll()
eq("service: dead stream is restarted on poll", #fake.runStreams, 2)
queueRead(fake, "show-disconnected.txt")
fake.advance(6000)
poll()
eq("service: live stream is not restarted", #fake.runStreams, 2)

-- ── actions ──────────────────────────────────────────────────────────────────

fake = bootWith("show-disconnected.txt", function(f)
  wgLoaded(f)
  f.queue(CONNECT, { stdout = fixture("connect-ok.txt") })
  queueRead(f, "show-connected.txt")
end)
local seq0 = state(fake).requestSeq
send(fake, { action = "connect", id = 0 })
local call = lastCall(fake, CONNECT)
eq("service: connect argv", call and table.concat(call.argv, " "), "logonbox-vpn-cli connect 0")
eq("service: connect timeout", call and call.timeoutMs, 60000)
eq("service: connect success re-reads", row(fake, 0) and row(fake, 0).status, "CONNECTED")
eq("service: connect success clears busy", state(fake).busy, false)
eq("service: connect success clears inFlight", inFlight(fake, 0), nil)
eq("service: connect success no notification", #fake.notifications, 0)
eq("service: connect success no row error", rowError(fake, 0), nil)
eq("service: connect bumps requestSeq once", state(fake).requestSeq, seq0 + 1)
eq("service: connect success no kernel read", #fake.fileReads, 0)

fake = bootWith("show-disconnected.txt", function(f)
  f.queue(CONNECT, { defer = true })
end)
send(fake, { action = "connect", id = "0" })
eq("service: connect string id runs", count(fake, CONNECT), 1)
eq("service: busy while connecting", state(fake).busy, true)
eq("service: inFlight connecting while busy", inFlight(fake, 0), "connecting")

before = #fake.calls
send(fake, { action = "disconnect", id = 0 })
eq("service: second action while busy is refused", state(fake).lastError and state(fake).lastError.key, "error.busy")
eq("service: refused action runs nothing", #fake.calls, before)
eq("service: refused action keeps the row connecting", inFlight(fake, 0), "connecting")
send(fake, { action = "connect", id = 0 })
eq("service: second connect while busy runs nothing", count(fake, CONNECT), 1)
local seqBusy = state(fake).requestSeq
send(fake, { action = "refresh" })
eq("service: refresh while busy runs nothing", #fake.calls, before)
eq("service: refresh while busy is handled", state(fake).requestSeq, seqBusy + 1)
send(fake, { action = "dismiss_error" })
eq("service: dismiss_error clears lastError while busy", state(fake).lastError, nil)
eq("service: dismiss_error runs nothing", #fake.calls, before)
send(fake, { action = "open_gui" })
local gui = lastCall(fake, { GUI })
check("service: open_gui is detached and allowed while busy", gui ~= nil and gui.hasCallback == false and #gui.argv == 1)
eq("service: open_gui while busy sets no busy error", state(fake).lastError, nil)
send(fake, { action = "open_download" })
local dl = lastCall(fake, { "xdg-open" })
check("service: open_download is detached and allowed while busy",
  dl ~= nil and dl.hasCallback == false and dl.argv[2] == "https://docs.logonbox.com/app/logonbox-documentation/en/article/7680932")
eq("service: still busy after detached launches", state(fake).busy, true)

fake = bootWith("show-unauthorized.txt")
before = #fake.calls
send(fake, { action = "connect", id = 0 })
eq("service: connect on unauthorized row runs nothing", #fake.calls, before)
eq("service: unauthorized row error", rowError(fake, 0) and rowError(fake, 0).key, "error.needs_signin")
eq("service: unauthorized connect not busy", state(fake).busy, false)

fake = bootWith("show-authorizing.txt")
before = #fake.calls
send(fake, { action = "connect", id = 0 })
eq("service: connect on authorizing row runs nothing", #fake.calls, before)

fake = bootWith("show-disconnected.txt")
before = #fake.calls
send(fake, { action = "connect", id = "0; rm -rf ~" })
eq("service: connect invalid id refused", state(fake).lastError and state(fake).lastError.key, "error.invalid_id")
eq("service: invalid id runs nothing", #fake.calls, before)
send(fake, { action = "connect", id = 7 })
eq("service: connect unknown id runs nothing", #fake.calls, before)
send(fake, { action = "disconnect", id = "-d" })
eq("service: disconnect -d runs nothing", #fake.calls, before)
send(fake, { action = "connect" })
eq("service: connect without id runs nothing", #fake.calls, before)
send(fake, { action = "format_disk" })
eq("service: unknown action error", state(fake).lastError and state(fake).lastError.key, "error.unknown_action")
eq("service: unknown action runs nothing", #fake.calls, before)
send(fake, "not a table")
eq("service: non-table request ignored", #fake.calls, before)

-- connect failure, WireGuard loaded: the CLI's reason
fake = bootWith("show-disconnected.txt", function(f)
  wgLoaded(f)
  f.queue(CONNECT, { exitCode = 1, stdout = "Connecting to https://user%40example.com@vpn.example.com:8443/app\n" .. fixture("connect-failed.txt") })
  queueRead(f, "show-disconnected.txt")
end)
send(fake, { action = "connect", id = 0 })
eq("service: connect failure without reboot", rowError(fake, 0) and rowError(fake, 0).key, "error.connect_failed_detail")
eq("service: connect failure detail", rowError(fake, 0) and rowError(fake, 0).detail, "No route to host")
eq("service: connect failure one notification", #fake.notifications, 1)
eq("service: connect failure notification title", fake.notifications[1] and fake.notifications[1].title, "notify.connect_failed")
eq("service: connect failure notification body", fake.notifications[1] and fake.notifications[1].body, "error.connect_failed_detail")
eq("service: connect failure is an error notification", fake.notifications[1] and fake.notifications[1].error, true)
eq("service: connect failure reads the kernel release", fake.fileReads[1], OSRELEASE)
eq("service: connect failure no reboot", state(fake).rebootNeeded, false)
eq("service: connect failure clears inFlight", inFlight(fake, 0), nil)
eq("service: connect failure clears busy", state(fake).busy, false)
eq("service: connect failure re-reads", count(fake, SHOW), 2)
eq("service: connect failure shows ! on the tile", model.barView(state(fake)).label, "!")
local logged = table.concat(fake.logs, "\n")
check("service: log holds no host or account", not logged:find("example", 1, true) and not logged:find("@", 1, true))

-- the error lifetime
queueRead(fake, "show-disconnected.txt")
poll()
eq("service: row error survives a DISCONNECTED poll", rowError(fake, 0) and rowError(fake, 0).key, "error.connect_failed_detail")
fake.queue(CONNECT, { defer = true })
send(fake, { action = "connect", id = 0 })
eq("service: row error cleared by next action on the row", rowError(fake, 0), nil)

-- the detail never carries a host
fake = bootWith("show-disconnected.txt", function(f)
  wgLoaded(f)
  f.queue(CONNECT, { exitCode = 1, stdout = "Failed to connect. Connection refused: vpn.example.com/192.0.2.1:8443\n" })
  queueRead(f, "show-disconnected.txt")
end)
send(fake, { action = "connect", id = 0 })
eq("service: connect failure detail is scrubbed", rowError(fake, 0) and rowError(fake, 0).detail, "Connection refused: …")

-- connect failure, kernel updated without a reboot
fake = bootWith("show-disconnected.txt", function(f)
  f.files[OSRELEASE] = REL .. "\n"
  f.queue(CONNECT, { exitCode = 1, stdout = fixture("connect-failed-wg0.txt") })
  queueRead(f, "show-disconnected.txt")
end)
send(fake, { action = "connect", id = 0 })
eq("service: connect failure with reboot", rowError(fake, 0) and rowError(fake, 0).key, "error.reboot_needed")
eq("service: reboot flag set", state(fake).rebootNeeded, true)
eq("service: reboot notification body", fake.notifications[1] and fake.notifications[1].body, "error.reboot_needed")
local reads = #fake.fileReads
queueRead(fake, "show-disconnected.txt")
send(fake, { action = "refresh" })
eq("service: reboot stays while the check fails", state(fake).rebootNeeded, true)
eq("service: reboot re-check uses file tests only", #fake.fileReads, reads)
fake.exists["/usr/lib/modules/" .. REL] = true
fake.dirs["/usr/lib/modules/" .. REL .. "/kernel/drivers/net/wireguard"] = { "wireguard.ko.zst" }
queueRead(fake, "show-disconnected.txt")
send(fake, { action = "refresh" })
eq("service: reboot cleared when check passes", state(fake).rebootNeeded, false)
eq("service: reboot row error cleared with it", rowError(fake, 0), nil)

-- modules present but WireGuard not loaded: not a reboot
fake = bootWith("show-disconnected.txt", function(f)
  f.files[OSRELEASE] = REL .. "\n"
  f.exists["/usr/lib/modules/" .. REL] = true
  f.dirs["/usr/lib/modules/" .. REL .. "/kernel/drivers/net/wireguard"] = { "wireguard.ko.zst" }
  f.queue(CONNECT, { exitCode = 1, stdout = fixture("connect-failed.txt") })
  queueRead(f, "show-disconnected.txt")
end)
send(fake, { action = "connect", id = 0 })
eq("service: loadable module is no reboot", state(fake).rebootNeeded, false)

-- unreadable kernel release never claims a reboot
fake = bootWith("show-disconnected.txt", function(f)
  f.queue(CONNECT, { exitCode = 1, stdout = fixture("connect-failed.txt") })
  queueRead(f, "show-disconnected.txt")
end)
send(fake, { action = "connect", id = 0 })
eq("service: unreadable release is no reboot", state(fake).rebootNeeded, false)
eq("service: unreadable release still sets the row error", rowError(fake, 0) and rowError(fake, 0).key, "error.connect_failed_detail")

-- a row error is cleared when the row reaches CONNECTED
fake = bootWith("show-disconnected.txt", function(f)
  wgLoaded(f)
  f.queue(CONNECT, { exitCode = 1, stdout = fixture("connect-failed.txt") })
  queueRead(f, "show-disconnected.txt")
end)
send(fake, { action = "connect", id = 0 })
queueRead(fake, "show-connected.txt")
fake.streamLine(1, CONNECTED_LINE)
eq("service: row error cleared when the row is CONNECTED", rowError(fake, 0), nil)

-- timeouts
fake = bootWith("show-disconnected.txt", function(f)
  wgLoaded(f)
  f.queue(CONNECT, { exitCode = -1, timedOut = true })
  queueRead(f, "show-disconnected.txt")
end)
send(fake, { action = "connect", id = 0 })
eq("service: connect timeout clears busy", state(fake).busy, false)
eq("service: connect timeout row error", rowError(fake, 0) and rowError(fake, 0).key, "error.connect_timeout")
eq("service: connect timeout re-reads", count(fake, SHOW), 2)

fake = bootWith("show-disconnected.txt", function(f)
  wgLoaded(f)
  f.queue(CONNECT, { defer = true, exitCode = 1, stdout = fixture("connect-failed.txt") })
end)
send(fake, { action = "connect", id = 0 })
fake.advance(60000)
update()
eq("service: watchdog waits for the slack", state(fake).busy, true)
fake.advance(5001)
queueRead(fake, "show-disconnected.txt")
update()
eq("service: watchdog clears lost callback", state(fake).busy, false)
eq("service: watchdog row error", rowError(fake, 0) and rowError(fake, 0).key, "error.connect_timeout")
eq("service: watchdog clears inFlight", inFlight(fake, 0), nil)
eq("service: watchdog re-reads", count(fake, SHOW), 2)
fake.flush()
eq("service: watchdog connect timeout notifies once", #fake.notifications, 1)
eq("service: watchdog notification body", fake.notifications[1] and fake.notifications[1].body, "error.connect_timeout")
eq("service: watchdog notification title", fake.notifications[1] and fake.notifications[1].title, "notify.connect_failed")
eq("service: late callback after the watchdog is ignored", #fake.notifications, 1)
eq("service: late callback keeps the watchdog error", rowError(fake, 0) and rowError(fake, 0).key, "error.connect_timeout")

-- disconnect
fake = bootWith("show-connected.txt", function(f)
  f.queue(DISCONNECT, { exitCode = 0, stderr = fixture("disconnect-not-connected.txt") })
  queueRead(f, "show-disconnected.txt")
end)
send(fake, { action = "disconnect", id = 0 })
call = lastCall(fake, DISCONNECT)
eq("service: disconnect argv", call and table.concat(call.argv, " "), "logonbox-vpn-cli disconnect 0")
eq("service: disconnect timeout", call and call.timeoutMs, 30000)
eq("service: disconnect already counts as success", rowError(fake, 0), nil)
eq("service: disconnect already no notification", #fake.notifications, 0)
eq("service: disconnect re-reads", row(fake, 0) and row(fake, 0).status, "DISCONNECTED")
eq("service: disconnect clears inFlight", inFlight(fake, 0), nil)
eq("service: disconnect runs no kernel check", #fake.fileReads, 0)

fake = bootWith("show-connected.txt", function(f)
  f.queue(DISCONNECT, { defer = true, stdout = fixture("disconnect-ok.txt") })
end)
send(fake, { action = "disconnect", id = 0 })
eq("service: inFlight disconnecting while busy", inFlight(fake, 0), "disconnecting")
queueRead(fake, "show-disconnected.txt")
fake.flush()
eq("service: disconnect ok clears busy", state(fake).busy, false)
eq("service: disconnect ok clears inFlight", inFlight(fake, 0), nil)

fake = bootWith("show-connected.txt", function(f)
  f.queue(DISCONNECT, { exitCode = 1, stderr = "nope\n" })
  queueRead(f, "show-connected.txt")
end)
send(fake, { action = "disconnect", id = 0 })
eq("service: disconnect failure row error", rowError(fake, 0) and rowError(fake, 0).key, "error.disconnect_failed_detail")
eq("service: disconnect failure survives a CONNECTED read", rowError(fake, 0) and rowError(fake, 0).detail, "nope")
eq("service: disconnect failure sends no notification (R9)", #fake.notifications, 0)
queueRead(fake, "show-disconnected.txt")
send(fake, { action = "refresh" })
eq("service: disconnect error cleared when the row is DISCONNECTED", rowError(fake, 0), nil)

-- detached launches
fake = bootWith("show-disconnected.txt")
before = count(fake, { GUI })
send(fake, { action = "open_gui" })
eq("service: open_gui launches the gui", count(fake, { GUI }), before + 1)
eq("service: open_gui argv is the gui alone", #lastCall(fake, { GUI }).argv, 1)
fake = boot(function(f)
  f.commands[CLI] = false
  f.commands[GUI] = false
end)
send(fake, { action = "open_download" })
eq("service: open_download works when not installed", count(fake, { "xdg-open" }), 1)
send(fake, { action = "open_gui" })
eq("service: open_gui without a gui runs nothing", count(fake, { GUI }), 0)
eq("service: open_gui without a gui is an error", state(fake).lastError and state(fake).lastError.key, "error.open_gui_failed")

-- the needs-sign-in refusal leaves an unrelated global error alone
fake = bootWith("show-unauthorized.txt")
queueRead(fake, "show-garbage.txt")
send(fake, { action = "refresh" })
send(fake, { action = "connect", id = 0 })
eq("service: needs-sign-in refusal keeps lastError", state(fake).lastError and state(fake).lastError.key, "error.read")
eq("service: needs-sign-in refusal still sets the row error", rowError(fake, 0) and rowError(fake, 0).key, "error.needs_signin")

-- a later kernel check that passes clears reboot errors on other rows too
local twoDown = fixture("show-multi.txt"):gsub("Status: CONNECTED", "Status: DISCONNECTED")
fake = boot(function(f)
  f.files[OSRELEASE] = REL .. "\n"
  queueOwner(f, "true")
  f.queue(SHOW, { stdout = twoDown })
  f.queue(CONNECT, { exitCode = 1, stdout = fixture("connect-failed-wg0.txt") })
  queueOwner(f, "true")
  f.queue(SHOW, { stdout = twoDown })
end)
send(fake, { action = "connect", id = 0 })
eq("service: row 0 reboot error", rowError(fake, 0) and rowError(fake, 0).key, "error.reboot_needed")
fake.exists["/sys/module/wireguard"] = true
fake.queue(CONNECT, { exitCode = 1, stdout = fixture("connect-failed.txt") })
queueOwner(fake, "true")
fake.queue(SHOW, { stdout = twoDown })
send(fake, { action = "connect", id = 1 })
eq("service: row 1 gets the real reason", rowError(fake, 1) and rowError(fake, 1).key, "error.connect_failed_detail")
eq("service: reboot flag cleared by the passing check", state(fake).rebootNeeded, false)
eq("service: stale reboot row error cleared", rowError(fake, 0), nil)

-- ── simulate ─────────────────────────────────────────────────────────────────

local expected = {
  not_installed = "not_installed",
  service_down = "service_down",
  no_connections = "no_connections",
  needs_signin = "list",
  reboot_needed = "list",
  multi = "list",
}
for mode, panel in pairs(expected) do
  fake = boot(function(f)
    f.setFile(DIR .. "/simulate", "  " .. mode .. "\n")
  end)
  eq("service: simulate " .. mode .. " panel state", model.panelState(state(fake)), panel)
  eq("service: simulate " .. mode .. " flag", state(fake).simulate, mode)
  eq("service: simulate " .. mode .. " runs no cli", count(fake, { CLI }) + count(fake, OWNER), 0)
  send(fake, { action = "connect", id = 0 })
  eq("service: simulate " .. mode .. " refuses actions", state(fake).lastError and state(fake).lastError.key, "error.simulated")
  eq("service: simulate " .. mode .. " action runs nothing", count(fake, CONNECT), 0)
end
fake = boot(function(f) f.setFile(DIR .. "/simulate", "needs_signin") end)
eq("service: simulate needs_signin row", row(fake, 0) and row(fake, 0).authorized, false)
eq("service: simulate needs_signin tile", model.barView(state(fake)).label, "!")
fake = boot(function(f) f.setFile(DIR .. "/simulate", "reboot_needed") end)
eq("service: simulate reboot_needed flag", state(fake).rebootNeeded, true)
eq("service: simulate reboot_needed row error", rowError(fake, 0) and rowError(fake, 0).key, "error.reboot_needed")
fake = boot(function(f) f.setFile(DIR .. "/simulate", "multi") end)
eq("service: simulate multi has three rows", #(state(fake).connections or {}), 3)
eq("service: simulate multi tile is On", model.barView(state(fake)).label, "On")
check("service: simulate multi uses fake hosts", (row(fake, 1) and row(fake, 1).host or ""):find("example", 1, true) ~= nil)
fake.noctalia.removeFile(DIR .. "/simulate")
queueRead(fake, "show-disconnected.txt")
send(fake, { action = "refresh" })
eq("service: simulate off reads the real state", #(state(fake).connections or {}), 1)
eq("service: simulate off clears the flag", state(fake).simulate, nil)
fake = bootWith("show-disconnected.txt", function(f) f.setFile(DIR .. "/simulate", "bogus") end)
eq("service: unknown simulate mode is ignored", state(fake).simulate, nil)
eq("service: unknown simulate mode reads the real state", count(fake, SHOW), 1)

-- ── debug marker ─────────────────────────────────────────────────────────────

fake = bootWith("show-connected.txt")
eq("service: no state.json without the marker", fake.files[DIR .. "/state.json"], nil)
fake.setFile(DIR .. "/debug", "")
queueRead(fake, "show-connected.txt")
send(fake, { action = "refresh" })
local dumped = fake.files[DIR .. "/state.json"]
check("service: debug marker writes state.json", dumped ~= nil)
local decoded = dumped and json.decode(dumped) or {}
eq("service: state.json has the connection", decoded.connections and decoded.connections[1] and decoded.connections[1].status, "CONNECTED")
eq("service: state.json has the dns count", decoded.connections and decoded.connections[1] and decoded.connections[1].dnsCount, 2)
check("service: state.json has no account, host or dns",
  dumped ~= nil and not dumped:find("example", 1, true) and not dumped:find("198.51.100", 1, true) and not dumped:find("@", 1, true))
eq("service: published snapshot keeps the host", row(fake, 0) and row(fake, 0).host, "vpn.example.com")

-- ── ipc ──────────────────────────────────────────────────────────────────────

fake = bootWith("show-disconnected.txt")
local seqIpc = state(fake).requestSeq
queueRead(fake, "show-connected.txt")
onIpc("request", '{"action":"refresh"}')
eq("service: ipc request is handled", state(fake).requestSeq, seqIpc + 1)
eq("service: ipc request refreshes", row(fake, 0) and row(fake, 0).status, "CONNECTED")
before = #fake.calls
onIpc("request", "not json")
onIpc("other", '{"action":"refresh"}')
eq("service: bad ipc ignored", #fake.calls, before)

current.uninstall()

-- stream-triggered passes keep a 2 s gap; the last trigger is never dropped
fake = bootWith("show-disconnected.txt")
local base = count(fake, SHOW)
queueRead(fake, "show-connected.txt")
fake.streamLine(1, CONNECTED_LINE)
eq("service: first stream refresh runs at once", count(fake, SHOW), base + 1)
queueRead(fake, "show-disconnected.txt")
fake.advance(500)
fake.streamLine(1, CONNECTED_LINE)
fake.streamLine(1, CONNECTED_LINE)
eq("service: stream refresh within 2 s is held", count(fake, SHOW), base + 1)
update()
eq("service: held stream refresh waits for the gap", count(fake, SHOW), base + 1)
fake.advance(1600)
update()
eq("service: held stream refresh runs once after the gap", count(fake, SHOW), base + 2)
fake.advance(3000)
update()
eq("service: held stream refresh is not repeated", count(fake, SHOW), base + 2)
