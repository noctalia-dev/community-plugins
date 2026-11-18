--!nonstrict
-- UFW service: the only entry that reads ufw's files or runs a process.
--
--   noctalia.state.set("ufw.state", snapshot)     the bar and the panel render this
--   noctalia.state.watch("ufw.request", handler)  requests from the bar and the panel
--   noctalia msg plugin 3dprogramin/ufw:service all request '<json>'   the same, over IPC
--
-- Reading (no root): /etc/ufw/ufw.conf, /etc/default/ufw, /etc/ufw/user.rules and
-- /etc/ufw/user6.rules, one readFileAsync per callback. The update() tick (1 s) checks the four
-- files' mtime and size every 3 s and re-reads only the files that changed (plus both rules
-- files while the last parse was incomplete), and runs `systemctl show ufw` every 5 s. A failed
-- `systemctl show` leaves the unit unknown; a ufw unit systemd doesn't know (LoadState
-- not-found) is treated like no systemctl.
-- Everything is re-read after each action and on a `refresh` request (the panel opening).
-- Rules are parsed in a callback of their own, after the reads.
--
-- Until the first read pass lands the source is "loading" (nothing read yet, not unreadable).
-- A rules file without its END RULES marker keeps the previous rules (or "loading") and is
-- re-read every poll; after 3 incomplete parses in a row the snapshot says rulesIncomplete.
-- A rules file that can't be read gives source "none" (the panel offers Load rules, which is
-- never run automatically). Load rules, and a Save while the files are unreadable, take the
-- rules from the batch script's dump: source "root", kept until the files are readable again.
--
-- Root actions (Save, Turn on/off, Start ufw, Start at boot, Load rules) run one at a time
-- through pkexec with a 60 s timeout; any other request while one runs gets error.busy.
-- Staging (stage_add, stage_remove, unstage, discard) runs any time except during a Save.
-- The staged changes live here, in memory only. A Save while ufw is stopped gets `written` ops
-- back (rules file updated, running firewall not): they count as saved only when ufw was not on
-- before the Save and the dump shows them, and the notice says they take effect when ufw is
-- turned on. A `written` op while ufw was on is a failure.
--
-- Privacy: noctalia.log gets "ufw: <event> <count or key>" only, the one notification (after
-- a Save) carries a count only, and the debug file holds model.debugView() (counts and keys).
--
-- Files in <pluginDataDir>: while `debug` exists, every publish writes `state.json`. While both
-- `debug` and `fixture-root` exist, the four files are read from the directory named in
-- `fixture-root` (laid out like /etc: ufw/ufw.conf, default/ufw, ufw/user.rules,
-- ufw/user6.rules) and every root action is refused with error.test_mode.

local rules = require("./rules.luau")
local commands = require("./commands.luau")
local model = require("./model.luau")

local TICK_MS = 1000
local FILE_POLL_TICKS = 3
local UNIT_POLL_TICKS = 5
local ROOT_TIMEOUT_MS = 60000
local READ_TIMEOUT_MS = 10000
local TERMINAL_REFRESH_MS = 5000
-- A callback that never arrives must not wedge the service: busy is cleared, and a read pass
-- or a systemctl read no longer blocks the next one, this long after its timeout.
local WATCHDOG_SLACK_MS = 5000
local STALE_MS = 30000
local MAX_DETAIL = 200
local STATE_KEY = "ufw.state"
local REQUEST_KEY = "ufw.request"
local DEBUG_MARKER = "debug"
local DEBUG_FILE = "state.json"
local FIXTURE_ROOT = "fixture-root"
-- Read through readFileAsync only so its completion arrives as a new callback.
local YIELD_FILE = "plugin.toml"

local NAMES = { "conf", "defaults", "v4", "v6" }
local RELATIVE = {
  conf = "/ufw/ufw.conf",
  defaults = "/default/ufw",
  v4 = "/ufw/user.rules",
  v6 = "/ufw/user6.rules",
}
local STAGING = { stage_add = true, stage_remove = true, unstage = true, discard = true }
local SIMPLE_ROOT = { enable = true, disable = true, start_service = true, enable_at_boot = true }
local ROOT_ACTIONS = {
  save = true, enable = true, disable = true, start_service = true, enable_at_boot = true,
  load_rules = true, run_in_terminal = true, enable_polkit_agent = true,
}
-- Errors a successful stage replaces.
local STAGE_ERRORS = {
  ["error.not_removable"] = true, ["error.busy"] = true, ["error.unknown_action"] = true,
}

-- ── state ────────────────────────────────────────────────────────────────────

local installed = noctalia.commandExists("ufw") == true
local systemctlFound = noctalia.commandExists("systemctl") == true
-- systemctl is there and knows a ufw unit (LoadState not "not-found"); otherwise the status
-- falls back to ENABLED alone and Turn on / Turn off use ufw itself, as without systemctl.
local hasSystemctl = systemctlFound
local enabled = nil
local defaults = rules.parseDefaults(nil)
local unit = {}
local ruleList = {}
-- "loading" until the first read pass sets "files" / "none" / "root": not read yet is not unreadable
local source = "loading"
local rootLoaded = false -- the rules came from a root dump and the files are still unreadable
-- `enabled` is known without ufw.conf being readable: from a root dump, or from a Turn on /
-- Turn off that succeeded. An unreadable ufw.conf then keeps it instead of clearing it.
local enabledKnown = false
local debugWritten = false -- state.json exists because of us; removed once the marker goes
local pending = {}
local nextOpId = 0
local lastError = nil
local notice = nil
local polkitFallback = nil
local testMode = false
local etcRoot = "/etc"
local seq = 0
local requestSeq = 0

-- per file: stamp ({mtime, size} or {missing} when last read), ok (last read succeeded), text (rules files:
-- only their "#" lines, see markerLines)
local files = { conf = {}, defaults = {}, v4 = {}, v6 = {} }
local rulesIncomplete = false -- re-read both rules files on the next poll
local INCOMPLETE_SHOWN_AFTER = 3
local incompleteParses = 0 -- consecutive incomplete parses; from 3 on the panel says so

local busy = false
local busyAction = nil
local busyDeadlineMs = nil
local actionId = 0 -- bumped per action; a late callback of an older one is ignored

local ticks = 0
local terminalRefreshAtMs = nil
local tickQueue = {} -- reads the host refused; retried from update()

-- ── helpers ──────────────────────────────────────────────────────────────────

local function log(event, value)
  if value ~= nil then
    noctalia.log("ufw: " .. event .. " " .. tostring(value))
  else
    noctalia.log("ufw: " .. event)
  end
end

local function dataFile(name)
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/" .. name
end

local function trim(text)
  return (string.match(tostring(text or ""), "^%s*(.-)%s*$"))
end

local function clip(text)
  if text == nil then
    return nil
  end
  if #text > MAX_DETAIL then
    return string.sub(text, 1, MAX_DETAIL)
  end
  return text
end

local function firstLineOf(text)
  for line in string.gmatch(tostring(text or ""), "[^\n]+") do
    local trimmed = trim(line)
    if trimmed ~= "" then
      return clip(trimmed)
    end
  end
  return nil
end

local function firstLine(result)
  return firstLineOf(result.stderr) or firstLineOf(result.stdout)
end

-- Runs fn(...) guarded; a failure is logged by name only (never the message).
local function guarded(what, fn, ...)
  local ok = pcall(fn, ...)
  if not ok then
    log("callback_failed", what)
  end
  return ok
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

-- readFileAsync, retried from update() when the host refuses it (it caps reads in flight).
local function readAsync(path, onResult)
  if noctalia.readFileAsync(path, onResult) ~= true then
    tickQueue[#tickQueue + 1] = function()
      readAsync(path, onResult)
    end
  end
end

-- Runs fn in a fresh host callback, with its own CPU budget.
local function nextCallback(fn)
  local dir = noctalia.pluginDir()
  readAsync(dir and (dir .. "/" .. YIELD_FILE) or YIELD_FILE, function()
    fn()
  end)
end

-- The rules parser only reads "### ..." lines: drop every other line with one C-level gsub,
-- so the Luau parse walks a few lines per rule instead of the whole iptables text.
local function markerLines(text)
  return (string.gsub("\n" .. text, "\n[^#\n][^\n]*", ""))
end

local function stamp(path)
  local info = noctalia.fileInfo(path)
  if info == nil then
    return { missing = true }
  end
  return { mtime = tonumber(info.mtime) or 0, size = info.size }
end

-- The host's mtime is a float that differs by under a microsecond between two calls on an
-- unchanged file (seen live), so it is compared with a tolerance far below any real rewrite.
local MTIME_TOLERANCE = 0.01

local function sameStamp(a, b)
  if a == nil or b == nil then
    return false
  end
  if a.missing or b.missing then
    return a.missing == b.missing
  end
  return a.size == b.size and math.abs(a.mtime - b.mtime) <= MTIME_TOLERANCE
end

local function pathOf(name)
  return etcRoot .. RELATIVE[name]
end

-- ── publish ──────────────────────────────────────────────────────────────────

local function snapshot()
  return {
    seq = seq,
    requestSeq = requestSeq,
    installed = installed,
    hasSystemctl = hasSystemctl,
    source = source,
    enabled = enabled,
    unit = { active = unit.active, bootEnabled = unit.bootEnabled },
    defaults = { input = defaults.input, ipv6 = defaults.ipv6 },
    rules = ruleList,
    pending = pending,
    busy = busy,
    busyAction = busyAction,
    lastError = lastError,
    notice = notice,
    polkitFallback = polkitFallback,
    testMode = testMode,
    -- the rules files kept parsing incomplete (no END RULES marker): say so instead of nothing
    rulesIncomplete = incompleteParses >= INCOMPLETE_SHOWN_AFTER,
  }
end

-- Counts and keys only (model.debugView), plus a few non-rule fields the live script reads.
local function writeDebug(snap)
  local marker = dataFile(DEBUG_MARKER)
  local path = dataFile(DEBUG_FILE)
  if marker == nil or path == nil then
    return
  end
  if noctalia.fileExists(marker) ~= true then
    if debugWritten then
      debugWritten = false
      noctalia.removeFile(path)
    end
    return
  end
  local view = model.debugView(snap)
  view.requestSeq = snap.requestSeq
  view.source = snap.source
  view.testMode = snap.testMode
  view.busyAction = snap.busyAction
  view.bootEnabled = snap.unit.bootEnabled
  view.polkitFallbackFor = snap.polkitFallback and snap.polkitFallback["for"]
  local encoded = noctalia.json.encode(view, true)
  if encoded ~= nil then
    noctalia.writeFile(path, encoded)
    debugWritten = true
  end
end

-- The 3 s poll: no state.json may outlive its marker, even without a publish.
local function dropStaleDebug()
  local marker = dataFile(DEBUG_MARKER)
  if debugWritten and marker ~= nil and noctalia.fileExists(marker) ~= true then
    debugWritten = false
    noctalia.removeFile(dataFile(DEBUG_FILE))
  end
end

local function publish()
  seq = seq + 1
  local snap = snapshot()
  noctalia.state.set(STATE_KEY, snap)
  guarded("debug", writeDebug, snap)
end

local function handled()
  requestSeq = requestSeq + 1
end

-- ── rules ────────────────────────────────────────────────────────────────────

local function reconcileNow()
  if busyAction == "save" then
    return -- the files change under a running Save; its own re-read reconciles
  end
  local kept, dropped = commands.reconcile(pending, ruleList, defaults.ipv6)
  pending = kept
  if dropped > 0 then
    notice = { key = "notice.pending_dropped", n = dropped }
    log("pending_dropped", dropped)
  end
end

local function setRules(list, from)
  for _, rule in ipairs(list) do
    rule.removable = commands.isRemovableShape(rule)
  end
  ruleList = list
  source = from
  log("rules", #list)
  reconcileNow()
end

-- After a read pass that touched a rules file (or /etc/default/ufw, for IPV6).
local function rebuildFromFiles()
  local ipv6 = defaults.ipv6
  if not files.v4.ok or (ipv6 and not files.v6.ok) then
    -- unreadable (even if only user6.rules is): no re-read loop, offer Load rules
    rulesIncomplete = false
    incompleteParses = 0
    if not rootLoaded then
      if source ~= "none" then
        log("rules_unreadable")
      end
      source = "none"
      ruleList = {}
    end
    return
  end
  local list, complete = rules.parseRules(files.v4.text, ipv6 and files.v6.text or nil, ipv6)
  if not complete then
    -- keep the previous rules (and build no delete from a partial read); re-read next poll
    if not rulesIncomplete then
      log("rules_incomplete")
    end
    rulesIncomplete = true
    incompleteParses = incompleteParses + 1
    return
  end
  rulesIncomplete = false
  incompleteParses = 0
  rootLoaded = false
  setRules(list, "files")
end

local function applyFile(name, text)
  local file = files[name]
  file.ok = text ~= nil
  if name == "conf" then
    if text ~= nil then
      enabled = rules.parseConf(text).enabled
      enabledKnown = false
    elseif not enabledKnown then
      enabled = nil
    end
  elseif name == "defaults" then
    if text ~= nil then
      defaults = rules.parseDefaults(text)
    elseif not rootLoaded then
      defaults = rules.parseDefaults(nil)
    end
  else
    file.text = text and markerLines(text) or nil
  end
end

-- The batch script's dump: ufw.conf and /etc/default/ufw in one callback, the rules in the
-- next. asRoot: Load rules (source "root"); otherwise a Save, whose source stays "files"
-- unless the files were unreadable. done(complete).
local function applyDump(dump, asRoot, done)
  nextCallback(function()
    guarded("dump", function()
      if dump.conf ~= nil then
        enabled = rules.parseConf(dump.conf).enabled
        enabledKnown = enabled ~= nil
      end
      if dump.defaults ~= nil then
        defaults = rules.parseDefaults(dump.defaults)
      end
    end)
    nextCallback(function()
      local complete = false
      guarded("dump_rules", function()
        if dump.v4 == nil then
          return
        end
        local ipv6 = defaults.ipv6
        local v6 = nil
        if ipv6 and dump.v6 ~= nil then
          v6 = markerLines(dump.v6)
        end
        local list, ok = rules.parseRules(markerLines(dump.v4), v6, ipv6)
        if not ok then
          return
        end
        complete = true
        if asRoot or source ~= "files" then
          rootLoaded = true
          setRules(list, "root")
        else
          setRules(list, "files")
        end
      end)
      done(complete)
    end)
  end)
end

-- ── test mode ────────────────────────────────────────────────────────────────

local function detectRoot()
  local marker = dataFile(DEBUG_MARKER)
  local pointer = dataFile(FIXTURE_ROOT)
  if marker ~= nil and pointer ~= nil and noctalia.fileExists(marker) == true
    and noctalia.fileExists(pointer) == true then
    local dir = trim(noctalia.readFile(pointer))
    dir = string.gsub(dir, "/+$", "")
    if dir ~= "" then
      return dir, true
    end
  end
  return "/etc", false
end

-- True when the root changed: every file must be read again, from the new place. Nothing
-- read or staged under the old root survives: fixture rules use classic ports, so a staged
-- remove could match a real rule. Until the re-read lands nothing is known (source "loading").
local function updateTestMode()
  local root, on = detectRoot()
  if root == etcRoot and on == testMode then
    return false
  end
  etcRoot, testMode = root, on
  rootLoaded = false
  enabledKnown = false
  rulesIncomplete = false
  incompleteParses = 0
  for _, name in ipairs(NAMES) do
    files[name] = {}
  end
  pending = {}
  ruleList = {}
  source = "loading"
  enabled = nil
  defaults = rules.parseDefaults(nil)
  notice = nil
  log("test_mode", on and "on" or "off")
  return true
end

-- ── reading ──────────────────────────────────────────────────────────────────

local passId = 0
local passRunning = false
local passStartedMs = nil
local wanted = {} -- name -> true: files the next pass reads
local passWaiters = {}
local activeWaiters = {} -- the running pass's waiters, handed on if that pass goes stale

local startPass

-- A pass with waiters leaves the publish to them (they join it with the systemctl read).
local function finishPass(id, waiters)
  if id ~= passId then
    return
  end
  passRunning = false
  activeWaiters = {}
  for _, fn in ipairs(waiters) do
    guarded("waiter", fn)
  end
  if #waiters == 0 then
    publish()
  end
  if next(wanted) ~= nil or #passWaiters > 0 then
    startPass()
  end
end

startPass = function()
  passId = passId + 1
  local id = passId
  local stale = passRunning
  passRunning = true
  passStartedMs = noctalia.nowMs()
  if updateTestMode() then
    for _, name in ipairs(NAMES) do
      wanted[name] = true
    end
  end
  local list = {}
  for _, name in ipairs(NAMES) do
    if wanted[name] then
      list[#list + 1] = name
    end
  end
  wanted = {}
  local waiters = passWaiters
  passWaiters = {}
  if stale then
    -- the previous pass is stale (a lost callback): its waiters wait for this one
    for _, fn in ipairs(activeWaiters) do
      waiters[#waiters + 1] = fn
    end
  end
  activeWaiters = waiters
  local reparse = false
  local index = 0
  local step
  step = function()
    if id ~= passId then
      return
    end
    index = index + 1
    local name = list[index]
    if name == nil then
      if reparse then
        return nextCallback(function()
          if id ~= passId then
            return
          end
          guarded("rules", rebuildFromFiles)
          finishPass(id, waiters)
        end)
      end
      return finishPass(id, waiters)
    end
    if name ~= "conf" then
      reparse = true
    end
    local path = pathOf(name)
    files[name].stamp = stamp(path)
    readAsync(path, function(text)
      if id ~= passId then
        return
      end
      guarded("read", applyFile, name, text)
      step()
    end)
  end
  step()
end

-- Reads these files (then publishes, or calls after). Overlapping calls coalesce into one
-- more pass; a pass older than STALE_MS (a lost callback) no longer blocks a new one.
local function readFiles(names, after)
  for _, name in ipairs(names) do
    wanted[name] = true
  end
  if after ~= nil then
    passWaiters[#passWaiters + 1] = after
  end
  if passRunning and noctalia.nowMs() - passStartedMs < STALE_MS then
    return
  end
  startPass()
end

local unitRunning = false
local unitStartedMs = nil
local unitWaiters = {}

local function flushUnitWaiters()
  local waiters = unitWaiters
  unitWaiters = {}
  for _, fn in ipairs(waiters) do
    guarded("waiter", fn)
  end
  return #waiters
end

-- `systemctl show ufw`; publishes on a change unless a waiter will.
local function readUnit(after)
  if after ~= nil then
    unitWaiters[#unitWaiters + 1] = after
  end
  if not systemctlFound then
    unit = {}
    hasSystemctl = false
    flushUnitWaiters()
    return
  end
  if unitRunning and noctalia.nowMs() - unitStartedMs < READ_TIMEOUT_MS + WATCHDOG_SLACK_MS then
    return
  end
  unitRunning = true
  unitStartedMs = noctalia.nowMs()
  run(commands.SYSTEMCTL_SHOW, READ_TIMEOUT_MS, function(result)
    unitRunning = false
    local changed = false
    guarded("unit", function()
      -- a failed or timed-out read leaves the unit unknown (muted), not the last answer
      local fresh = {}
      if not result.timedOut and result.exitCode == 0 then
        fresh = commands.parseSystemctlShow(result.stdout)
      end
      if fresh.active ~= unit.active or fresh.bootEnabled ~= unit.bootEnabled or fresh.missing ~= unit.missing then
        unit = fresh
        changed = true
      end
      hasSystemctl = not unit.missing
    end)
    if flushUnitWaiters() == 0 and changed then
      publish()
    end
  end)
end

-- Every file and the unit, then one publish (after `after`).
local function refreshAll(after)
  installed = noctalia.commandExists("ufw") == true
  systemctlFound = noctalia.commandExists("systemctl") == true
  if not systemctlFound then
    hasSystemctl = false
  end
  local left = 2
  local function joined()
    left = left - 1
    if left == 0 then
      if after ~= nil then
        after()
      end
      publish()
    end
  end
  readFiles(NAMES, joined)
  readUnit(joined)
end

-- The 3 s poll: only the files whose mtime or size changed (or both rules files after an
-- incomplete parse).
local function checkFiles()
  dropStaleDebug()
  local all = updateTestMode()
  local names = {}
  for _, name in ipairs(NAMES) do
    if all or not sameStamp(stamp(pathOf(name)), files[name].stamp)
      or (rulesIncomplete and (name == "v4" or name == "v6")) then
      names[#names + 1] = name
    end
  end
  if #names > 0 then
    log("changed", table.concat(names, ","))
    readFiles(names)
  end
end

-- On a request: a test-mode change takes effect before the request is judged. A pass
-- still reading the old root is orphaned (its waiters move to the new pass).
local function checkTestMode()
  if not updateTestMode() then
    return
  end
  for _, name in ipairs(NAMES) do
    wanted[name] = true
  end
  startPass()
end

-- ── actions ──────────────────────────────────────────────────────────────────

local function withError(op, errorText, errorKey)
  local copy = {}
  for k, v in pairs(op) do
    copy[k] = v
  end
  copy.error = errorText
  copy.errorKey = errorKey
  copy.notLive = nil
  return copy
end

-- notLive (see applyResults) lasts until the next root action: after a Turn on / off or a
-- start, the re-read may reconcile those ops away again.
local function clearNotLive()
  local out = {}
  for i, op in ipairs(pending) do
    if op.notLive then
      out[i] = withError(op, op.error, op.errorKey)
    else
      out[i] = op
    end
  end
  pending = out
end

local function refuse(key)
  lastError = { key = key }
  log("refused", key)
  handled()
  publish()
end

local function beginAction(action, timeoutMs)
  if action ~= "save" then
    clearNotLive()
  end
  actionId = actionId + 1
  busy = true
  busyAction = action
  busyDeadlineMs = noctalia.nowMs() + (timeoutMs or ROOT_TIMEOUT_MS) + WATCHDOG_SLACK_MS
  lastError = nil
  notice = nil
  polkitFallback = nil
  publish()
  return actionId
end

local function finishAction(id, err)
  if id ~= actionId then
    return
  end
  busy = false
  busyAction = nil
  busyDeadlineMs = nil
  lastError = err
  if err ~= nil then
    log("error", err.key)
  end
  refreshAll(handled)
end

-- The error for a pkexec result that did not succeed (cancelled sets a notice instead).
local function outcome(action, kind, result)
  if kind == "ok" then
    return nil
  elseif kind == "cancelled" then
    notice = { key = "notice.cancelled" }
    return nil
  elseif kind == "timeout" then
    return { key = "error.timeout" }
  elseif kind == "no_agent" then
    polkitFallback = { ["for"] = action }
    return { key = "error.no_polkit_agent" }
  end
  return { key = "error.command_failed", detail = firstLine(result) }
end

local function runSimple(action)
  local argv = commands.argv(action, { enabled = enabled, hasSystemctl = hasSystemctl, unit = unit })
  local id = beginAction(action)
  run(argv, ROOT_TIMEOUT_MS, function(result)
    if id ~= actionId then
      return
    end
    local kind = commands.classifyPkexec(result)
    log(action, kind)
    if kind == "ok" and not files.conf.ok then
      -- ufw.conf is unreadable and the command leaves no dump: what it did is all we know.
      -- Turn off with systemctl only stops the unit, so it says nothing about ufw.conf.
      if action == "enable" or (action == "disable" and not hasSystemctl) then
        enabled = action == "enable"
        enabledKnown = true
      end
    end
    finishAction(id, outcome(action, kind, result))
  end)
end

-- Why saveArgv left an op out: the key of its validation error.
local function droppedKey(op)
  if op.kind == "remove" then
    return "error.not_removable"
  end
  if type(op.port) ~= "number" then
    return "add.error_port"
  end
  local _, err = commands.validateAdd(string.format("%d", op.port), op.proto, op.comment)
  return err or "add.error_port"
end

-- Applies parseBatch results: ops that succeeded leave pending, a failed op keeps ufw's first
-- line, ops that did not run stay. A `written` op (ufw's rules file was updated, the running
-- firewall was not: ufw is stopped) counts as saved only when ufw was not on when the Save
-- started (save.wasOn) and the dump's rules (dumpRules, nil without a complete dump) show it
-- done, against the rules the Save started from (save.before). While ufw is on, `written`
-- means the live update failed: a failure, kept pending with ufw's line and marked notLive so
-- the re-read (whose files do show it) does not reconcile it away. Returns the number saved
-- and how many of those were written only.
local function applyResults(order, results, dumpRules, save)
  local saved, written, done, failed, notLive = 0, 0, {}, {}, {}
  local byId = {}
  for _, op in ipairs(pending) do
    byId[op.id] = op
  end
  for i, opId in ipairs(order) do
    local r = results[i]
    if r ~= nil and r.ok then
      done[opId] = true
      saved = saved + 1
    elseif r ~= nil and r.written and not save.wasOn and dumpRules ~= nil
      and commands.applied(byId[opId], dumpRules, defaults.ipv6, save.before) then
      done[opId] = true
      saved = saved + 1
      written = written + 1
    elseif r ~= nil then
      failed[opId] = firstLineOf(r.msg) or false
      notLive[opId] = r.written == true and save.wasOn
    end
  end
  local kept = {}
  for _, op in ipairs(pending) do
    if not done[op.id] then
      local msg = failed[op.id]
      local copy = op
      if msg then
        copy = withError(op, msg, nil)
      elseif msg == false then
        copy = withError(op, nil, "error.op_failed")
      end
      if notLive[op.id] then
        copy.notLive = true
      end
      kept[#kept + 1] = copy
    end
  end
  pending = kept
  return saved, written
end

-- After the batch (and its dump, when complete): pending, the notification, the notice, the error.
local function settleSave(id, order, dropped, results, dumpRules, save)
  local saved, written = applyResults(order, results, dumpRules, save)
  log("saved", saved)
  if written > 0 then
    -- saved to ufw's rules, but ufw isn't running them: say when they take effect
    log("saved_not_live", written)
    notice = { key = "notice.saved_not_live", n = saved }
    noctalia.notify(noctalia.tr("plugin.name"), noctalia.tr(model.countKey("notice.saved_not_live", saved), { n = saved }))
  elseif saved > 0 then
    noctalia.notify(noctalia.tr("plugin.name"), noctalia.tr(model.countKey("notice.saved", saved), { n = saved }))
  end
  -- failed, didn't run, or left out of the batch: never reported as saved
  local unsaved = #order - saved + #dropped
  local err = nil
  if unsaved > 0 then
    err = { key = "error.save_partial", n = unsaved }
  end
  finishAction(id, err)
end

local function runSave()
  if #pending == 0 then
    handled()
    publish()
    return
  end
  local byId = {}
  for _, rule in ipairs(ruleList) do
    byId[rule.id] = rule
  end
  local argv, order, dropped = commands.saveArgv(pending, byId)
  local droppedSet = {}
  for _, opId in ipairs(dropped) do
    droppedSet[opId] = true
  end
  local marked = {}
  for _, op in ipairs(pending) do
    if droppedSet[op.id] then
      marked[#marked + 1] = withError(op, nil, droppedKey(op))
    elseif op.error ~= nil or op.errorKey ~= nil then
      marked[#marked + 1] = withError(op, nil, nil)
    else
      marked[#marked + 1] = op
    end
  end
  pending = marked
  if #dropped > 0 then
    log("save_dropped", #dropped)
  end
  if #order == 0 then
    -- nothing could be encoded: say so (each op carries its errorKey)
    lastError = { key = "error.save_dropped", n = #dropped }
    handled()
    publish()
    return
  end
  -- what a `written` result is judged against: the status and the rules before the Save
  local save = {
    wasOn = model.status({ installed = installed, enabled = enabled, hasSystemctl = hasSystemctl, unit = unit }) == "on",
    before = ruleList,
  }
  local id = beginAction("save")
  local root = etcRoot -- a dump read under another root (test mode changed) is not applied
  run(argv, ROOT_TIMEOUT_MS, function(result)
    if id ~= actionId then
      return
    end
    local kind = commands.classifyPkexec(result)
    local stdout = result.stdout or ""
    -- exit 1 with batch output is a partial save: apply what it reports
    if (kind == "ok" or kind == "failed")
      and (string.find(stdout, "@@op ", 1, true) or string.find(stdout, "@@file ", 1, true)) then
      local batch = commands.parseBatch(stdout)
      if batch.complete and batch.dump.v4 ~= nil and etcRoot == root then
        applyDump(batch.dump, false, function(complete)
          if id ~= actionId then
            return
          end
          settleSave(id, order, dropped, batch.results, complete and ruleList or nil, save)
        end)
      else
        settleSave(id, order, dropped, batch.results, nil, save)
      end
      return
    end
    log("save", kind)
    if kind == "ok" or kind == "failed" then
      return finishAction(id, { key = "error.save_failed", detail = firstLine(result) })
    end
    finishAction(id, outcome("save", kind, result))
  end)
end

local function runLoadRules()
  local id = beginAction("load_rules")
  local root = etcRoot
  run(commands.argv("load_rules"), ROOT_TIMEOUT_MS, function(result)
    if id ~= actionId then
      return
    end
    local kind = commands.classifyPkexec(result)
    log("load_rules", kind)
    if kind ~= "ok" then
      return finishAction(id, outcome("load_rules", kind, result))
    end
    local batch = commands.parseBatch(result.stdout)
    if etcRoot ~= root then
      return finishAction(id, nil)
    end
    if not batch.complete or batch.dump.v4 == nil then
      return finishAction(id, { key = "error.load_failed" })
    end
    applyDump(batch.dump, true, function(complete)
      if complete then
        finishAction(id, nil)
      else
        finishAction(id, { key = "error.load_failed" })
      end
    end)
  end)
end

-- Opens a terminal with a fixed command, for when no polkit agent can ask for the password.
-- Only keys of commands.TERMINAL_COMMANDS run. The files are re-read once the user has had
-- time to type the password.
local function runInTerminal(request)
  local key = request["for"]
  local cmd = nil
  if type(key) == "string" then
    local terminalKey = commands.terminalKey(key, { enabled = enabled, hasSystemctl = hasSystemctl, unit = unit })
    if terminalKey ~= nil then
      cmd = rawget(commands.TERMINAL_COMMANDS, terminalKey)
    end
  end
  if type(cmd) ~= "string" then
    return refuse("error.unknown_action")
  end
  if noctalia.runInTerminal(cmd) == false then
    lastError = { key = "error.terminal_failed" }
    log("error", lastError.key)
  else
    lastError = nil
    polkitFallback = nil
    clearNotLive()
    terminalRefreshAtMs = noctalia.nowMs() + TERMINAL_REFRESH_MS
    log("run_in_terminal", key)
  end
  handled()
  publish()
end

-- Turns on Noctalia's built-in polkit agent so pkexec can show a password prompt. It takes
-- the busy slot, so its late callback can't overwrite another action's result.
local function enablePolkitAgent()
  local argv = commands.argv("enable_polkit_agent")
  local fallback = polkitFallback
  local id = beginAction("enable_polkit_agent", READ_TIMEOUT_MS)
  run(argv, READ_TIMEOUT_MS, function(result)
    if id ~= actionId then
      return
    end
    if result.exitCode == 0 and not result.timedOut then
      log("polkit_agent", "on")
      return finishAction(id, nil)
    end
    polkitFallback = fallback -- the prompt still can't be shown: keep the way out
    finishAction(id, { key = "error.command_failed", detail = firstLine(result) })
  end)
end

local function stage(request)
  nextOpId = nextOpId + 1
  local out, err = commands.stage(pending, ruleList, request, nextOpId)
  pending = out
  if err ~= nil then
    lastError = { key = err }
    log("stage", err)
  else
    if lastError ~= nil and (STAGE_ERRORS[lastError.key] or string.sub(lastError.key, 1, 4) == "add.") then
      lastError = nil
    end
    log("pending", #pending)
  end
  handled()
  publish()
end

-- No key clears what is shown; a key clears only that error or notice, never a newer one.
local function dismiss(key)
  if key == nil then
    lastError, notice, polkitFallback = nil, nil, nil
    return
  end
  if lastError ~= nil and lastError.key == key then
    if key == "error.no_polkit_agent" then
      polkitFallback = nil
    end
    lastError = nil
  end
  if notice ~= nil and notice.key == key then
    notice = nil
  end
end

local function handleRequest(request)
  if type(request) ~= "table" or type(request.action) ~= "string" then
    return
  end
  local action = request.action
  checkTestMode()
  if action == "refresh" then
    if busy then
      -- the running action re-reads everything when it ends
      handled()
      publish()
      return
    end
    refreshAll(handled)
    return
  elseif action == "dismiss_error" then
    dismiss(request.key)
    handled()
    publish()
    return
  elseif STAGING[action] then
    if busy and busyAction == "save" then
      return refuse("error.busy")
    end
    return stage(request)
  end
  if not ROOT_ACTIONS[action] then
    return refuse("error.unknown_action")
  end
  if busy then
    return refuse("error.busy")
  end
  if testMode then
    return refuse("error.test_mode")
  end
  if action == "save" then
    return runSave()
  elseif action == "load_rules" then
    return runLoadRules()
  elseif action == "run_in_terminal" then
    return runInTerminal(request)
  elseif action == "enable_polkit_agent" then
    return enablePolkitAgent()
  elseif SIMPLE_ROOT[action] then
    return runSimple(action)
  end
end

noctalia.state.watch(REQUEST_KEY, function(request)
  guarded("request", handleRequest, request)
end)

function onIpc(event, payload)
  if event ~= "request" or type(payload) ~= "string" then
    return
  end
  local value = noctalia.json.decode(payload)
  if type(value) == "table" then
    guarded("request", handleRequest, value)
  end
end

function update()
  local now = noctalia.nowMs()
  if busy and busyDeadlineMs ~= nil and now > busyDeadlineMs then
    actionId = actionId + 1 -- orphan the lost callback
    busy = false
    busyAction = nil
    busyDeadlineMs = nil
    lastError = { key = "error.timeout" }
    log("watchdog", "error.timeout")
    refreshAll(handled)
  end
  if terminalRefreshAtMs ~= nil and not busy and now >= terminalRefreshAtMs then
    terminalRefreshAtMs = nil
    refreshAll()
  end
  -- one refused read per tick, each with this tick's budget
  local queued = table.remove(tickQueue, 1)
  if queued ~= nil then
    queued()
  end
  ticks = ticks + 1
  if not busy then
    if ticks % FILE_POLL_TICKS == 0 then
      guarded("poll", checkFiles)
    end
    if ticks % UNIT_POLL_TICKS == 0 then
      guarded("poll", readUnit)
    end
  end
end

noctalia.setUpdateInterval(TICK_MS)

log("service started")
publish()
refreshAll()
