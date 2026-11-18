-- luau tests/service_test.luau (after run.sh built tests/.build/service_src.luau)
-- Runs service.luau against a fake Noctalia host: files in memory, processes
-- queued and completed by hand, a boot clock the test moves.
local decode = require("./json")
local libs = {
  ["./lib/catalog.luau"] = require("../lib/catalog"),
  ["./lib/writer.luau"] = require("../lib/writer"),
  ["./lib/monitors.luau"] = require("../lib/monitors"),
  ["./lib/hyprctl.luau"] = require("../lib/hyprctl"),
  ["./lib/presets/futurista.luau"] = require("../lib/presets/futurista"),
}
local source = require("./.build/service_src")
local batch = require("./fixtures/getoption_batch")
local monitorsJson = require("./fixtures/monitors")
local sample = require("./sample_state")

-- Hyprland after loading border_size = 3 (and, for the power-saver case, shadow still on).
local batch3 = batch:gsub('"general:border_size", "int": 2', '"general:border_size", "int": 3')
local batchOdd = batch:gsub('"general:border_size", "int": 2', '"general:border_size", "int": 7')
local border3 = { options = { ["general.border_size"] = { value = 3, why = "thicker" } } }
local border3NoShadow = { options = {
  ["general.border_size"] = { value = 3 },
  ["decoration.shadow.enabled"] = { value = false },
} }

local failures = 0
local function check(name, condition)
  print((condition and "ok   " or "FAIL ") .. name)
  if not condition then failures += 1 end
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = copy(x) end
  return t
end

-- One fresh host + service per scenario.
local function boot(files, opts)
  opts = opts or {}
  local host = { files = files or {}, procs = {}, state = {}, watchers = {}, logs = {} }
  host.files["/proc/uptime"] = host.files["/proc/uptime"] or "100.00 400.00\n"
  local encoded, n = {}, 0
  local noctalia = {
    pluginDataDir = function() return "/data" end,
    pluginDir = function() return "/plugin" end,
    getConfig = function(key) return key == "config_path" and "~/.config/hypr/hyprland-settings.lua" or nil end,
    expandPath = function(p) return (p:gsub("^~", "/home/test")) end,
    readFile = function(p) return host.files[p] end,
    writeFile = function(p, c)
      if opts.failWrite and p:find(opts.failWrite, 1, true) then return false, "disk full" end
      host.files[p] = c
      return true
    end,
    fileExists = function(p) return host.files[p] ~= nil end,
    renameFile = function(a, b)
      if host.files[a] == nil then return false, "missing" end
      host.files[b], host.files[a] = host.files[a], nil
      return true
    end,
    removeFile = function(p) host.files[p] = nil; return true end,
    listDir = function(dir)
      local names = {}
      for p in pairs(host.files) do
        local name = p:match("^" .. dir .. "/([^/]+)$")
        if name then table.insert(names, name) end
      end
      return names
    end,
    nowMs = function() return 1000000 + (host.ms or 0) end,
    log = function(m) table.insert(host.logs, m) end,
    setUpdateInterval = function() end,
    runAsync = function(argv, cb)
      if opts.noLaunch then return false end
      table.insert(host.procs, { argv = argv, cb = cb })
      return true
    end,
    string = { trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end },
    json = {
      decode = function(s)
        if encoded[s] then return copy(encoded[s]) end
        local ok, v = pcall(decode, s)
        if ok then return v end
        return nil, "bad json"
      end,
      encode = function(v) n += 1; local k = "__json" .. n; encoded[k] = copy(v); return k end,
    },
    state = {
      get = function(k) return copy(host.state[k]) end,
      set = function(k, v)
        host.state[k] = copy(v)
        for _, w in ipairs(host.watchers[k] or {}) do w(copy(v)) end
      end,
      watch = function(k, f) host.watchers[k] = host.watchers[k] or {}; table.insert(host.watchers[k], f) end,
    },
  }
  local env = setmetatable({ noctalia = noctalia, require = function(p) return assert(libs[p], p) end }, { __index = _G })
  local chunk = assert(loadstring(source, "service.luau"))
  setfenv(chunk, env)
  chunk()
  host.env = env
  -- the startup setup check: Hyprland has loaded the file unless a test says otherwise
  for i, p in ipairs(host.procs) do
    if table.concat(p.argv, " "):find("package.loaded", 1, true) then
      table.remove(host.procs, i)
      p.cb({ exitCode = 0, stdout = opts.notLoaded and "nil" or "true", stderr = "", timedOut = false })
      break
    end
  end
  return host
end

local function ok(stdout) return { exitCode = 0, stdout = stdout or "", stderr = "", timedOut = false } end
local function err(code, text) return { exitCode = code, stdout = "", stderr = text, timedOut = false } end
local function out(code, text) return { exitCode = code, stdout = text, stderr = "", timedOut = false } end
local function status(h) return h.state["hs.txn"].status end
local function at(h, seconds) h.files["/proc/uptime"] = string.format("%.2f 400.00\n", seconds) end
local function tick(h, seconds) at(h, seconds); h.env.update() end

local function pending(h, word)
  for _, p in ipairs(h.procs) do
    if table.concat(p.argv, " "):find(word, 1, true) then return true end
  end
  return false
end

-- Completes the oldest open process whose argv contains `word`.
local function finish(h, word, result)
  for i, p in ipairs(h.procs) do
    if table.concat(p.argv, " "):find(word, 1, true) then
      table.remove(h.procs, i)
      p.cb(result)
      return p.argv
    end
  end
  error("no process with " .. word)
end

local function answerRefresh(h, values, errors)
  finish(h, "--batch", ok(values or batch))
  finish(h, "monitors", ok(monitorsJson))
  finish(h, "configerrors", ok(errors or '[""]'))
end

local function request(h, op, state, adopt)
  h.seq = (h.seq or 0) + 1
  h.env.noctalia.state.set("hs.request", { seq = h.seq, op = op, state = state, adopt = adopt })
end

-- One verify round: Hyprland's Lua answers the revision (reloaded) or not.
local function reload(h, values, errors)
  finish(h, "repl", ok(h.beginArgv[10] .. "\n"))
  answerRefresh(h, values, errors)
end
local function noReload(h) finish(h, "repl", ok("nil")) end

-- Boots, applies `draft` and lets begin succeed: status "verifying", deadline 115.
local function applied(draft, files, errors)
  local h = boot(files)
  answerRefresh(h, nil, errors)
  request(h, "apply", draft)
  answerRefresh(h, nil, errors)
  h.beginArgv = finish(h, " begin ", ok("115.00\n"))
  return h
end

-- 1. startup reads everything once
local h = boot()
answerRefresh(h)
check("startup publishes live values", h.state["hs.live"].values["input.kb_layout"] == "de")
check("empty strings are read as empty", h.state["hs.live"].values["input.kb_variant"] == "")
check("startup is idle", status(h) == "idle")

-- 2. apply -> verifying -> pending (after the reload shows) -> keep
h = applied(border3)
local argv = h.beginArgv
check("begin goes through flock and txn.lua", argv[1] == "flock" and argv[4] == "/data/lock" and argv[6] == "/plugin/txn.lua")
check("begin gets the expanded target and 15 s", argv[9] == "/home/test/.config/hypr/hyprland-settings.lua" and argv[11] == "15")
check("no adopt unless asked", argv[12] == nil)
local id = argv[10]
check("candidate consumed after begin", h.files["/data/candidate." .. id .. ".lua"] == nil)
check("draft parked until confirmed", h.files["/data/state." .. id .. ".json"] ~= nil and h.files["/data/state.json"] == nil)
check("verifying after begin", status(h) == "verifying" and h.state["hs.txn"].deadline == 115)
request(h, "keep")
check("keep is refused while verifying", not pending(h, " keep "))
tick(h, 101)
noReload(h)
check("still verifying before the reload", status(h) == "verifying" and not pending(h, "--batch"))
tick(h, 102)
reload(h, batch3)
check("pending once the revision reads back", status(h) == "pending" and #h.state["hs.txn"].not_effective == 0)
request(h, "keep")
finish(h, " keep ", ok("confirmed"))
check("keep confirms", status(h) == "confirmed")
check("draft becomes saved state", h.files["/data/state.json"] ~= nil and h.files["/data/state." .. id .. ".json"] == nil)
check("saved state published", h.state["hs.saved"].options["general.border_size"].value == 3)

-- 3. no reload within 5 s -> revert, whatever the values say
h = applied(border3)
tick(h, 101); noReload(h)
tick(h, 106)
check("no reload: reverts", pending(h, " revert ") and h.state["hs.txn"].message == "not_loaded")
h = applied({ preset = { name = "futurista" } })
tick(h, 101); noReload(h)
check("preset-only change is not taken as loaded", status(h) == "verifying")
tick(h, 106)
check("preset-only change without reload reverts", pending(h, " revert "))

-- 4. a new config error reverts at once; known ones do not
h = applied(border3, nil, '["old error"]')
tick(h, 101)
reload(h, batch3, '["old error", "hyprland-settings.lua:3: unknown field"]')
check("new error triggers revert", pending(h, " revert "))
h = applied(border3, nil, '["old error"]')
tick(h, 101)
reload(h, batch3, '["old error"]')
check("old errors alone do not revert", status(h) == "pending")

-- 5. loaded but overridden by a later file: reported, not reverted
h = applied(border3NoShadow)
tick(h, 101); reload(h, batch3)
local over = h.state["hs.txn"].not_effective
check("value overridden by a later file is reported", status(h) == "pending" and #over == 1 and over[1] == "decoration.shadow.enabled")
h = applied({ options = { ["general.border_size"] = { value = 3 }, ["decoration.rounding"] = { value = 10 } } })
tick(h, 101); reload(h, (batch3:gsub('"decoration:rounding", "int": 10', '"decoration:rounding", "int": 7')))
over = h.state["hs.txn"].not_effective
check("unchanged requested value reading back wrong is reported", #over == 1 and over[1] == "decoration.rounding")

h = applied({ options = { ["general.gaps_out"] = { value = { top = 20, right = 20, bottom = 20, left = 20 } } } })
tick(h, 101); reload(h, batch)
check("four equal gap sides match the scalar readback", #h.state["hs.txn"].not_effective == 0)

-- 6. a no-op apply still needs the reload proof
h = applied(sample)
tick(h, 101); reload(h, batch)
check("unchanged values verify after reload", status(h) == "pending")

-- 7. begin fails: nothing pending, draft and candidate gone
h = boot()
answerRefresh(h)
request(h, "apply", border3)
answerRefresh(h)
argv = finish(h, " begin ", err(7, "not written by this plugin: /x"))
check("not-ours is reported with its code", status(h) == "failed" and h.state["hs.txn"].code == 7)
check("failed begin drops draft and candidate", h.files["/data/state." .. argv[10] .. ".json"] == nil
  and h.files["/data/candidate." .. argv[10] .. ".lua"] == nil)

-- 8. adopt over IPC
h = boot()
answerRefresh(h)
h.env.onIpc("adopt", '{"options":{"general.border_size":{"value":3}}}')
answerRefresh(h)
argv = finish(h, " begin ", ok("115"))
check("adopt reaches txn.lua", argv[12] == "adopt")

-- 9. timeout reverts once
h = applied(border3)
id = h.beginArgv[10]
tick(h, 101); reload(h, batch3)
tick(h, 115)
check("timeout reverts", pending(h, " revert "))
tick(h, 116)
local reverts = 0
for _, p in ipairs(h.procs) do
  if table.concat(p.argv, " "):find(" revert ", 1, true) then reverts += 1 end
end
check("only one revert while reverting", reverts == 1)
finish(h, " revert ", ok("reverted"))
check("reverted, draft dropped", status(h) == "reverted" and h.files["/data/state." .. id .. ".json"] == nil)

-- 10. keep too late -> revert
h = applied(border3)
tick(h, 101); reload(h, batch3)
request(h, "keep")
finish(h, " keep ", out(1, "expired"))
check("expired keep reverts", pending(h, " revert "))

-- 11. keep confirmed while a timeout revert was queued: the revert sees "confirmed"
h = applied(border3)
tick(h, 101); reload(h, batch3)
tick(h, 115)
finish(h, " revert ", out(1, "confirmed"))
check("confirmed wins, draft promoted", status(h) == "confirmed" and h.files["/data/state.json"] ~= nil)

-- 12. a failed revert is retried
h = applied(border3)
tick(h, 115)
finish(h, " revert ", err(6, "cannot restore, backup kept"))
check("failed revert keeps the transaction", status(h) == "revert_failed")
tick(h, 117)
check("not retried too early", not pending(h, " revert "))
tick(h, 121)
check("retried after 5 s", pending(h, " revert "))

-- 13. Hyprland unreachable during verifying: the transaction survives
h = applied(border3)
tick(h, 101)
finish(h, "repl", err(1, "Couldn't connect"))
check("unreachable Hyprland does not end the transaction", status(h) == "verifying")
tick(h, 102)
finish(h, "repl", ok(h.beginArgv[10]))
finish(h, "--batch", err(1, "Couldn't connect"))
finish(h, "monitors", err(1, "Couldn't connect"))
finish(h, "configerrors", err(1, "Couldn't connect"))
check("read failure does not end the transaction", status(h) == "verifying" and h.state["hs.live"].error ~= nil)
tick(h, 106)
check("but it still reverts at the verify deadline", pending(h, " revert "))

-- 14. startup recovery
h = boot({ ["/data/txn"] = "id=42\nstatus=pending\ndeadline=999\n", ["/data/state.42.json"] = "{}" })
check("open txn is reverted on start", pending(h, "revert /data 42"))
h = boot({ ["/data/txn"] = "id=43\nstatus=prepared\n" })
check("prepared txn is reverted on start", pending(h, "revert /data 43"))
h = boot({ ["/data/txn"] = "id=44\nstatus=confirmed\n", ["/data/state.44.json"] = '{"preset":{"name":"futurista"}}' })
check("confirmed but not promoted is promoted on start", h.files["/data/state.json"] ~= nil and h.state["hs.saved"].preset.name == "futurista")
check("startup after a confirm is idle", status(h) == "idle")
h = boot({ ["/data/txn"] = "id=45\nstatus=reverted\n", ["/data/state.45.json"] = "{}",
  ["/data/state.9.json"] = "{}", ["/data/candidate.9.lua"] = "x", ["/data/state.json.tmp"] = "x" })
check("leftovers are cleaned up on start", h.files["/data/state.45.json"] == nil and h.files["/data/state.9.json"] == nil
  and h.files["/data/candidate.9.lua"] == nil and h.files["/data/state.json.tmp"] == nil)

-- 15. refused before anything is written
local function refused(draft, name)
  local r = boot()
  answerRefresh(r)
  request(r, "apply", draft)
  answerRefresh(r)
  check(name, status(r) == "failed" and #r.procs == 0)
  return r
end
local r = refused({ monitors = {
  { output = "eDP-1", mode = "preferred", position = "0x0", scale = 1.6, disabled = true },
  { output = "desc:AOC 24G1WG4", mode = "1920x1080@144", position = "1600x0", scale = 1, disabled = true },
} }, "all screens off is refused")
check("with the reason", r.state["hs.txn"].message == "at least one screen must stay on")
refused({ monitors = { { output = "eDP-1", mode = "preferred", position = "garbage", scale = 1.6, transform = 99 } } },
  "bad monitor fields are refused")
refused({ monitors = { { output = "eDP-1", mode = "preferred", position = "0x0", scale = 1.7 } } },
  "preferred mode is checked for whole pixels")
refused({ options = { ["general.border_size"] = { value = 99 } } }, "invalid value is refused")
refused({ options = 5 }, "malformed draft is refused without crashing")
h = boot(nil, { failWrite = "candidate." })
answerRefresh(h)
request(h, "apply", border3)
answerRefresh(h)
check("failed candidate write stops before begin", status(h) == "failed" and #h.procs == 0)

-- 16. one transaction at a time; processes that fail
h = applied(border3)
request(h, "apply", border3)
check("second apply ignored while verifying", #h.procs == 0)
h = boot(nil, { noLaunch = true })
request(h, "apply", border3)
check("no hyprctl: apply fails cleanly", status(h) == "failed")
h = boot()
answerRefresh(h)
request(h, "apply", border3)
answerRefresh(h)
finish(h, " begin ", { exitCode = 0, stdout = "", stderr = "", timedOut = true })
check("txn.lua timeout is a failure", status(h) == "failed")

-- 17. first-run setup
h = boot(nil, { notLoaded = true })
answerRefresh(h)
check("not loaded is published", h.state["hs.setup"].loaded == false and h.state["hs.setup"].module == "hyprland-settings")
check("setup paths", h.state["hs.setup"].conf == "/home/test/.config/hypr/hyprland.lua"
  and h.state["hs.setup"].file == "/home/test/.config/hypr/hyprland-settings.lua")
request(h, "setup_decline")
check("decline is remembered", h.files["/data/setup-declined"] ~= nil and h.state["hs.setup"].declined == true)
request(h, "setup")
argv = finish(h, "setup.lua", ok("added"))
check("setup runs setup.lua under the lock", argv[1] == "flock" and argv[6] == "/plugin/setup.lua"
  and argv[7] == "/home/test/.config/hypr/hyprland.lua" and argv[9] == "hyprland-settings" and argv[10] == "/data/backups")
check("working until Hyprland shows it", h.state["hs.setup"].state == "working")
tick(h, 101)
finish(h, "package.loaded", ok("nil"))
check("still working before the reload", h.state["hs.setup"].state == "working")
tick(h, 102)
finish(h, "package.loaded", ok("true"))
check("loaded after the reload", h.state["hs.setup"].loaded == true and h.state["hs.setup"].state == "idle")
h = boot(nil, { notLoaded = true })
request(h, "setup")
finish(h, "setup.lua", ok("added"))
tick(h, 107)
finish(h, "package.loaded", ok("nil"))
check("no reload within 6 s is an error", h.state["hs.setup"].state == "error" and h.state["hs.setup"].message == "not_loaded")
h = boot(nil, { notLoaded = true })
request(h, "setup")
finish(h, "setup.lua", err(3, "hyprland.conf found: this plugin needs Hyprland's Lua config"))
check("conf-only system reported", h.state["hs.setup"].state == "error" and h.state["hs.setup"].code == 3)
h = boot()
check("loaded at start", h.state["hs.setup"].loaded == true)

print(failures .. " failure(s)")
if failures > 0 then error("tests failed") end
