--!nonstrict
-- Reads live values, saves through txn.lua, verifies the reload, runs the
-- keep-or-revert countdown.
--
-- Shared state (noctalia.state):
--   hs.live    { values = { [path] = v }, monitors = <hyprctl monitors all -j>, errors = {...}, error = "..."? }
--   hs.saved   the confirmed state (see lib/writer.luau)
--              message on revert is a reason code: timeout | not_loaded | too_late | outside |
--              user | restarted | config_error:<text>
--   hs.txn     { status, id?, deadline?, now?, message?, not_effective? = { path or "monitor NAME" } }
--              status: idle | applying | verifying | pending | keeping | reverting | revert_failed
--                      | confirmed | reverted | conflict | failed
--              Keep is only possible in "pending", i.e. after Hyprland visibly loaded the file.
--   hs.setup   { loaded, declined, module?, file, conf, state = "idle"|"working"|"error", message? }
--              loaded: Hyprland's Lua has required the settings file (package.loaded)
--   hs.request { seq, op = "refresh"|"apply"|"keep"|"revert"|"setup"|"setup_decline"|"setup_check",
--                state = draft, adopt = bool }   (panel)
--
-- Times are seconds since boot, the same clock txn.lua uses.

local catalog = require("./lib/catalog.luau")
local writer = require("./lib/writer.luau")
local monitors = require("./lib/monitors.luau")
local hyprctl = require("./lib/hyprctl.luau")
local presets = { futurista = require("./lib/presets/futurista.luau") }

local SECONDS = 15
local SETUP_SECONDS = 6
local VERIFY_SECONDS = 5
local data = assert(noctalia.pluginDataDir())
local txnScript = noctalia.pluginDir() .. "/txn.lua"

local txn = { status = "idle" }
local draft, before = nil, nil -- of the open transaction
local verifyUntil, verifyBusy, retryAt = nil, false, nil
local setupUntil = nil
local lastSeq = (noctalia.state.get("hs.request") or {}).seq or 0

local OPEN = { applying = true, verifying = true, pending = true, keeping = true, reverting = true, revert_failed = true }

local function uptime()
  return tonumber((noctalia.readFile("/proc/uptime") or ""):match("^([%d%.]+)")) or 0
end

local function target()
  return noctalia.expandPath(noctalia.getConfig("config_path"))
end

local function publish()
  txn.now = uptime()
  noctalia.state.set("hs.txn", txn)
end

local function set(status, fields)
  txn = { status = status, id = txn.id, deadline = txn.deadline }
  for k, v in pairs(fields or {}) do txn[k] = v end
  if txn.message then noctalia.log("hyprland-settings: " .. status .. ": " .. txn.message) end
  publish()
end

local function writeAtomic(path, text)
  local ok, err = noctalia.writeFile(path .. ".tmp", text)
  if ok then ok, err = noctalia.renameFile(path .. ".tmp", path) end
  return ok, err
end

local function readJson(path)
  local raw = noctalia.readFile(path)
  if raw == nil then return nil end
  local value = noctalia.json.decode(raw)
  return type(value) == "table" and value or nil
end

local function readTxnFile()
  local t = {}
  for key, value in (noctalia.readFile(data .. "/txn") or ""):gmatch("([%w_]+)=([^\n]*)") do t[key] = value end
  return t
end

-- Like runAsync, but a process that cannot start still answers.
local function run(argv, cb)
  if not noctalia.runAsync(argv, cb) then
    cb({ exitCode = -1, stdout = "", stderr = "could not start " .. argv[1], timedOut = false })
  end
end

-- Every txn.lua call goes through the same lock as the watchdog.
local function runTxn(args, cb)
  local argv = { "flock", "-w", "10", data .. "/lock", "lua", txnScript }
  for _, a in ipairs(args) do table.insert(argv, a) end
  run(argv, function(result)
    if result.timedOut then return cb(false, "txn.lua timed out", -1) end
    local out = noctalia.string.trim(result.exitCode == 0 and result.stdout or (result.stderr ~= "" and result.stderr or result.stdout))
    cb(result.exitCode == 0, out, result.exitCode)
  end)
end

-- Reads values, monitors and config errors. Failures go to hs.live.error and
-- never touch the transaction: the file-based revert works without Hyprland.
local function refresh(done)
  run(hyprctl.readArgv(catalog), function(read)
    run({ "hyprctl", "monitors", "all", "-j" }, function(mons)
      run({ "hyprctl", "configerrors", "-j" }, function(errs)
        local mlist = mons.exitCode == 0 and not mons.stdoutTruncated and noctalia.json.decode(mons.stdout) or nil
        local elist = errs.exitCode == 0 and noctalia.json.decode(errs.stdout) or nil
        if read.exitCode ~= 0 or read.stdoutTruncated or type(mlist) ~= "table" or type(elist) ~= "table" then
          local message = "hyprctl failed: " .. noctalia.string.trim(read.stderr .. " " .. mons.stderr .. " " .. errs.stderr)
          noctalia.state.set("hs.live", { values = {}, monitors = {}, errors = {}, error = message })
          if done then done(nil, message) end
          return
        end
        local errors = {}
        for _, e in ipairs(elist) do
          if e ~= "" then table.insert(errors, e) end
        end
        local live = { values = hyprctl.parseRead(catalog, read.stdout, noctalia.json.decode), monitors = mlist, errors = errors }
        noctalia.state.set("hs.live", live)
        if done then done(live) end
      end)
    end)
  end)
end

local function dropDraft(id)
  noctalia.removeFile(data .. "/state." .. id .. ".json")
  draft, before = nil, nil
end

-- A confirmed transaction's draft becomes the saved state, also when the
-- service died between "keep" and this rename.
local function promote(id)
  local parked = data .. "/state." .. id .. ".json"
  local err = nil
  if noctalia.fileExists(parked) then
    local ok, rerr = noctalia.renameFile(parked, data .. "/state.json")
    if not ok then err = "file saved, but plugin state not: " .. tostring(rerr) end
  end
  draft, before = nil, nil
  noctalia.state.set("hs.saved", readJson(data .. "/state.json") or {})
  return err
end

local function revert(reason)
  local id = txn.id
  set("reverting", { message = reason })
  runTxn({ "revert", data, id }, function(ok, out, code)
    if txn.id ~= id then return end
    if ok then
      dropDraft(id)
      set("reverted", { message = reason })
    elseif code == 1 and out == "confirmed" then
      local err = promote(id)
      set("confirmed", { message = err })
    elseif code == 1 then
      dropDraft(id)
      set(out ~= "" and out or "reverted", { message = reason })
    elseif code == 2 then
      dropDraft(id)
      set("conflict", { message = out })
    else
      -- Backup kept; try again in a few seconds.
      retryAt = uptime() + 5
      set("revert_failed", { message = out })
      noctalia.setUpdateInterval(1000)
    end
    refresh()
  end)
end

local function keep()
  local id = txn.id
  set("keeping")
  runTxn({ "keep", data, id }, function(ok, out, code)
    if txn.id ~= id then return end
    if ok then
      local err = promote(id)
      set("confirmed", { message = err })
    elseif code == 1 and out == "expired" then
      revert("too_late")
    elseif code == 1 then
      if out == "reverted" then dropDraft(id) end
      set(out, {})
    elseif code == 2 then
      revert("outside")
    else
      set("pending", { message = out }) -- keep failed, countdown goes on
    end
  end)
end

local function same(a, b)
  -- four equal sides == one number
  local function flat(v)
    if type(v) == "table" and v.top == v.right and v.top == v.bottom and v.top == v.left then return v.top end
    return v
  end
  a, b = flat(a), flat(b)
  if type(a) == "table" and type(b) == "table" then
    return a.top == b.top and a.right == b.right and a.bottom == b.bottom and a.left == b.left
  end
  if type(a) == "number" and type(b) == "number" then return math.abs(a - b) < 1e-6 end
  return a == b
end

-- Does a live monitor look like the rule says?
local function looksLike(rule, m)
  if rule.disabled then return m.disabled == true end
  if m.disabled then return false end
  local w, h, hz = monitors.parseMode(monitors.resolveMode(rule.mode, m) or "")
  if w == nil or m.width ~= w or m.height ~= h or math.abs(m.refreshRate - hz) > 0.5 then return false end
  if math.abs(m.scale - rule.scale) > 0.01 or (m.transform or 0) ~= (rule.transform or 0) then return false end
  local x, y = rule.position:match("^(%-?%d+)x(%-?%d+)$")
  return x == nil or (m.x == tonumber(x) and m.y == tonumber(y))
end

-- Requested values that do not show although the file is loaded. Usually a
-- later file overrides them (e.g. a power-saver block), but that is not
-- proven, so they are reported as "not effective", not reverted.
local function notEffective(live)
  local list = {}
  for path, entry in pairs(draft.options or {}) do
    if not same(live.values[path], entry.value) then table.insert(list, path) end
  end
  for _, monitor in ipairs(live.monitors) do
    local rule = monitors.ruleFor(draft.monitors or {}, monitor)
    if rule ~= nil and not looksLike(rule, monitor) then table.insert(list, "monitor " .. monitor.name) end
  end
  table.sort(list)
  return list
end

-- Proof of the reload: the file sets HYPRLAND_SETTINGS_REVISION to this
-- transaction's id, and Hyprland's Lua state must return it.
local function verify()
  verifyBusy = true
  local id = txn.id
  run({ "hyprctl", "repl", "return HYPRLAND_SETTINGS_REVISION" }, function(rev)
    if txn.id ~= id or txn.status ~= "verifying" then verifyBusy = false; return end
    if rev.exitCode ~= 0 or noctalia.string.trim(rev.stdout) ~= id then verifyBusy = false; return end
    refresh(function(live)
      verifyBusy = false
      if txn.id ~= id or txn.status ~= "verifying" then return end
      if live == nil then return end -- try again next tick; the deadlines still hold
      local old = {}
      for _, e in ipairs(before.errors) do old[e] = true end
      for _, e in ipairs(live.errors) do
        if not old[e] then return revert("config_error:" .. e) end
      end
      set("pending", { not_effective = notEffective(live) })
    end)
  end)
end

-- ------------------------------------------------------------------ setup

-- The module name hyprland.lua requires. Only files in ~/.config/hypr can
-- be required by name; for any other path the panel shows manual steps.
local function setupInfo()
  local file = target()
  local dir = noctalia.expandPath("~/.config/hypr")
  local module = file:match("^" .. dir:gsub("%p", "%%%0") .. "/([%w_%-]+)%.lua$")
  return file, module, dir .. "/hyprland.lua"
end

local setup = { loaded = false, declined = noctalia.fileExists(data .. "/setup-declined"), state = "idle" }

local function publishSetup()
  local file, module, conf = setupInfo()
  setup.file, setup.module, setup.conf = file, module, conf
  noctalia.state.set("hs.setup", setup)
end

local function checkSetup(done)
  local _, module = setupInfo()
  if module == nil then
    setup.loaded = false
    publishSetup()
    return
  end
  run({ "hyprctl", "repl", 'return tostring(package.loaded["' .. module .. '"])' }, function(r)
    setup.loaded = r.exitCode == 0 and noctalia.string.trim(r.stdout) == "true"
    publishSetup()
    if done then done(setup.loaded) end
  end)
end

local function runSetup()
  if OPEN[txn.status] or setup.state == "working" then return end
  local file, module, conf = setupInfo()
  if module == nil then return end
  setup.state, setup.message = "working", nil
  publishSetup()
  local argv = { "flock", "-w", "10", data .. "/lock", "lua", noctalia.pluginDir() .. "/setup.lua",
    conf, file, module, data .. "/backups" }
  run(argv, function(result)
    if result.exitCode ~= 0 then
      setup.state = "error"
      setup.message = noctalia.string.trim(result.stderr ~= "" and result.stderr or result.stdout)
      setup.code = result.exitCode
      publishSetup()
      return
    end
    -- Hyprland reloads hyprland.lua by itself; wait for the module to show up.
    setupUntil = uptime() + SETUP_SECONDS
    noctalia.setUpdateInterval(1000)
  end)
end

local function apply(request)
  if OPEN[txn.status] then return end
  -- Wall clock plus boot clock: unique even if the wall clock jumps back.
  local id = string.format("%d-%d", math.floor(noctalia.nowMs()), math.floor(uptime() * 100))
  txn = { status = "applying", id = id }
  publish()
  -- Re-read what is connected right now: a screen may have been unplugged.
  refresh(function(live, readErr)
    if txn.id ~= id then return end
    if live == nil then return set("failed", { message = readErr }) end
    local state = request.state
    local called, valid, verr = pcall(monitors.validate, state.monitors or {}, live.monitors)
    if not called then return set("failed", { message = "invalid monitors: " .. tostring(valid) }) end
    if not valid then return set("failed", { message = verr }) end
    local rendered, text, rerr = pcall(writer.render, state, catalog, presets, id)
    if not rendered then return set("failed", { message = "invalid settings: " .. tostring(text) }) end
    if text == nil then return set("failed", { message = rerr }) end
    local encoded = noctalia.json.encode(state)
    if encoded == nil then return set("failed", { message = "cannot encode settings" }) end
    local wrote, werr = writeAtomic(data .. "/state." .. id .. ".json", encoded)
    if wrote then wrote, werr = writeAtomic(data .. "/candidate." .. id .. ".lua", text) end
    if not wrote then
      dropDraft(id)
      return set("failed", { message = "cannot write: " .. tostring(werr) })
    end
    draft, before = state, live
    local args = { "begin", data, target(), id, tostring(SECONDS) }
    if request.adopt then table.insert(args, "adopt") end
    runTxn(args, function(began, out, code)
      if txn.id ~= id then return end
      noctalia.removeFile(data .. "/candidate." .. id .. ".lua")
      if not began then
        dropDraft(id)
        return set("failed", { message = out, code = code })
      end
      verifyUntil = uptime() + VERIFY_SECONDS
      set("verifying", { deadline = tonumber(out) })
      noctalia.setUpdateInterval(1000)
    end)
  end)
end

function update()
  if setupUntil ~= nil then
    if uptime() >= setupUntil then
      setupUntil = nil
      setup.state, setup.message = "error", "not_loaded"
      checkSetup(function(loaded)
        if loaded then setup.state, setup.message = "idle", nil; publishSetup() end
      end)
    else
      checkSetup(function(loaded)
        if loaded then setupUntil = nil; setup.state = "idle"; publishSetup() end
      end)
    end
    return
  end
  local s = txn.status
  if s == "revert_failed" then
    if uptime() >= retryAt then revert(txn.message) end
    return
  end
  if s ~= "verifying" and s ~= "pending" then
    if not OPEN[s] then noctalia.setUpdateInterval(60000) end
    return
  end
  local now = uptime()
  if txn.deadline == nil or now >= txn.deadline then return revert("timeout") end
  if s == "verifying" then
    if now >= verifyUntil then return revert("not_loaded") end
    if not verifyBusy then verify() end
  end
  publish()
end

local function handle(request)
  if type(request) ~= "table" or type(request.seq) ~= "number" or request.seq <= lastSeq then return end
  lastSeq = request.seq
  if request.op == "refresh" or request.op == "setup_check" then
    refresh()
    checkSetup()
  elseif request.op == "setup" then
    runSetup()
  elseif request.op == "setup_decline" then
    noctalia.writeFile(data .. "/setup-declined", "")
    setup.declined = true
    publishSetup()
  elseif request.op == "apply" and type(request.state) == "table" then
    apply(request)
  elseif request.op == "keep" and txn.status == "pending" then
    keep()
  elseif request.op == "revert" and (txn.status == "pending" or txn.status == "verifying") then
    revert("user")
  end
end

-- Startup. An open transaction from the last run is reverted, not resumed:
-- nobody saw it work, so nobody can keep it.
noctalia.state.set("hs.saved", readJson(data .. "/state.json") or {})
local open = readTxnFile()
for _, name in ipairs(noctalia.listDir(data) or {}) do
  local parked = name:match("^state%.(.+)%.json$") or name:match("^candidate%.(.+)%.lua$")
  if parked ~= nil and parked ~= open.id then noctalia.removeFile(data .. "/" .. name) end
  if name:match("%.tmp$") then noctalia.removeFile(data .. "/" .. name) end
end
if open.status == "pending" or open.status == "prepared" then
  txn = { status = "reverting", id = open.id }
  revert("restarted")
elseif open.status == "confirmed" and open.id then
  local err = promote(open.id)
  if err then set("failed", { message = err }) else publish() end
else
  if open.id then dropDraft(open.id) end
  publish()
end

noctalia.state.watch("hs.request", handle)
refresh()
checkSetup()

-- Same operations over IPC: noctalia msg plugin michael-retunzew/hyprland-settings:service all apply '<json>'
-- ("adopt" instead of "apply" takes over an existing hand-written file).
function onIpc(event, payload)
  local state = (event == "apply" or event == "adopt") and noctalia.json.decode(payload or "") or nil
  handle({ seq = lastSeq + 1, op = event == "adopt" and "apply" or event, state = state, adopt = event == "adopt" })
end
