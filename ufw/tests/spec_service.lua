-- service.luau against the fake noctalia, with fixture files at /etc/ufw/*. Each test boots a
-- fresh service. The stub's readFileAsync and runAsync call back at once, so a whole read pass
-- (and a whole action) completes inside the call that started it.
local rules = loadModule("rules.luau")
local commands = loadModule("commands.luau")
local model = loadModule("model.luau")

local DATA = "/fake/plugin-data"
local P = {
  conf = "/etc/ufw/ufw.conf",
  defaults = "/etc/default/ufw",
  v4 = "/etc/ufw/user.rules",
  v6 = "/etc/ufw/user6.rules",
}
local SHOW = commands.SYSTEMCTL_SHOW
local SHOW_ACTIVE = "ActiveState=active\nUnitFileState=enabled\n"
local V4 = fixture("shapes.rules")
local V6 = fixture("shapes6.rules")
-- the v4-only "allow from 192.0.2.0/24 to any port 22 proto tcp" rule
local V4_ONLY_LINE = "### tuple ### allow tcp 22 0.0.0.0/0 any 192.0.2.0/24 in\n"
local V4_ONLY_ID = rules.ruleId({ action = "allow", direction = "in", proto = "tcp", port = "22",
  from = "192.0.2.0/24", to = "any", route = false })
local EXPECTED = rules.parseRules(V4, V6, true)

local function without(text, line)
  local s, e = string.find(text, line, 1, true)
  assert(s, "fixture line not found")
  return string.sub(text, 1, s - 1) .. string.sub(text, e + 1)
end

local ALL_LOGS = {}
local current

-- boot(setup) -> fake. Files are readable and the unit is active unless setup changes that.
local function boot(setup, opts)
  if current then current.uninstall() end
  local fake = stubs.newNoctalia()
  fake.sticky(SHOW) -- the unit keeps its last answered state
  fake.setFile(P.conf, fixture("conf-on.conf"), 100)
  fake.setFile(P.defaults, fixture("default-accept"), 100)
  fake.setFile(P.v4, V4, 100)
  fake.setFile(P.v6, V6, 100)
  if not (opts and opts.noShow) then
    fake.queue(SHOW, { stdout = SHOW_ACTIVE })
  end
  if setup then setup(fake) end
  fake.install()
  loadFresh("service.luau")
  current = fake
  ALL_LOGS[#ALL_LOGS + 1] = fake.logs
  return fake
end

local function state(fake)
  return fake.state["ufw.state"] or {}
end

local function send(fake, request)
  fake.noctalia.state.set("ufw.request", request)
end

local function tick(n)
  for _ = 1, n do update() end
end

local function etcReads(fake, from)
  local out = {}
  for i = (from or 0) + 1, #fake.fileReads do
    local path = fake.fileReads[i]
    if string.sub(path, 1, 5) == "/etc/" or string.sub(path, 1, 13) == "/fake/fixture" then
      out[#out + 1] = path
    end
  end
  return out
end

local function countReads(fake, path, from)
  local n = 0
  for _, p in ipairs(etcReads(fake, from)) do
    if p == path then n = n + 1 end
  end
  return n
end

local function pkexecCalls(fake)
  local out = {}
  for _, call in ipairs(fake.calls) do
    if call.argv[1] == "pkexec" then out[#out + 1] = call end
  end
  return out
end

local function findRule(snap, id)
  for _, r in ipairs(snap.rules or {}) do
    if r.id == id then return r end
  end
  return nil
end

local function dump(conf, defaults, v4, v6)
  return "@@file conf\n" .. conf .. "@@file defaults\n" .. defaults .. "@@file v4\n" .. v4
    .. "@@file v6\n" .. v6 .. "@@end\n"
end

local FULL_DUMP = dump(fixture("conf-on.conf"), fixture("default-accept"), V4, V6)

---------------------------------------------------------------------------
-- reading

local fake = boot()
local s = state(fake)
eq("service: first read publishes rules and status", #(s.rules or {}), #EXPECTED)
eq("service: first read source files", s.source, "files")
eq("service: first read status on", model.status(s), "on")
eq("service: first read enabled", s.enabled, true)
eq("service: first read default input", s.defaults and s.defaults.input, "ACCEPT")
eq("service: first read ipv6", s.defaults and s.defaults.ipv6, true)
eq("service: first read installed", s.installed, true)
eq("service: first read hasSystemctl", s.hasSystemctl, true)
eq("service: first read not busy", s.busy, false)
eq("service: first read no pending", #(s.pending or {}), 0)
eq("service: first read not test mode", s.testMode, false)
eq("service: polls on a 1 s tick", fake.updateInterval, 1000)
check("service: seq counts publishes", type(s.seq) == "number" and s.seq >= 1)
local typed, someRemovable = true, false
for _, r in ipairs(s.rules or {}) do
  if type(r.removable) ~= "boolean" then typed = false end
  if r.removable then someRemovable = true end
end
check("service: every rule has removable set", typed and someRemovable)
eq("service: removable matches commands", findRule(s, V4_ONLY_ID) and findRule(s, V4_ONLY_ID).removable, true)
eq("service: each file read once at start", #etcReads(fake), 4)
eq("service: started log", fake.logs[1], "ufw: service started")

-- mtime change re-reads only that file
fake = boot()
local before = #fake.fileReads
tick(3)
eq("service: unchanged files are not re-read", #etcReads(fake, before), 0)
fake.fileMeta[P.v6].mtime = 100.0000003 -- the host's mtime jitters below a microsecond
tick(3)
eq("service: mtime jitter is no change", #etcReads(fake, before), 0)
fake.setFile(P.v4, without(V4, V4_ONLY_LINE), 200)
tick(2)
eq("service: no mtime check before 3 s", #etcReads(fake, before), 0)
tick(1)
local reads = etcReads(fake, before)
eq("service: mtime change re-reads only that file", #reads == 1 and reads[1], P.v4)
fake.files[P.v6] = V6 .. "\n" -- same mtime, new size
fake.fileMeta[P.v6].size = #fake.files[P.v6]
before = #fake.fileReads
tick(3)
eq("service: size change re-reads", countReads(fake, P.v6, before), 1)
eq("service: mtime change updates the rules", #state(fake).rules, #EXPECTED - 1)
eq("service: changed rule is gone", findRule(state(fake), V4_ONLY_ID), nil)

-- incomplete read keeps the previous rules, and the next poll re-reads it
fake = boot()
local seqBefore = state(fake).seq
fake.setFile(P.v4, fixture("truncated.rules"), 200)
tick(3)
eq("service: incomplete read keeps previous rules", #state(fake).rules, #EXPECTED)
eq("service: incomplete read keeps source", state(fake).source, "files")
before = #fake.fileReads
fake.files[P.v4] = without(V4, V4_ONLY_LINE) -- same mtime as the truncated copy
tick(3)
eq("service: incomplete read is re-read on the next poll", countReads(fake, P.v4, before), 1)
eq("service: re-read after incomplete applies", #state(fake).rules, #EXPECTED - 1)
before = #fake.fileReads
tick(3)
eq("service: complete read stops the forced re-read", #etcReads(fake, before), 0)
check("service: seq never goes backwards", state(fake).seq > seqBefore)

-- a rules file that stays incomplete from the start: still "loading", and from the third
-- incomplete parse in a row the snapshot says so (the panel shows a line, not nothing)
fake = boot(function(f)
  f.setFile(P.v4, fixture("truncated.rules"), 100)
end)
eq("service: incomplete from the start stays loading", state(fake).source, "loading")
eq("service: one incomplete parse is not reported yet", state(fake).rulesIncomplete, false)
tick(3)
eq("service: two incomplete parses are not reported yet", state(fake).rulesIncomplete, false)
tick(3)
eq("service: three incomplete parses in a row are reported", state(fake).rulesIncomplete, true)
eq("service: still loading while incomplete", state(fake).source, "loading")
fake.files[P.v4] = V4
tick(3)
eq("service: a complete parse clears it", state(fake).rulesIncomplete, false)
eq("service: a complete parse reads the rules", state(fake).source, "files")
eq("service: a complete parse gives the rules", #state(fake).rules, #EXPECTED)

-- a read pass whose callback never arrives does not swallow later refreshes
fake = boot()
local req0 = state(fake).requestSeq
fake.refuseFileReads = true -- the host refuses every read: the pass waits on its retry
send(fake, { action = "refresh" })
eq("service: refresh waits on a stuck pass", state(fake).requestSeq, req0)
fake.advance(31000)
fake.refuseFileReads = false
send(fake, { action = "refresh" })
eq("service: stale pass's refresh is handled by the next pass", state(fake).requestSeq, req0 + 2)
tick(1) -- the old pass's retried read arrives late and is ignored
eq("service: late read of an orphaned pass is ignored", state(fake).requestSeq, req0 + 2)

-- unreadable files
fake = boot(function(f)
  f.unreadable[P.conf] = true
  f.unreadable[P.v4] = true
  f.unreadable[P.v6] = true
end)
s = state(fake)
eq("service: unreadable files give source none", s.source, "none")
eq("service: unreadable files give status unknown", model.status(s), "unknown")
eq("service: unreadable files give no rules", #(s.rules or {}), 0)
eq("service: unreadable files run no pkexec (load_rules is never automatic)", #pkexecCalls(fake), 0)
before = #fake.fileReads
tick(6)
eq("service: unreadable files are not re-read in a loop", #etcReads(fake, before), 0)

fake = boot(function(f) f.unreadable[P.v6] = true end)
eq("service: only user6.rules unreadable gives source none", state(fake).source, "none")
eq("service: only user6.rules unreadable keeps ufw.conf", state(fake).enabled, true)

fake = boot(function(f)
  f.setFile(P.defaults, fixture("default-ipv6-no"), 100)
  f.unreadable[P.v6] = true
end)
eq("service: user6.rules unreadable with IPV6=no is fine", state(fake).source, "files")
eq("service: IPV6=no reads v4 rules only", #state(fake).rules, #rules.parseRules(V4, nil, false))

-- before the first read lands nothing is known, and that is "loading", not unreadable
fake = boot(function(f) f.refuseFileReads = true end)
eq("service: source loading before the first read", state(fake).source, "loading")
eq("service: loading header is not Load rules", model.header(state(fake)).primary, nil)
fake.refuseFileReads = false
tick(1)
eq("service: source files once the first read lands", state(fake).source, "files")
eq("service: status once the first read lands", model.status(state(fake)), "on")

-- systemctl show
fake = boot(function(f)
  f.queue(SHOW, { stdout = "ActiveState=failed\nUnitFileState=disabled\n" })
end, { noShow = true })
s = state(fake)
eq("service: systemctl show maps to unit (active)", s.unit and s.unit.active, "failed")
eq("service: systemctl show maps to unit (boot)", s.unit and s.unit.bootEnabled, false)
eq("service: failed unit status", model.status(s), "failed")
local showCalls = 0
for _, call in ipairs(fake.calls) do
  if table.concat(call.argv, " ") == table.concat(SHOW, " ") then showCalls = showCalls + 1 end
end
eq("service: systemctl show runs at start", showCalls, 1)
fake.queue(SHOW, { stdout = SHOW_ACTIVE })
tick(4)
eq("service: no systemctl poll before 5 s", state(fake).unit.active, "failed")
tick(1)
eq("service: systemctl show polled every 5 s", state(fake).unit.active, "active")
fake.queue(SHOW, { exitCode = 1, stderr = "Failed to connect to bus" })
tick(5)
eq("service: failed systemctl show leaves the unit unknown", state(fake).unit.active, nil)
eq("service: failed systemctl show gives status unknown", model.status(state(fake)), "unknown")
fake.queue(SHOW, { timedOut = true, exitCode = -1 })
tick(5)
eq("service: timed-out systemctl show stays unknown", model.status(state(fake)), "unknown")
fake.queue(SHOW, { stdout = SHOW_ACTIVE })
tick(5)
eq("service: systemctl show answering again restores the status", model.status(state(fake)), "on")

-- no ufw unit (LoadState=not-found): ENABLED alone, and the actions use ufw itself
fake = boot(function(f)
  f.queue(SHOW, { stdout = "LoadState=not-found\nActiveState=inactive\nUnitFileState=\n" })
end, { noShow = true })
s = state(fake)
eq("service: unit not found publishes no systemctl", s.hasSystemctl, false)
eq("service: unit not found falls back to ENABLED (on)", model.status(s), "on")
fake.queue({ "pkexec" }, {})
send(fake, { action = "disable" })
eq("service: unit not found Turn off is ufw disable", table.concat((pkexecCalls(fake)[1] or { argv = {} }).argv, " "), "pkexec ufw disable")
fake = boot(function(f)
  f.setFile(P.conf, fixture("conf-off.conf"), 100)
  f.queue(SHOW, { stdout = "LoadState=not-found\nActiveState=inactive\nUnitFileState=\n" })
end, { noShow = true })
eq("service: unit not found falls back to ENABLED (off)", model.status(state(fake)), "off")
fake.queue({ "pkexec" }, {})
send(fake, { action = "enable" })
eq("service: unit not found Turn on is plain enable", table.concat((pkexecCalls(fake)[1] or { argv = {} }).argv, " "), "pkexec ufw --force enable")

fake = boot(function(f) f.commands.systemctl = false end, { noShow = true })
eq("service: no systemctl, no show call", #fake.calls, 0)
eq("service: no systemctl status on", model.status(state(fake)), "on")

---------------------------------------------------------------------------
-- staging

fake = boot()
send(fake, { action = "stage_add", port = "41000", proto = "tcp", comment = "e2e note" })
s = state(fake)
eq("service: stage add appears in pending", #s.pending, 1)
eq("service: staged add kind", s.pending[1] and s.pending[1].kind, "add")
eq("service: staged add port", s.pending[1] and s.pending[1].port, 41000)
eq("service: staged add proto", s.pending[1] and s.pending[1].proto, "tcp")
eq("service: stage add no error", s.lastError, nil)
send(fake, { action = "stage_add", port = "99999" })
eq("service: stage invalid port sets error key", state(fake).lastError and state(fake).lastError.key, "add.error_port")
eq("service: invalid port stages nothing", #state(fake).pending, 1)
onIpc("request", '{"action":"stage_add","port":41001}')
eq("service: IPC stage add", #state(fake).pending, 2)
check("service: op ids unique", state(fake).pending[1].id ~= state(fake).pending[2].id)
send(fake, { action = "unstage", id = state(fake).pending[1].id })
eq("service: unstage", #state(fake).pending, 1)
send(fake, { action = "discard" })
eq("service: discard", #state(fake).pending, 0)
send(fake, { action = "stage_remove", rule = "no-such-rule" })
eq("service: stage unknown rule", state(fake).lastError and state(fake).lastError.key, "error.not_removable")
send(fake, { action = "dismiss_error" })
eq("service: dismiss_error clears it", state(fake).lastError, nil)
send(fake, { action = "format_disk" })
eq("service: unknown action", state(fake).lastError and state(fake).lastError.key, "error.unknown_action")
local callsBefore = #fake.calls
send(fake, "not a table")
onIpc("request", "{not json")
onIpc("other", '{"action":"enable"}')
eq("service: junk requests run nothing", #fake.calls, callsBefore)

-- pending reconciles with an outside change
fake = boot()
send(fake, { action = "stage_remove", rule = V4_ONLY_ID })
eq("service: stage remove", #state(fake).pending, 1)
fake.setFile(P.v4, without(V4, V4_ONLY_LINE), 300)
tick(3)
eq("service: pending reconciles with outside change", #state(fake).pending, 0)
eq("service: reconcile notice key", state(fake).notice and state(fake).notice.key, "notice.pending_dropped")
eq("service: reconcile notice n", state(fake).notice and state(fake).notice.n, 1)

---------------------------------------------------------------------------
-- save

local ADDED_V4 = without(V4, V4_ONLY_LINE)
fake = boot(function(f)
  f.noctalia.tr = function(key, subst)
    if subst and subst.n ~= nil then return key .. " " .. tostring(subst.n) end
    return key
  end
end)
send(fake, { action = "stage_remove", rule = V4_ONLY_ID })
send(fake, { action = "stage_add", port = "41002", proto = "both" })
fake.queue({ "pkexec" }, { stdout = "@@op 1 ok\n@@op 2 ok\n" .. dump(fixture("conf-on.conf"), fixture("default-accept"), ADDED_V4, V6) })
fake.setFile(P.v4, ADDED_V4, 500) -- what ufw wrote; the re-read after the save sees it
send(fake, { action = "save" })
local saves = pkexecCalls(fake)
eq("service: save runs one pkexec", #saves, 1)
check("service: save argv is the batch", saves[1] ~= nil and saves[1].argv[4] == commands.BATCH_SCRIPT and saves[1].argv[5] == "ufw-batch")
eq("service: save has both ops", saves[1] and #saves[1].argv, 7)
eq("service: save timeout 60 s", saves[1] and saves[1].timeoutMs, 60000)
s = state(fake)
eq("service: save success clears pending", #s.pending, 0)
eq("service: save not busy after", s.busy, false)
eq("service: save dump updates rules", findRule(s, V4_ONLY_ID), nil)
eq("service: save keeps source files", s.source, "files")
eq("service: save success notifies count", #fake.notifications, 1)
local note = fake.notifications[1] or {}
eq("service: notification title", note.title, "plugin.name")
eq("service: notification body has only the count", (string.gsub(note.body or "", "%D", "")), "2")
eq("service: notification uses notice.saved", string.sub(note.body or "", 1, 12), "notice.saved")
eq("service: notification uses the plural key for 2", note.body, "notice.saved_other 2")

-- partial failure
fake = boot()
send(fake, { action = "stage_add", port = "41000" })
send(fake, { action = "stage_add", port = "41001" })
send(fake, { action = "stage_add", port = "41002" })
fake.queue({ "pkexec" }, { exitCode = 1,
  stdout = "@@op 1 ok\n@@op 2 fail 1\n@@msg ERROR: Bad port\n@@msg more\n" .. FULL_DUMP })
send(fake, { action = "save" })
s = state(fake)
eq("service: save partial failure keeps failed op with error", #s.pending, 2)
eq("service: partial failed op error is msg's first line", s.pending[1] and s.pending[1].error, "ERROR: Bad port")
eq("service: partial failed op is the second", s.pending[1] and s.pending[1].port, 41001)
eq("service: op that did not run stays pending", s.pending[2] and s.pending[2].port, 41002)
eq("service: op that did not run has no error", s.pending[2] and s.pending[2].error, nil)
eq("service: partial notifies the saved count", #fake.notifications, 1)
eq("service: partial is not busy", s.busy, false)
eq("service: partial save sets an error", s.lastError and s.lastError.key, "error.save_partial")
eq("service: partial save error counts what wasn't saved", s.lastError and s.lastError.n, 2)

-- dropped ops are never saved: one valid add plus a remove saveArgv can't encode
local realDeleteArgs = commands.deleteArgs
fake = boot(function(f)
  f.noctalia.tr = function(key, subst)
    if subst and subst.n ~= nil then return key .. " " .. tostring(subst.n) end
    return key
  end
end)
send(fake, { action = "stage_remove", rule = V4_ONLY_ID })
send(fake, { action = "stage_add", port = "41000" })
commands.deleteArgs = function() return nil end -- the rule's delete can't be rebuilt
fake.queue({ "pkexec" }, { stdout = "@@op 1 ok\n" .. FULL_DUMP })
send(fake, { action = "save" })
commands.deleteArgs = realDeleteArgs
s = state(fake)
saves = pkexecCalls(fake)
eq("service: dropped op is left out of the batch", saves[1] and #saves[1].argv, 6)
eq("service: dropped op stays pending", #s.pending, 1)
eq("service: dropped op is the remove", s.pending[1] and s.pending[1].kind, "remove")
eq("service: dropped op carries its errorKey", s.pending[1] and s.pending[1].errorKey, "error.not_removable")
eq("service: dropped op is not counted saved", (string.gsub((fake.notifications[1] or {}).body or "", "%D", "")), "1")
eq("service: dropped op sets the partial error", s.lastError and s.lastError.key, "error.save_partial")
eq("service: dropped op partial n", s.lastError and s.lastError.n, 1)

fake = boot()
send(fake, { action = "stage_remove", rule = V4_ONLY_ID })
commands.deleteArgs = function() return nil end
send(fake, { action = "save" })
commands.deleteArgs = realDeleteArgs
s = state(fake)
eq("service: all ops dropped runs nothing", #pkexecCalls(fake), 0)
eq("service: all ops dropped sets an error", s.lastError and s.lastError.key, "error.save_dropped")
eq("service: all ops dropped n", s.lastError and s.lastError.n, 1)
eq("service: all ops dropped keeps them", s.pending[1] and s.pending[1].errorKey, "error.not_removable")

-- Save while ufw is stopped (ENABLED=yes, unit inactive: the plugin's Turn off). The batch
-- reports `written` (rules file updated, running firewall not); the dump decides.
local ADD_TUPLE4 = "### tuple ### allow any 41002 0.0.0.0/0 any 0.0.0.0/0 in\n"
local ADD_TUPLE6 = "### tuple ### allow any 41002 ::/0 any ::/0 in\n"
local function withTuple(text, line)
  local s0 = string.find(text, "### END RULES ###", 1, true)
  assert(s0, "fixture has no END RULES")
  return string.sub(text, 1, s0 - 1) .. line .. string.sub(text, s0)
end
local STOPPED_V4 = withTuple(ADDED_V4, ADD_TUPLE4)
local STOPPED_V6 = withTuple(V6, ADD_TUPLE6)
local WRITTEN2 = "@@op 1 written 1\n@@msg ERROR: problem running\n@@op 2 written 1\n@@msg ERROR: problem running\n"
local function bootStopped()
  return boot(function(f)
    f.noctalia.tr = function(key, subst)
      if subst and subst.n ~= nil then return key .. " " .. tostring(subst.n) end
      return key
    end
    f.queue(SHOW, { stdout = "ActiveState=inactive\nUnitFileState=enabled\n" })
  end, { noShow = true })
end

fake = bootStopped()
eq("service: stopped save: starts stopped", model.status(state(fake)), "stopped")
send(fake, { action = "stage_remove", rule = V4_ONLY_ID })
send(fake, { action = "stage_add", port = "41002", proto = "both" })
fake.queue({ "pkexec" }, { stdout = WRITTEN2 .. dump(fixture("conf-on.conf"), fixture("default-accept"), STOPPED_V4, STOPPED_V6) })
fake.setFile(P.v4, STOPPED_V4, 500)
fake.setFile(P.v6, STOPPED_V6, 500)
send(fake, { action = "save" })
s = state(fake)
eq("service: stopped save: one pkexec for both ops", #pkexecCalls(fake), 1)
eq("service: stopped save: both ops leave pending", #s.pending, 0)
eq("service: stopped save: no error", s.lastError, nil)
eq("service: stopped save: notice says when it takes effect", s.notice and s.notice.key, "notice.saved_not_live")
eq("service: stopped save: notice counts the saved ops", s.notice and s.notice.n, 2)
eq("service: stopped save: one notification", #fake.notifications, 1)
eq("service: stopped save: notification says when it takes effect", (fake.notifications[1] or {}).body, "notice.saved_not_live_other 2")
eq("service: stopped save: rules from the dump", findRule(s, V4_ONLY_ID), nil)

-- written, but the dump does not show it (the add has no IPv6 copy, the remove's rule is still there)
fake = bootStopped()
send(fake, { action = "stage_remove", rule = V4_ONLY_ID })
send(fake, { action = "stage_add", port = "41002", proto = "both" })
fake.queue({ "pkexec" }, { stdout = WRITTEN2 .. dump(fixture("conf-on.conf"), fixture("default-accept"), withTuple(V4, ADD_TUPLE4), V6) })
send(fake, { action = "save" })
s = state(fake)
eq("service: unconfirmed written ops stay pending", #s.pending, 2)
eq("service: unconfirmed written op keeps ufw's line", s.pending[1] and s.pending[1].error, "ERROR: problem running")
eq("service: unconfirmed written ops are a partial save", s.lastError and s.lastError.key, "error.save_partial")
eq("service: unconfirmed written ops partial n", s.lastError and s.lastError.n, 2)
eq("service: unconfirmed written ops: no notice", s.notice, nil)
eq("service: unconfirmed written ops: no notification", #fake.notifications, 0)

-- written without a complete dump: nothing can confirm it
fake = bootStopped()
send(fake, { action = "stage_add", port = "41002", proto = "both" })
fake.queue({ "pkexec" }, { stdout = "@@op 1 written 1\n@@msg ERROR: problem running\n@@file conf\nENABLED=yes\n" })
send(fake, { action = "save" })
s = state(fake)
eq("service: written op without a full dump stays pending", #s.pending, 1)
eq("service: written op without a full dump is a partial save", s.lastError and s.lastError.key, "error.save_partial")

-- one live, one written (a mixed result): every op saved, the notice still says when
fake = bootStopped()
send(fake, { action = "stage_remove", rule = V4_ONLY_ID })
send(fake, { action = "stage_add", port = "41002", proto = "both" })
fake.queue({ "pkexec" }, { stdout = "@@op 1 ok\n@@op 2 written 1\n@@msg ERROR: problem running\n"
  .. dump(fixture("conf-on.conf"), fixture("default-accept"), STOPPED_V4, STOPPED_V6) })
send(fake, { action = "save" })
s = state(fake)
eq("service: ok plus written: both saved", #s.pending, 0)
eq("service: ok plus written: notice", s.notice and s.notice.key, "notice.saved_not_live")

-- written while ufw was on (unit active): the live update failed, so it is not saved, even
-- though the dump shows the rules files changed
fake = boot(function(f)
  f.noctalia.tr = function(key, subst)
    if subst and subst.n ~= nil then return key .. " " .. tostring(subst.n) end
    return key
  end
end)
eq("service: written while on: starts on", model.status(state(fake)), "on")
send(fake, { action = "stage_remove", rule = V4_ONLY_ID })
send(fake, { action = "stage_add", port = "41002", proto = "both" })
fake.queue({ "pkexec" }, { stdout = WRITTEN2 .. dump(fixture("conf-on.conf"), fixture("default-accept"), STOPPED_V4, STOPPED_V6) })
fake.setFile(P.v4, STOPPED_V4, 500)
fake.setFile(P.v6, STOPPED_V6, 500)
send(fake, { action = "save" })
s = state(fake)
eq("service: written while on: one pkexec", #pkexecCalls(fake), 1)
eq("service: written while on: both ops stay pending (the re-read does not reconcile them away)", #s.pending, 2)
eq("service: written while on: keeps ufw's line", s.pending[1] and s.pending[1].error, "ERROR: problem running")
eq("service: written while on: the add keeps ufw's line", s.pending[2] and s.pending[2].error, "ERROR: problem running")
eq("service: written while on: a partial save", s.lastError and s.lastError.key, "error.save_partial")
eq("service: written while on: partial n", s.lastError and s.lastError.n, 2)
eq("service: written while on: no saved notice", s.notice, nil)
eq("service: written while on: no notification", #fake.notifications, 0)
eq("service: written while on: the files were re-read", findRule(s, V4_ONLY_ID), nil)
-- the next root action (here Turn off) ends that: its re-read reconciles them away
fake.queue({ "pkexec" }, { exitCode = 0 })
send(fake, { action = "disable" })
s = state(fake)
eq("service: written while on: after the next action the ops reconcile away", #s.pending, 0)
eq("service: written while on: the reconcile notice", s.notice and s.notice.key, "notice.pending_dropped")

-- a read pass landing during a Save does not reconcile
fake = boot()
send(fake, { action = "stage_remove", rule = V4_ONLY_ID })
fake.refuseFileReads = true -- the refresh's pass waits on a refused read
send(fake, { action = "refresh" })
fake.queue({ "pkexec" }, { defer = true })
send(fake, { action = "save" })
eq("service: save started over a stuck pass", state(fake).busyAction, "save")
fake.setFile(P.v4, without(V4, V4_ONLY_LINE), 300)
fake.refuseFileReads = false
tick(1) -- the retried read lands: the pass finishes during the Save
eq("service: re-read during a save happened", findRule(state(fake), V4_ONLY_ID), nil)
eq("service: re-read during a save does not reconcile", #state(fake).pending, 1)
eq("service: re-read during a save sets no notice", state(fake).notice, nil)

-- cancelled / timeout / no agent
fake = boot()
send(fake, { action = "stage_add", port = "41000" })
fake.queue({ "pkexec" }, { exitCode = 126 })
send(fake, { action = "save" })
eq("service: save cancelled keeps pending", #state(fake).pending, 1)
eq("service: save cancelled notice", state(fake).notice and state(fake).notice.key, "notice.cancelled")
eq("service: save cancelled no error on op", state(fake).pending[1].error, nil)
eq("service: save cancelled no notification", #fake.notifications, 0)

fake = boot()
send(fake, { action = "stage_add", port = "41000" })
fake.queue({ "pkexec" }, { exitCode = 1, timedOut = true })
send(fake, { action = "save" })
eq("service: save timeout keeps pending", #state(fake).pending, 1)
eq("service: save timeout error", state(fake).lastError and state(fake).lastError.key, "error.timeout")

fake = boot()
send(fake, { action = "stage_add", port = "41000" })
fake.queue({ "pkexec" }, { exitCode = 127, stderr = "Error: no authentication agent found." })
send(fake, { action = "save" })
s = state(fake)
eq("service: no agent sets polkit fallback", s.polkitFallback and s.polkitFallback["for"], "save")
eq("service: no agent error key", s.lastError and s.lastError.key, "error.no_polkit_agent")
eq("service: no agent keeps pending", #s.pending, 1)
fake.queue({ "pkexec" }, { exitCode = 1, stderr = "Error: no authentication agent found." })
send(fake, { action = "disable" })
eq("service: no agent on disable names it", state(fake).polkitFallback and state(fake).polkitFallback["for"], "disable")
fake.queue({ "noctalia", "msg", "config-set" }, { defer = true })
send(fake, { action = "enable_polkit_agent" })
local agentCall = nil
for _, call in ipairs(fake.calls) do
  if call.argv[1] == "noctalia" then agentCall = call end
end
eq("service: enable_polkit_agent runs its argv", agentCall and table.concat(agentCall.argv, " "),
  table.concat(commands.argv("enable_polkit_agent"), " "))
eq("service: enable_polkit_agent takes the busy slot", state(fake).busyAction, "enable_polkit_agent")
send(fake, { action = "save" })
eq("service: save refused while the agent is enabled", state(fake).lastError and state(fake).lastError.key, "error.busy")
fake.flush()
eq("service: enable_polkit_agent clears the fallback", state(fake).polkitFallback, nil)
eq("service: enable_polkit_agent ends busy", state(fake).busy, false)
eq("service: enable_polkit_agent clears the error", state(fake).lastError, nil)

fake = boot()
fake.queue({ "pkexec" }, { exitCode = 127 })
send(fake, { action = "enable" })
fake.queue({ "noctalia", "msg", "config-set" }, { exitCode = 1, stderr = "config-set failed\n" })
send(fake, { action = "enable_polkit_agent" })
eq("service: failed agent enable keeps the fallback", state(fake).polkitFallback and state(fake).polkitFallback["for"], "enable")
eq("service: failed agent enable error", state(fake).lastError and state(fake).lastError.key, "error.command_failed")

-- save with nothing pending runs nothing
fake = boot()
send(fake, { action = "save" })
eq("service: empty save runs nothing", #pkexecCalls(fake), 0)

---------------------------------------------------------------------------
-- busy

fake = boot()
fake.queue({ "pkexec" }, { defer = true })
send(fake, { action = "enable" })
eq("service: busy while an action runs", state(fake).busy, true)
eq("service: busyAction names it", state(fake).busyAction, "enable")
send(fake, { action = "disable" })
eq("service: second request while busy is rejected", state(fake).lastError and state(fake).lastError.key, "error.busy")
eq("service: rejected request runs nothing", #pkexecCalls(fake), 1)
send(fake, { action = "stage_add", port = "41000" })
eq("service: staging allowed while another action runs", #state(fake).pending, 1)
before = #fake.fileReads
tick(6)
eq("service: no polling while busy", #etcReads(fake, before), 0)
fake.flush()
eq("service: busy cleared when the action ends", state(fake).busy, false)
check("service: re-read after the action", countReads(fake, P.conf, before) >= 1)

fake = boot()
send(fake, { action = "stage_add", port = "41000" })
fake.queue({ "pkexec" }, { defer = true })
send(fake, { action = "save" })
eq("service: save is busy", state(fake).busyAction, "save")
send(fake, { action = "stage_add", port = "41001" })
eq("service: staging blocked while saving", state(fake).lastError and state(fake).lastError.key, "error.busy")
eq("service: blocked stage adds nothing", #state(fake).pending, 1)
fake.flush()
eq("service: lost save leaves pending (exit 0, no output)", #state(fake).pending, 1)
eq("service: lost save error", state(fake).lastError and state(fake).lastError.key, "error.save_failed")

-- watchdog: a callback that never arrives
fake = boot()
fake.queue({ "pkexec" }, { defer = true })
send(fake, { action = "disable" })
fake.advance(70000)
tick(1)
eq("service: watchdog clears busy", state(fake).busy, false)
eq("service: watchdog error", state(fake).lastError and state(fake).lastError.key, "error.timeout")

---------------------------------------------------------------------------
-- root actions

fake = boot()
fake.queue({ "pkexec" }, {})
send(fake, { action = "enable" })
local calls = pkexecCalls(fake)
eq("service: enable picks argv by unit state (active)", calls[1] and table.concat(calls[1].argv, " "), "pkexec ufw --force enable")
eq("service: enable timeout 60 s", calls[1] and calls[1].timeoutMs, 60000)

fake = boot(function(f)
  f.setFile(P.conf, fixture("conf-off.conf"), 100)
  f.queue(SHOW, { stdout = "ActiveState=inactive\nUnitFileState=enabled\n" })
end, { noShow = true })
fake.queue({ "pkexec" }, {})
before = #fake.fileReads
send(fake, { action = "enable" })
calls = pkexecCalls(fake)
check("service: enable picks argv by unit state (ENABLED=no, inactive)", calls[1] ~= nil and calls[1].argv[2] == "/bin/sh" and calls[1].argv[4] == commands.ENABLE_AND_START)
eq("service: action refreshes the files", countReads(fake, P.conf, before), 1)

for _, case in ipairs({
  { "disable", "pkexec systemctl stop ufw" },
  { "start_service", "pkexec systemctl start ufw" },
  { "enable_at_boot", "pkexec systemctl enable ufw" },
}) do
  fake = boot()
  fake.queue({ "pkexec" }, {})
  send(fake, { action = case[1] })
  calls = pkexecCalls(fake)
  eq("service: " .. case[1] .. " argv", calls[1] and table.concat(calls[1].argv, " "), case[2])
end

fake = boot()
fake.queue({ "pkexec" }, { exitCode = 126 })
send(fake, { action = "disable" })
eq("service: cancelled action notice", state(fake).notice and state(fake).notice.key, "notice.cancelled")
fake.queue({ "pkexec" }, { exitCode = 1, stderr = "ERROR: something\n" })
send(fake, { action = "disable" })
eq("service: failed action error", state(fake).lastError and state(fake).lastError.key, "error.command_failed")

-- run_in_terminal
fake = boot()
send(fake, { action = "run_in_terminal", ["for"] = "rm -rf /" })
eq("service: run_in_terminal only runs table constants", #fake.terminalCalls, 0)
send(fake, { action = "run_in_terminal", ["for"] = "__index" })
send(fake, { action = "run_in_terminal" })
eq("service: run_in_terminal ignores odd keys", #fake.terminalCalls, 0)
send(fake, { action = "run_in_terminal", ["for"] = "enable" })
eq("service: run_in_terminal runs the constant", fake.terminalCalls[1], commands.TERMINAL_COMMANDS.enable)
send(fake, { action = "run_in_terminal", ["for"] = "stop_service" })
eq("service: run_in_terminal takes action names, not constant names", #fake.terminalCalls, 1)
fake = boot()
send(fake, { action = "run_in_terminal", ["for"] = "disable" })
eq("service: run_in_terminal for=disable stops ufw", fake.terminalCalls[1], "sudo systemctl stop ufw")
-- Turn on with ENABLED=no and the unit inactive: the terminal also enables and starts
do
  local offFake = boot(function(f)
    f.setFile(P.conf, fixture("conf-off.conf"), 100)
    f.queue(SHOW, { stdout = "ActiveState=inactive\nUnitFileState=enabled\n" })
  end, { noShow = true })
  send(offFake, { action = "run_in_terminal", ["for"] = "enable" })
  eq("service: run_in_terminal for=enable from off and inactive enables and starts", offFake.terminalCalls[1],
    "sudo sh -c 'ufw --force enable && systemctl start ufw'")
  local stoppedFake = boot(function(f)
    f.queue(SHOW, { stdout = "ActiveState=inactive\nUnitFileState=enabled\n" })
  end, { noShow = true })
  send(stoppedFake, { action = "run_in_terminal", ["for"] = "enable" })
  eq("service: run_in_terminal for=enable from stopped starts the unit", stoppedFake.terminalCalls[1], "sudo systemctl start ufw")
end
fake = boot()
send(fake, { action = "run_in_terminal", ["for"] = "disable" })
before = #fake.fileReads
fake.advance(4000)
tick(1)
eq("service: no terminal refresh before 5 s", countReads(fake, P.conf, before), 0)
fake.advance(1500)
tick(1)
eq("service: terminal refresh after 5 s", countReads(fake, P.conf, before), 1)

-- load_rules
fake = boot(function(f)
  f.unreadable[P.conf] = true
  f.unreadable[P.v4] = true
  f.unreadable[P.v6] = true
end)
fake.queue({ "pkexec" }, { stdout = FULL_DUMP })
send(fake, { action = "load_rules" })
calls = pkexecCalls(fake)
eq("service: load_rules argv", calls[1] and #calls[1].argv, 5)
s = state(fake)
eq("service: load_rules sets source root", s.source, "root")
eq("service: load_rules reads the rules", #s.rules, #EXPECTED)
eq("service: load_rules reads ufw.conf", s.enabled, true)
check("service: load_rules sets removable", findRule(s, V4_ONLY_ID) and findRule(s, V4_ONLY_ID).removable == true)
tick(6)
eq("service: root rules kept while files stay unreadable", state(fake).source, "root")
send(fake, { action = "refresh" })
eq("service: root rules kept across a refresh", #state(fake).rules, #EXPECTED)
fake.unreadable[P.conf] = nil
fake.unreadable[P.v4] = nil
fake.unreadable[P.v6] = nil
send(fake, { action = "refresh" })
eq("service: readable files replace root rules", state(fake).source, "files")

fake = boot(function(f) f.unreadable[P.v4] = true; f.unreadable[P.v6] = true end)
send(fake, { action = "stage_add", port = "41000" })
fake.queue({ "pkexec" }, { stdout = "@@op 1 ok\n" .. FULL_DUMP })
send(fake, { action = "save" })
eq("service: save dump with unreadable files gives source root", state(fake).source, "root")
eq("service: save dump with unreadable files gives its rules", #state(fake).rules, #EXPECTED)
eq("service: save dump saved the op", #state(fake).pending, 0)

-- root-loaded mode: Turn off / Turn on leave no dump, so their success sets `enabled`
fake = boot(function(f)
  f.unreadable[P.conf] = true
  f.unreadable[P.v4] = true
  f.unreadable[P.v6] = true
end)
fake.queue({ "pkexec" }, { stdout = FULL_DUMP })
send(fake, { action = "load_rules" })
eq("service: root-loaded ufw on", model.status(state(fake)), "on")
fake.queue({ "pkexec" }, {})
fake.queue(SHOW, { stdout = "ActiveState=inactive\nUnitFileState=enabled\n" })
send(fake, { action = "disable" })
eq("service: root-loaded turn off stops the unit, enabled stays", state(fake).enabled, true)
eq("service: root-loaded turn off shows stopped", model.status(state(fake)), "stopped")
fake.queue({ "pkexec" }, {})
fake.queue(SHOW, { stdout = SHOW_ACTIVE })
send(fake, { action = "enable" })
eq("service: root-loaded enable from stopped argv", table.concat(pkexecCalls(fake)[3].argv, " "), "pkexec systemctl start ufw")
eq("service: root-loaded enable sets enabled true", state(fake).enabled, true)
eq("service: root-loaded enable shows on", model.status(state(fake)), "on")
fake.queue({ "pkexec" }, { exitCode = 126 })
send(fake, { action = "disable" })
eq("service: cancelled disable leaves enabled", state(fake).enabled, true)

-- without systemctl the legacy `ufw disable` is all there is, and its success is all we know
fake = boot(function(f)
  f.commands.systemctl = false
  f.unreadable[P.conf] = true
  f.unreadable[P.v4] = true
  f.unreadable[P.v6] = true
end, { noShow = true })
fake.queue({ "pkexec" }, { stdout = FULL_DUMP })
send(fake, { action = "load_rules" })
fake.queue({ "pkexec" }, {})
send(fake, { action = "disable" })
eq("service: legacy disable argv", table.concat(pkexecCalls(fake)[2].argv, " "), "pkexec ufw disable")
eq("service: root-loaded legacy disable sets enabled false", state(fake).enabled, false)
eq("service: root-loaded legacy disable shows off", model.status(state(fake)), "off")
tick(6)
send(fake, { action = "refresh" })
eq("service: root-loaded off survives polls and refresh", state(fake).enabled, false)

fake = boot(function(f) f.unreadable[P.conf] = true end)
eq("service: unreadable ufw.conf is unknown", state(fake).enabled, nil)
fake.queue({ "pkexec" }, {})
send(fake, { action = "disable" })
-- never loaded as root and ufw.conf unreadable: a stop tells us nothing, so it stays unknown
-- (Load rules is offered), which is honest
eq("service: turn off with unreadable ufw.conf stays unknown", state(fake).enabled, nil)
fake.unreadable[P.conf] = nil
send(fake, { action = "refresh" })
eq("service: readable ufw.conf wins again", state(fake).enabled, true)

fake = boot()
fake.queue({ "pkexec" }, {})
send(fake, { action = "disable" })
eq("service: readable ufw.conf is not guessed", state(fake).enabled, true) -- the fixture file still says yes
-- Turn off stops the unit: the files still say ENABLED=yes, so the status is stopped
fake = boot()
fake.queue({ "pkexec" }, {})
fake.queue(SHOW, { stdout = "ActiveState=inactive\nUnitFileState=enabled\n" })
send(fake, { action = "disable" })
eq("service: turn off leaves enabled true", state(fake).enabled, true)
eq("service: turn off shows stopped", model.status(state(fake)), "stopped")
fake.queue({ "pkexec" }, {})
send(fake, { action = "enable" })
eq("service: enable from stopped argv", table.concat(pkexecCalls(fake)[2].argv, " "), "pkexec systemctl start ufw")

---------------------------------------------------------------------------
-- debug file and test mode

local function leaks(text)
  local found = {}
  for _, r in ipairs(EXPECTED) do
    for n in string.gmatch((r.port or "") .. "," .. (r.fromPort or ""), "%d+") do
      if tonumber(n) > 1000 and string.find(text, n, 1, true) then found[#found + 1] = n end
    end
    for _, v in ipairs({ r.from, r.to, r.comment, r.iface, r.app }) do
      if v ~= nil and v ~= "any" and string.find(text, v, 1, true) then found[#found + 1] = v end
    end
  end
  for _, v in ipairs({ "41000", "41001", "41002", "e2e note", "192.0.2", "2001:db8", "198.51.100" }) do
    if string.find(text, v, 1, true) then found[#found + 1] = v end
  end
  return found
end

fake = boot()
send(fake, { action = "refresh" })
eq("service: no debug file without the marker", fake.files[DATA .. "/state.json"], nil)
fake.files[DATA .. "/debug"] = ""
send(fake, { action = "stage_add", port = "41000", comment = "e2e note" })
local debugText = fake.files[DATA .. "/state.json"]
check("service: debug file only with marker", debugText ~= nil)
local view = debugText and json.decode(debugText) or {}
eq("service: debug file status", view.status, "on")
eq("service: debug file allowedCount", view.allowedCount, model.allowedCount(EXPECTED))
eq("service: debug file pendingCount", view.pendingCount, 1)
eq("service: debug file has seq", view.seq, state(fake).seq)
eq("service: debug file has no rule data", #leaks(debugText or ""), 0)

fake = boot(function(f)
  f.files[DATA .. "/debug"] = ""
  f.files[DATA .. "/fixture-root"] = "/fake/fixture\n"
  f.setFile("/fake/fixture/ufw/ufw.conf", fixture("conf-off.conf"), 1)
  f.setFile("/fake/fixture/default/ufw", fixture("default-ipv6-no"), 1)
  f.setFile("/fake/fixture/ufw/user.rules", V4, 1)
  f.setFile("/fake/fixture/ufw/user6.rules", V6, 1)
end)
s = state(fake)
eq("service: test mode flag", s.testMode, true)
eq("service: test mode reads fixture root", s.enabled, false)
eq("service: test mode reads fixture defaults", s.defaults.input, "DROP")
eq("service: test mode reads no /etc file", countReads(fake, P.conf) + countReads(fake, P.v4), 0)
eq("service: test mode rules", #s.rules, #rules.parseRules(V4, nil, false))
for _, action in ipairs({ "enable", "disable", "start_service", "enable_at_boot", "load_rules", "enable_polkit_agent" }) do
  send(fake, { action = action })
  eq("service: test mode refuses " .. action, state(fake).lastError and state(fake).lastError.key, "error.test_mode")
end
send(fake, { action = "stage_add", port = "41000" })
eq("service: test mode still stages", #state(fake).pending, 1)
send(fake, { action = "save" })
eq("service: test mode refuses save", state(fake).lastError and state(fake).lastError.key, "error.test_mode")
send(fake, { action = "run_in_terminal", ["for"] = "enable" })
eq("service: test mode refuses run_in_terminal", #fake.terminalCalls, 0)
eq("service: test mode refuses root actions", #pkexecCalls(fake), 0)
local agentRuns = 0
for _, call in ipairs(fake.calls) do
  if call.argv[1] == "noctalia" then agentRuns = agentRuns + 1 end
end
eq("service: test mode refuses enable_polkit_agent", agentRuns, 0)
check("service: debug file written in test mode", fake.files[DATA .. "/state.json"] ~= nil)
fake.files[DATA .. "/debug"] = nil
tick(3)
eq("service: test mode ends with the marker", state(fake).testMode, false)
eq("service: test mode end re-reads /etc", state(fake).enabled, true)
eq("service: ops staged in test mode are gone after leaving it", #state(fake).pending, 0)
eq("service: state.json removed with the marker", fake.files[DATA .. "/state.json"], nil)

local function bootTestMode(setup)
  return boot(function(f)
    f.files[DATA .. "/debug"] = ""
    f.files[DATA .. "/fixture-root"] = "/fake/fixture\n"
    f.setFile("/fake/fixture/ufw/ufw.conf", fixture("conf-on.conf"), 1)
    f.setFile("/fake/fixture/default/ufw", fixture("default-accept"), 1)
    f.setFile("/fake/fixture/ufw/user.rules", V4, 1)
    f.setFile("/fake/fixture/ufw/user6.rules", V6, 1)
    if setup then setup(f) end
  end)
end

-- the markers appear: the very next root action is refused (no poll needed)
fake = boot()
fake.files[DATA .. "/debug"] = ""
fake.files[DATA .. "/fixture-root"] = "/fake/fixture\n"
fake.setFile("/fake/fixture/ufw/ufw.conf", fixture("conf-off.conf"), 1)
fake.queue({ "pkexec" }, {})
send(fake, { action = "enable" })
eq("service: root action right after the markers appear is refused", state(fake).lastError and state(fake).lastError.key, "error.test_mode")
eq("service: no pkexec right after the markers appear", #pkexecCalls(fake), 0)
eq("service: test mode on at once", state(fake).testMode, true)

-- leaving test mode: a Save right after can't use fixture rules or fixture-staged ops
fake = bootTestMode(function(f)
  f.unreadable[P.v4] = true
  f.unreadable[P.v6] = true
end)
send(fake, { action = "stage_remove", rule = V4_ONLY_ID })
eq("service: fixture remove staged in test mode", #state(fake).pending, 1)
fake.files[DATA .. "/debug"] = nil
fake.queue({ "pkexec" }, { stdout = "@@op 1 ok\n" .. FULL_DUMP })
send(fake, { action = "save" })
eq("service: save right after leaving test mode runs nothing", #pkexecCalls(fake), 0)
eq("service: fixture-staged op gone", #state(fake).pending, 0)
eq("service: fixture rules gone (real rules unreadable)", state(fake).source, "none")
send(fake, { action = "stage_remove", rule = V4_ONLY_ID })
eq("service: fixture rule can't be staged after leaving", state(fake).lastError and state(fake).lastError.key, "error.not_removable")

-- leaving test mode while reads are held up: nothing from the fixtures is offered meanwhile
fake = bootTestMode()
fake.refuseFileReads = true
fake.files[DATA .. "/debug"] = nil
send(fake, { action = "stage_remove", rule = V4_ONLY_ID })
eq("service: no fixture rules before the re-read lands", state(fake).lastError and state(fake).lastError.key, "error.not_removable")
eq("service: source loading before the re-read lands", state(fake).source, "loading")
fake.refuseFileReads = false
tick(1)
eq("service: real rules after the re-read lands", state(fake).source, "files")
eq("service: real ufw.conf after the re-read lands", state(fake).enabled, true)

fake = boot(function(f)
  f.files[DATA .. "/fixture-root"] = "/fake/fixture\n"
end)
eq("service: fixture-root alone is not test mode", state(fake).testMode, false)

---------------------------------------------------------------------------
-- logs

check("service: leak check finds fixture data", #leaks("x 5173 y") > 0 and #leaks("api dev server") > 0 and #leaks("2001:db8::/32") > 0)
if current then current.uninstall() end
local leaked, badShape = {}, 0
for _, logs in ipairs(ALL_LOGS) do
  for _, line in ipairs(logs) do
    for _, v in ipairs(leaks(line)) do leaked[#leaked + 1] = v end
    if not string.match(line, "^ufw: [%w_]+") then badShape = badShape + 1 end
  end
end
eq("service: logs carry no rule data", #leaked, 0)
eq("service: logs are 'ufw: <event> ...'", badShape, 0)
