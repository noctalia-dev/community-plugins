-- tests/run_tests.lua — unit tests for the pure plugin modules.
-- Run with: lua tests/run_tests.lua   (from the what-did-i-do/ directory)

local prelude = dofile((arg and arg[0]:match("^(.*)/") or ".") .. "/prelude.lua")

local pluginDir = arg[0]:match("^(.*)/") or "."
-- tests/ lives inside the plugin dir; modules are at ../lib etc.
local base = pluginDir .. "/.."

local failures, count = 0, 0

local function check(name, cond)
  count = count + 1
  if cond then
    print("  ok   " .. name)
  else
    failures = failures + 1
    print("  FAIL " .. name)
  end
end

local function section(name)
  print("\n== " .. name .. " ==")
end

local json = prelude.loadModule(base, "lib/json.luau")
local timeutil = prelude.loadModule(base, "lib/timeutil.luau")
local formatting = prelude.loadModule(base, "lib/formatting.luau")
local aggregation = prelude.loadModule(base, "lib/aggregation.luau")
local tracker_mod = prelude.loadModule(base, "lib/tracker.luau")
local storage_mod = prelude.loadModule(base, "lib/storage.luau")
local exclusion = prelude.loadModule(base, "lib/exclusion.luau")
local hyprland_mod = prelude.loadModule(base, "providers/hyprland.luau")

-- ── json codec ───────────────────────────────────────────────────────────────

section("json")
do
  local ok, v = json.decode('{"a":1,"b":[true,"x\\u00e9"]}')
  check("decode object", ok and v.a == 1 and v.b[1] == true and v.b[2] == "xé")

  local ok2, err2 = json.decode('{"a":1')
  check("rejects truncated", ok2 == false and type(err2) == "string")

  local ok3, err3 = json.decode('{invalid}')
  check("rejects garbage", ok3 == false and type(err3) == "string")

  local ok4, v4 = json.decode('{"nested":{"deep":{"list":[1,2,{"x":"y"}]}}}')
  check("decode nested", ok4 and v4.nested.deep.list[3].x == "y")

  local okE, enc = json.encode({ a = 1, b = "two", c = { 1, 2, 3 } })
  local okR, back = json.decode(enc)
  check("encode/decode roundtrip", okE and okR and back.a == 1 and back.c[2] == 2)

  local okU, u = json.encode({ s = "café\n€\230\152\163" })
  check("encodes non-ascii safely", okU and type(u) == "string" and #u > 0)

  local okR2, back2 = json.decode(u)
  check("roundtrip non-ascii", okR2 and back2.s == "café\n€\230\152\163")

  local _, errN = json.encode({ bad = 0 / 0 })
  check("rejects NaN", errN ~= nil)

  local okSur, val = json.decode('"\\ud83d\\ude00"') -- 😀 surrogate pair
  check("decodes surrogate pair", okSur and val == "😀")

  local okLone, lone = json.decode('"\\ud83d"')
  check("lone surrogate -> replacement", okLone and lone ~= nil)
end

-- ── timeutil ─────────────────────────────────────────────────────────────────

section("timeutil")
do
  check("dateKey format", timeutil.dateKey(1725840000) == "2024-09-09" or #timeutil.dateKey(1725840000) == 10)
  check("dateKeyOf offset", #timeutil.dateKeyOf(1725840000, -1) == 10)
  check("valid key", timeutil.isValidDateKey("2026-02-28"))
  check("invalid key rejected", not timeutil.isValidDateKey("2026-02-30"))
  check("invalid format rejected", not timeutil.isValidDateKey("20260230"))
  check("isBefore", timeutil.isBefore("2026-01-01", "2026-01-02"))
  check("isBefore equal false", not timeutil.isBefore("2026-01-02", "2026-01-02"))
  check("dayDiff", timeutil.dayDiff("2026-01-01", "2026-01-08") == 7)
  check("dayDiff across year", timeutil.dayDiff("2025-12-31", "2026-01-01") == 1)
  check("classify normal", timeutil.classifyTick(1000000, 1002000, 60000) == "normal")
  check("classify gap", timeutil.classifyTick(1000000, 2000000, 60000) == "gap")
  check("classify clock_back", timeutil.classifyTick(2000000, 1000000, 60000) == "clock_back")
end

-- ── formatting ───────────────────────────────────────────────────────────────

section("formatting")
do
  -- The prelude's noctalia.tr stub returns the raw key for format keys, so
  -- bind the known English strings through the module's tr hook instead.
  local trMap = {
    format_duration_hours_minutes = "format.duration_hours_minutes",
  }
  formatting._tr = function(key, subst)
    local strings = {
      ["format.duration_hours_minutes"] = "{h}h {m}m",
      ["format.duration_hours"] = "{h}h",
      ["format.duration_minutes"] = "{m}m",
      ["format.duration_seconds"] = "{s}s",
      ["format.duration_minutes_seconds"] = "{m}m {s}s",
      ["format.duration_under_minute"] = "<1m",
    }
    local out = strings[key] or key
    if type(subst) == "table" then
      for k, v in pairs(subst) do
        out = out:gsub("{" .. k .. "}", tostring(v))
      end
    end
    return out
  end
  check("hours+minutes", formatting.fmtDuration(3 * 3600 + 42 * 60) == "3h 42m")
  check("hours only", formatting.fmtDuration(2 * 3600) == "2h")
  check("minutes", formatting.fmtDuration(42 * 60) == "42m")
  check("zero", formatting.fmtDuration(0) == "0m")
  check("sub-minute is <1m, never 0m", formatting.fmtDuration(20) == "<1m")
  check("negative clamps", formatting.fmtDuration(-5) == "0m")
  check("seconds incl", formatting.fmtDuration(65, true) == "1m 5s")
  check("seconds excl", formatting.fmtDuration(65) == "1m")
end

-- ── tracker: session merging ─────────────────────────────────────────────────

section("tracker: merging")
do
  local t = tracker_mod.newTracker({
    dateKeyFn = function(ms) return "2026-09-09" end,
    maxGapMs = 60000,
  })
  -- 10:00:00, same app for 30 min of 2s samples
  t:consume({ type = "sample", app = { appId = "firefox", appName = "Firefox" } }, 0)
  for ms = 2000, 30 * 60 * 1000, 2000 do
    t:consume({ type = "sample", app = { appId = "firefox", appName = "Firefox" } }, ms)
  end
  check("one session for continuous app", #t.sessions == 0 and t.open ~= nil)
  check("open session holds app", t.open.appId == "firefox")

  -- Switch to kitty at the 30-minute mark
  t:consume({ type = "sample", app = { appId = "kitty", appName = "kitty" } }, 30 * 60 * 1000 + 2000)
  check("switch closes first session", #t.sessions == 1 and t.open.appId == "kitty")
  check("first session duration ~30min", t.sessions[1].durationSeconds >= 1790 and t.sessions[1].durationSeconds <= 1801)
  check("boundary is not before start", t.sessions[1].endedAtMs >= t.sessions[1].startedAtMs)

  -- Back to firefox: three sessions total after this switch
  t:consume({ type = "sample", app = { appId = "firefox", appName = "Firefox" } }, 32 * 60 * 1000)
  check("second switch keeps sessions separate", #t.sessions == 2 and t.open.appId == "firefox")
  check("kitty session is short", t.sessions[2].durationSeconds <= 120)
end

-- ── tracker: idle / close / suspend ──────────────────────────────────────────

section("tracker: idle/suspend/clock")
do
  local t = tracker_mod.newTracker({
    dateKeyFn = function(ms) return "2026-09-09" end,
    maxGapMs = 60000,
  })
  t:consume({ type = "sample", app = { appId = "a" } }, 0)
  t:consume({ type = "sample", app = { appId = "a" } }, 10000)
  t:consume({ type = "idle" }, 20000)
  check("idle closes session", #t.sessions == 1 and t.open == nil)
  check("idle session ends at last sample", t.sessions[1].endedAtMs == 10000)

  t:consume({ type = "sample", app = { appId = "b" } }, 30000)
  check("resume after idle opens fresh", t.open ~= nil and t.open.appId == "b")
  check("new session starts at now", t.open.startedAtMs == 30000)

  -- suspend then resume: nothing counted during the dark period
  t:consume({ type = "sample", app = { appId = "b" } }, 40000)
  t:consume({ type = "suspend" }, 45000)
  check("suspend closes", t.open == nil)
  t:consume({ type = "resume" }, 400000)
  t:consume({ type = "sample", app = { appId = "b" } }, 410000)
  check("post-suspend session fresh", t.open.startedAtMs == 410000)
  check("suspended gap not credited", t.sessions[#t.sessions].endedAtMs == 40000) -- last *observed* sample, not suspend time

  -- clock goes backwards
  t:consume({ type = "sample", app = { appId = "b" } }, 420000)
  t:consume({ type = "sample", app = { appId = "b" } }, 100000) -- backwards!
  check("clock_back closes without negative time", t.sessions[#t.sessions].durationSeconds >= 0)

  -- gap too large
  t:consume({ type = "sample", app = { appId = "b" } }, 900000)
  check("gap closes session", t.open.startedAtMs == 900000)
end

-- ── aggregation ──────────────────────────────────────────────────────────────

section("aggregation")
do
  local sessions = {
    { id = "1", dateKey = "2026-09-09", appId = "firefox", appName = "Firefox", durationSeconds = 3600 },
    { id = "2", dateKey = "2026-09-09", appId = "kitty", appName = "kitty", durationSeconds = 7200 },
    { id = "3", dateKey = "2026-09-08", appId = "firefox", appName = "Firefox", durationSeconds = 1800 },
    { id = "4", dateKey = "2026-09-08", appId = "obsidian", appName = "obsidian", durationSeconds = 900 },
  }
  local day = aggregation.daySummary(sessions, "2026-09-09", 5)
  check("today total", day.total == 10800)
  check("today apps", day.appCount == 2)
  check("rank order", day.topApps[1].appId == "kitty" and day.topApps[2].appId == "firefox")

  local yesterday = aggregation.daySummary(sessions, "2026-09-08", 5)
  check("yesterday total", yesterday.total == 2700)
  check("yesterday apps", yesterday.appCount == 2)

  local wk = aggregation.weekSummary(sessions, "2026-09-09", 7, 5)
  check("week total", wk.total == 13500)
  check("week perDay has 7 buckets", #wk.perDay == 7)
  local sum = 0
  for _, d in ipairs(wk.perDay) do
    sum = sum + d.total
  end
  check("perDay sums to total", sum == wk.total)
  check("weekly average", math.abs(wk.dailyAverage - 13500 / 7) < 0.001)
  check("weekly top", wk.topApps[1].appId == "kitty")
end

-- ── storage ──────────────────────────────────────────────────────────────────

section("storage")
do
  -- In-memory host double: exercises the same code paths as noctalia.*.
  local files = {}
  local function hostDouble()
    return {
      dataDir = function() return "/data" end,
      mkdirAll = function() return true end,
      readFile = function(p) return files[p], nil end,
      writeFile = function(p, c) files[p] = c; return true, nil end,
      renameFile = function(a, b) files[b] = files[a]; files[a] = nil; return true, nil end,
      removeFile = function(p) files[p] = nil; return true, nil end,
      listDir = function(_dir)
        local out = {}
        for name in pairs(files) do
          table.insert(out, name)
        end
        return out, nil
      end,
      fileExists = function(p) return files[p] ~= nil end,
      log = function() end,
    }
  end

  local store = storage_mod.newStorage({ host = hostDouble(), encode = json.encode, decode = json.decode })
  local ok, err = store:load()
  check("first load creates empty", ok == true and #store.sessions == 0)

  store.sessions = { { id = "s1", dateKey = "2026-09-09", appId = "x", startedAtMs = 1000, durationSeconds = 10 } }
  local okSave = store:save(store.sessions)
  check("save ok", okSave == true and files["/data/history.json"] ~= nil)

  local store2 = storage_mod.newStorage({ host = hostDouble(), encode = json.encode, decode = json.decode })
  local ok2 = store2:load()
  check("reload recovers sessions", ok2 == true and #store2.sessions == 1 and store2.sessions[1].id == "s1")

  -- malformed file -> backup + empty start
  files["/data/history.json"] = "{not json"
  local store3 = storage_mod.newStorage({ host = hostDouble(), encode = json.encode, decode = json.decode })
  local ok3, err3 = store3:load()
  check("malformed handled", ok3 == false and #store3.sessions == 0 and type(err3) == "string")
  local hadBackup = false
  for name in pairs(files) do
    if name:find("history.corrupt-", 1, true) then
      hadBackup = true
    end
  end
  check("corrupt file backed up", hadBackup)

  -- unknown version -> preserved, not destroyed
  files["/data/history.json"] = '{"version":99,"sessions":[]}'
  local store4 = storage_mod.newStorage({ host = hostDouble(), encode = json.encode, decode = json.decode })
  local ok4, err4 = store4:load()
  check("unknown version starts empty", ok4 == false and #store4.sessions == 0)
  local keptUnknown = false
  for name in pairs(files) do
    if name:find("history.unknown-", 1, true) then
      keptUnknown = true
    end
  end
  check("unknown version file preserved", keptUnknown)

  -- clear
  store2:clear()
  check("clear removes file", files["/data/history.json"] == nil)
end

-- ── retention ────────────────────────────────────────────────────────────────

section("retention")
do
  local sessions = {
    { id = "a", dateKey = "2026-09-09", startedAtMs = 1, durationSeconds = 10, open = true },
    { id = "b", dateKey = "2026-09-09", startedAtMs = 1, durationSeconds = 10 },
    { id = "c", dateKey = "2026-08-10", startedAtMs = 1, durationSeconds = 10 },
    { id = "d", dateKey = "garbage", startedAtMs = 1, durationSeconds = 10 },
    { id = "e", dateKey = "2026-09-01", startedAtMs = 1, durationSeconds = 0 },
  }
  local kept, removed = tracker_mod.pruneSessions(sessions, "2026-09-09", 30)
  check("keeps open + in-window", #kept == 2)
  check("removes old/garbage/zero", removed == 3)
end

-- ── shell exclusion (Noctalia must never be tracked) ───────────────────────

section("exclusion: identifiers")
do
  -- Test 1: the shell's exact application id is excluded.
  check("noctalia appId excluded", exclusion.isExcludedApplication({ appId = "dev.noctalia.Noctalia" }))
  check("noctalia initialClass matched too", exclusion.isExcludedApplication({ appId = "custom", initialClass = "dev.noctalia.Noctalia" }))
  -- Test 2: real user applications are not excluded.
  check("firefox not excluded", not exclusion.isExcludedApplication({ appId = "firefox" }))
  -- Exact matches only: user apps that merely contain "noctalia" must survive.
  check("substring not excluded", not exclusion.isExcludedApplication({ appId = "my-noctalia-notes" }))
  check("different case not excluded", not exclusion.isExcludedApplication({ appId = "dev.noctalia.noctalia" }))
  check("non-table safe", not exclusion.isExcludedApplication(nil) and not exclusion.isExcludedApplication("firefox"))
end

section("exclusion: tracker integration")
do
  -- Test 3: 60 seconds of Noctalia adds 0 seconds of user activity.
  local t = tracker_mod.newTracker({
    dateKeyFn = function() return "2026-09-09" end,
    maxGapMs = 60000,
  })
  t:consume({ type = "sample", app = { appId = "firefox", appName = "Firefox" } }, 0)
  t:consume({ type = "sample", app = { appId = "firefox", appName = "Firefox" } }, 10000)
  for ms = 20000, 78000, 2000 do -- 60 s of Noctalia samples
    t:consume({ type = "sample", app = { appId = "dev.noctalia.Noctalia", appName = "dev.noctalia.Noctalia" } }, ms)
  end
  t:consume({ type = "sample", app = { appId = "firefox", appName = "Firefox" } }, 80000)
  check("noctalia session never created", t.open ~= nil and t.open.appId == "firefox" and #t.sessions == 1)
  check("firefox closed before noctalia started", t.sessions[1].appId == "firefox" and t.sessions[1].endedAtMs == 15000)
  check("zero noctalia seconds tracked", t.sessions[1].durationSeconds == 15) -- 0..15s firefox; 15..80s untracked
end

do
  -- Test 4: Firefox 10:00 -> Noctalia 10:10 -> Firefox 10:20. Exactly two
  -- firefox sessions; the 10-minute Noctalia interval is an untracked gap.
  local t = tracker_mod.newTracker({
    dateKeyFn = function() return "2026-09-09" end,
    maxGapMs = 60000,
  })
  local MIN = 60 * 1000
  t:consume({ type = "sample", app = { appId = "firefox" } }, 0) -- 10:00
  for ms = 2000, 10 * MIN, 2000 do
    t:consume({ type = "sample", app = { appId = "firefox" } }, ms)
  end
  t:consume({ type = "sample", app = { appId = "dev.noctalia.Noctalia" } }, 10 * MIN) -- 10:10
  for ms = 10 * MIN + 2000, 20 * MIN - 2000, 2000 do
    t:consume({ type = "sample", app = { appId = "dev.noctalia.Noctalia" } }, ms)
  end
  t:consume({ type = "sample", app = { appId = "firefox" } }, 20 * MIN) -- 10:20
  check("exactly one closed session (noctalia never stored)", #t.sessions == 1)
  check("closed session is firefox", t.sessions[1].appId == "firefox")
  check("firefox session ends at 10:10 switch", t.sessions[1].endedAtMs == 10 * MIN)
  check("second firefox session starts at 10:20", t.open ~= nil and t.open.startedAtMs == 20 * MIN)
  check("no noctalia session anywhere", (function()
    for _, s in ipairs(t.sessions) do
      if s.appId == "dev.noctalia.Noctalia" then return false end
    end
    return t.open == nil or t.open.appId ~= "dev.noctalia.Noctalia"
  end)())
  check("10-minute gap untracked", t.sessions[1].endedAtMs <= 10 * MIN and t.open.startedAtMs >= 20 * MIN)
end

do
  -- Test 5: Noctalia layer/panel/overlay active -> no trackable application.
  -- (Layer surfaces never appear as activewindow toplevels: hyprctl answers
  -- "Invalid". A Noctalia toplevel, when focused, is filtered by exclusion.)
  local provider = hyprland_mod.newProvider({})
  local seen
  _G.WDID_TEST_ASYNC = function(_args, cb)
    cb({ exitCode = 0, stdout = "Invalid" }) -- layer-shell surface focused
    return true
  end
  provider.activeWindow(function(app) seen = app end)
  check("layer surface -> no trackable app", seen == nil)

  seen = "sentinel"
  _G.WDID_TEST_ASYNC = function(_args, cb)
    cb({ exitCode = 0, stdout = '{"class":"dev.noctalia.Noctalia","initialClass":"dev.noctalia.Noctalia","title":"Settings","mapped":true}' })
    return true
  end
  provider.activeWindow(function(app) seen = app end)
  check("noctalia toplevel filtered at provider", seen == nil)

  seen = "sentinel"
  _G.WDID_TEST_ASYNC = function(_args, cb)
    cb({ exitCode = 0, stdout = '{"class":"firefox","initialClass":"firefox","title":"Mozilla Firefox","mapped":true}' })
    return true
  end
  provider.activeWindow(function(app) seen = app end)
  check("normal toplevel passes through", type(seen) == "table" and seen.appId == "firefox")
  _G.WDID_TEST_ASYNC = nil
end

do
  -- Test 6: plugin restart while Noctalia itself is visible. Shell rows left
  -- in storage (open or closed, e.g. written by an older version) must not be
  -- recovered; no Noctalia recovery session may ever exist.
  local files = {}
  local function hostDouble()
    return {
      dataDir = function() return "/data" end,
      mkdirAll = function() return true end,
      readFile = function(p) return files[p], nil end,
      writeFile = function(p, c) files[p] = c; return true, nil end,
      renameFile = function(a, b) files[b] = files[a]; files[a] = nil; return true, nil end,
      removeFile = function(p) files[p] = nil; return true, nil end,
      listDir = function() return {} end,
      fileExists = function(p) return files[p] ~= nil end,
      log = function() end,
    }
  end
  local okEnc, stored = json.encode({
    version = 1,
    sessions = {
      { id = "n1", dateKey = "2026-09-09", appId = "dev.noctalia.Noctalia", appName = "dev.noctalia.Noctalia", startedAtMs = 1000, durationSeconds = 55 },
      { id = "n2", dateKey = "2026-09-09", appId = "dev.noctalia.Noctalia", appName = "dev.noctalia.Noctalia", startedAtMs = 2000, open = true },
      { id = "f1", dateKey = "2026-09-09", appId = "firefox", appName = "Firefox", startedAtMs = 3000, durationSeconds = 120 },
    },
  })
  check("test fixture encoded", okEnc and type(stored) == "string")
  files["/data/history.json"] = stored
  local store = storage_mod.newStorage({ host = hostDouble(), encode = json.encode, decode = json.decode })
  store:load()
  local noctaliaRows = 0
  for _, s in ipairs(store.sessions) do
    if s.appId == "dev.noctalia.Noctalia" then noctaliaRows = noctaliaRows + 1 end
  end
  check("shell rows never recovered from storage", #store.sessions == 1 and noctaliaRows == 0)
  check("user session survived", store.sessions[1] ~= nil and store.sessions[1].appId == "firefox")

  -- Starting up while the shell is focused tracks nothing at all.
  local t = tracker_mod.newTracker({ dateKeyFn = function() return "2026-09-09" end })
  t:consume({ type = "start" }, 0)
  t:consume({ type = "sample", app = { appId = "dev.noctalia.Noctalia" } }, 5000)
  check("startup sample of shell creates nothing", t.open == nil and #t.sessions == 0)
end

-- ── application display-name resolution ─────────────────────────────────────

do
  local appnames = prelude.loadModule(base, "lib/appnames.luau")

  -- Spec examples.
  check("freebuff id -> Freebuff", appnames.resolveDisplayName("@codebuff/freebuff-desktop") == "Freebuff")
  check("brave id -> Brave", appnames.resolveDisplayName("brave-browser") == "Brave")
  check("telegram id -> Telegram", appnames.resolveDisplayName("org.telegram.desktop") == "Telegram")
  check("discord id -> Discord", appnames.resolveDisplayName("discord") == "Discord")

  -- Trusted provider metadata wins; package-like echoes do not.
  check("trusted metadata kept", appnames.resolveDisplayName("unknown-app", "Cool App") == "Cool App")
  check("package-like metadata rejected", appnames.resolveDisplayName("org.gnome.Evince", "org.gnome.Evince") ~= "org.gnome.Evince")

  -- Fallbacks: never empty; derivation never invents a sentence.
  check("unknown id falls back", appnames.resolveDisplayName("some-weird-bin") == "Some Weird")
  check("empty id -> ?", appnames.resolveDisplayName("") == "?")
  check("nil args -> ?", appnames.resolveDisplayName(nil, nil) == "?")
  check("empty appName falls back to id", appnames.resolveDisplayName("myapp", "") == "Myapp")
  check("opaque id still readable", appnames.resolveDisplayName("xX_custom_Xx") == "xX Custom Xx")

  -- Identifiers are never rewritten in the data layer.
  check("package-like detection", appnames.isPackageLike("@scope/pkg") and appnames.isPackageLike("org.x.Y"))
  check("plain class not package-like", not appnames.isPackageLike("firefox"))

  -- Desktop-file resolver: cached, failure-absorbing, id-preserving.
  local files = {
    ["/usr/share/applications/org.telegram.desktop.desktop"] = "[Desktop Entry]\nName=Telegram Desktop\nType=Application\n",
    ["/home/t/.local/share/applications/freebuff.desktop"] = "[Desktop Entry]\nName=Freebuff\n",
  }
  local listingCalls = 0
  local r = appnames.newResolver({
    getenv = function(k) return k == "HOME" and "/home/t" or nil end,
    listDir = function(dir)
      listingCalls = listingCalls + 1
      if dir == "/usr/share/applications" then return { "org.telegram.desktop.desktop", "notes.txt" } end
      if dir == "/home/t/.local/share/applications" then return { "freebuff.desktop" } end
      return nil
    end,
    readFile = function(p) return files[p] end,
  })
  check("desktop Name= used (telegram)", r.resolve("org.telegram.desktop") == "Telegram Desktop")
  check("desktop Name= used (freebuff)", r.resolve("@codebuff/freebuff") == "Freebuff")
  check("missing desktop file falls back", r.resolve("no-such-app") == "No Such")
  check("unparsable desktop file falls back", r.resolve("weird-bin") ~= "" and r.resolve("weird-bin") ~= nil)
  -- One scan across the whole resolver lifetime: XDG_DATA_DIRS entries (2)
  -- + the user dir + two flatpak export dirs = 5 listDir calls, once.
  check("desktop-file scan ran once", listingCalls == 5)
  check("cached resolve stable", r.resolve("org.telegram.desktop") == "Telegram Desktop")
  -- app_id in == app_id out: display resolution never touches identity.
  check("resolver keeps id intact", r.resolve("org.telegram.desktop", "Telegram Desktop") == "Telegram Desktop")

  -- Aggregation keeps the technical id next to the resolved label.
  local ranked = aggregation.rankApps({
    { appId = "@codebuff/freebuff-desktop", appName = "@codebuff/freebuff-desktop", durationSeconds = 60 },
    { appId = "firefox", appName = "Firefox", durationSeconds = 30 },
  }, 10)
  check("rankApps preserves appId", ranked[1].appId == "@codebuff/freebuff-desktop")

  -- Zero-second rows are not "usage": they must not surface as "0m" list
  -- entries in the UI (day total / week totals are computed separately and
  -- stay exact).
  local withZero = aggregation.rankApps({
    { appId = "brave", appName = "Brave", durationSeconds = 0 },
    { appId = "firefox", appName = "Firefox", durationSeconds = 120 },
  }, 10)
  check("zero-second app dropped from ranking", #withZero == 1 and withZero[1].appId == "firefox")
  local allZero = aggregation.rankApps({
    { appId = "brave", appName = "Brave", durationSeconds = 0 },
    { appId = "kitty", appName = "Kitty", durationSeconds = 0 },
  }, 10)
  check("all-zero day ranks empty", #allZero == 0)
  local zeroDay = aggregation.daySummary({
    { id = "z", dateKey = "2026-09-09", appId = "brave", appName = "Brave", startedAtMs = 1, durationSeconds = 0 },
  }, "2026-09-09", 6)
  check("zero-day total still exact", zeroDay.total == 0)
  check("zero-day appCount hides 0m rows", zeroDay.appCount == 0 and #zeroDay.topApps == 0)
  check("zero-day session list keeps data", zeroDay.sessionCount == 1)
end

-- ── panel/desktop-widget data paths stay bounded and sane ───────────────────

do
  -- 200 closed sessions across one day: daySummary must stay correct and the
  -- scroll region receives every row (rendering clips, data does not shrink).
  local many = {}
  for i = 1, 200 do
    many[i] = { id = "s" .. i, dateKey = "2026-09-09", appId = "app" .. (i % 7), appName = "App " .. (i % 7), startedAtMs = i * 60000, durationSeconds = 30 }
  end
  local summary = aggregation.daySummary(many, "2026-09-09", 6)
  check("large day: session count intact", summary.sessionCount == 200)
  check("large day: total correct", summary.total == 200 * 30)
  check("large day: top apps limited", #summary.topApps == 6)
  check("large day: ranked seconds sound", summary.topApps[1].seconds > 0)
  -- Empty and single-session days render valid data too.
  check("empty day is empty", aggregation.daySummary({}, "2026-09-09", 6).sessionCount == 0)
  check("single session day", aggregation.daySummary({ many[1] }, "2026-09-09", 6).sessionCount == 1)
end

-- ── duration formatting against the real translation files ─────────────────

-- Regression: the Turkish file once used a {d} placeholder where the code
-- substitutes {m}, so users saw literal "3sa {d}d". These checks load the
-- actual JSON files and fail if any format string drifts from the code's
-- placeholder contract (this also guards every future translation). Localized
-- tr.json must mirror en.json's placeholders exactly, per key.
do
  local function loadStrings(path)
    local fh = assert(io.open(path, "r"), "cannot read " .. path)
    local contents = fh:read("*a")
    fh:close()
    local jsonmod = prelude.loadModule(base, "lib/json.luau")
    local ok, parsed = jsonmod.decode(contents)
    assert(ok and type(parsed) == "table", "cannot parse " .. path)
    return parsed
  end
  local en = loadStrings("translations/en.json").format
  local trStrings = loadStrings("translations/tr.json").format
  -- The code looks keys up with the dotted "format.x" path; the JSON nests
  -- them under the "format" object, so flatten for the substitution hook.
  local function trFlat(key, subst)
    local short = key:gsub("^format%.", "")
    local out = trStrings[short] or key
    if type(subst) == "table" then
      for k, v in pairs(subst) do
        out = out:gsub("{" .. k .. "}", tostring(v))
      end
    end
    return out
  end
  formatting._tr = trFlat

  local function extract(text)
    local set = {}
    for ph in text:gmatch("{(%w+)}") do
      set[ph] = true
    end
    return set
  end
  local function samePlaceholders(a, b)
    local ka, kb = extract(a), extract(b)
    for k in pairs(ka) do
      if not kb[k] then return false end
    end
    for k in pairs(kb) do
      if not ka[k] then return false end
    end
    return true
  end

  -- The contract: the code substitutes a fixed set per key (the set en.json
  -- uses). A translation may use any subset (Turkish renders "2sa 0dk" where
  -- English says "2h"), but a placeholder outside the set leaks literally —
  -- the "3sa {d}d" bug. So tr[key] placeholders must be a SUBSET of en's.
  local function subsetOf(inner, outer)
    for k in pairs(inner) do
      if not outer[k] then return false end
    end
    return true
  end
  for _, key in ipairs({
    "duration_hours_minutes", "duration_hours", "duration_minutes",
    "duration_seconds", "duration_under_minute", "duration_minutes_seconds",
  }) do
    check("tr placeholders valid for " .. key, subsetOf(extract(trStrings[key]), extract(en[key])))
  end

  -- Substitution against the real Turkish strings: no braces survive.
  formatting._tr = function(key, subst)
    local out = trStrings[key] or key
    if type(subst) == "table" then
      for k, v in pairs(subst) do
        out = out:gsub("{" .. k .. "}", tostring(v))
      end
    end
    return out
  end
  formatting._tr = trFlat
  check("tr hours+minutes", formatting.fmtDuration(3 * 3600 + 21 * 60) == "3sa 21dk")
  check("tr minutes only", formatting.fmtDuration(6 * 60) == "6dk")
  check("tr hours only (zero minutes)", formatting.fmtDuration(2 * 3600) == "2sa")
  check("tr leaves no placeholder behind", not formatting.fmtDuration(7500):find("{"))
  formatting._tr = nil
end

-- ── week aggregation feeds a non-empty 7-day view ───────────────────────────

-- Regression: the 7-day tab appeared empty while data existed. The view's
-- data source must include today's sessions (open ones included) so the
-- aggregate can never come back empty when history has recent rows.
do
  local nowKey = os.date("!%Y-%m-%d")
  local sessions = {
    { id = "t1", dateKey = nowKey, appId = "firefox", appName = "Firefox", startedAtMs = 1000, durationSeconds = 600 },
    { id = "t2", dateKey = nowKey, appId = "kitty", appName = "Kitty", startedAtMs = 2000, durationSeconds = 300, open = true },
    { id = "y1", dateKey = aggregation.shiftDateKey(nowKey, -1), appId = "discord", appName = "Discord", startedAtMs = 3000, durationSeconds = 900 },
  }
  local wk = aggregation.weekSummary(sessions, nowKey, 7, 6)
  check("week window includes today", wk.total == 1800)
  check("week topApps non-empty", #wk.topApps == 3)
  check("week perDay covers 7 days", #wk.perDay == 7)
  local todayRow = wk.perDay[7]
  check("panel: perDay last entry is today", todayRow.dateKey == nowKey and todayRow.total == 900)
end

-- ── appicons: shared icon resolution helper ──────────────────────────────

section("appicons")
do
  local appicons = prelude.loadModule(base, "lib/appicons.luau")

  -- Known id resolves to the host path; host consulted exactly once per
  -- id+size no matter how often resolve() runs (the cache contract).
  local icons = appicons.newResolver({
    appIconPath = function(id, _size)
      if id == "brave-browser" then
        return "/usr/share/icons/brave.png"
      end
      return nil
    end,
  })
  check("appicons: known id resolves to host path", icons.resolve("brave-browser", 24) == "/usr/share/icons/brave.png")
  check("appicons: size is part of the cache key", icons.resolve("brave-browser", 16) == "/usr/share/icons/brave.png")
  for _ = 1, 5 do
    icons.resolve("brave-browser", 24)
    icons.resolve("brave-browser", 16)
  end
  check("appicons: cache prevents repeated host resolution", icons.hostCallCount() == 2)

  -- Unknown app -> nil, and the miss is cached too (no re-asking).
  check("appicons: unknown app resolves to nil", icons.resolve("no-such-app", 24) == nil)
  for _ = 1, 3 do
    icons.resolve("no-such-app", 24)
  end
  check("appicons: cached miss does not re-consult the host", icons.hostCallCount() == 3)

  -- Invalid ids never reach the host.
  check("appicons: empty id resolves to nil", icons.resolve("", 24) == nil)
  check("appicons: non-string id resolves to nil", icons.resolve(nil, 24) == nil and icons.resolve(42, 24) == nil)

  -- display_name stays independent from app_id: the helper resolves whatever
  -- string it is given, verbatim — "Brave" must never fetch the
  -- brave-browser icon (and vice versa).
  local seen = {}
  local byName = appicons.newResolver({
    appIconPath = function(id, _size)
      seen[id] = true
      if id == "brave-browser" then
        return "/icons/technical.png"
      end
      return nil
    end,
  })
  check("appicons: display name does not resolve the app id's icon", byName.resolve("Brave", 24) == nil)
  check("appicons: technical app id still resolves", byName.resolve("brave-browser", 24) == "/icons/technical.png")
  check("appicons: ids reach the host verbatim", seen["Brave"] == true and seen["brave-browser"] == true)

  -- Host errors are absorbed as misses (pcall), never propagated to the UI.
  local exploding = appicons.newResolver({
    appIconPath = function()
      error("host exploded")
    end,
  })
  check("appicons: host error degrades to nil", exploding.resolve("brave-browser", 24) == nil)
  exploding.resolve("brave-browser", 24)
  check("appicons: error miss is cached too", exploding.hostCallCount() == 1)
end

-- ── panel render: history must survive "no focused app" ─────────────────────

-- Regression for the empty-panel bug: currentApp == nil must NOT suppress
-- today's historical view. Drives the real panel.luau against a stub host
-- (ui.* factories record their kind; state is a plain store) and asserts
-- on the rendered tree for all four required states plus tab switching.
do
  -- Flat "section.key" strings from the real en.json for the host tr/trp.
  local trStrings = {}
  local function flatten(prefix, tbl)
    for k, v in pairs(tbl) do
      if type(v) == "table" then
        flatten(prefix .. k .. ".", v)
      else
        trStrings[prefix .. k] = v
      end
    end
  end
  local fh = io.open(base .. "/translations/en.json", "r")
  local okEn, enjson = json.decode(fh:read("*a"))
  fh:close()
  check("panel test: en.json parses", okEn == true and type(enjson) == "table")
  flatten("", enjson)
  local function trStub(key, subst)
    local out = trStrings[key] or key
    if type(subst) == "table" then
      for k, v in pairs(subst) do
        out = out:gsub("{" .. k .. "}", tostring(v))
      end
    end
    return out
  end

  -- ui stub: ui.<anything>(props, kids) records its kind for tree searches.
  local function makeNode(kind, props, kids)
    return { kind = kind, p = props or {}, kids = kids or {} }
  end
  local ui = setmetatable({}, {
    __index = function(_, kind)
      return function(props, kids)
        return makeNode(kind, props, kids)
      end
    end,
  })

  local function collect(n, out)
    out = out or {}
    if type(n) == "table" then
      if n.kind then
        out[#out + 1] = n
      end
      for _, k in ipairs(n.kids or {}) do
        collect(k, out)
      end
    end
    return out
  end
  local function hasKind(tree, kind)
    for _, n in ipairs(collect(tree)) do
      if n.kind == kind then return true end
    end
    return false
  end
  local function hasLabelText(tree, want)
    for _, n in ipairs(collect(tree)) do
      if n.kind == "label" and n.p.text == want then return true end
    end
    return false
  end
  local function countLabelText(tree, want)
    local c = 0
    for _, n in ipairs(collect(tree)) do
      if n.kind == "label" and n.p.text == want then c = c + 1 end
    end
    return c
  end
  local function findButton(tree, key)
    for _, n in ipairs(collect(tree)) do
      if n.kind == "button" and n.p.key == key then return n end
    end
    return nil
  end

  -- Icon host bookkeeping: how often the host was consulted per id@size
  -- (the icon contract tests assert the cache prevents re-resolution).
  local iconCounts = {}

  -- Fresh host + store per scenario; fresh panel module instance per load.
  local function makeHost(store)
    return {
      log = function() end,
      nowMs = function() return os.time() * 1000 end,
      tr = trStub,
      trp = function(key, _n, subst) return trStub(key, subst) end,
      state = {
        get = function(k) return store[k] end,
        set = function(k, v) store[k] = v end,
        watch = function() end,
      },
      openSettings = function() end,
      -- Only brave-browser resolves; everything else is a miss (fallback
      -- rows must keep rendering without an icon).
      appIconPath = function(id, size)
        local k = tostring(id) .. "@" .. tostring(size)
        iconCounts[k] = (iconCounts[k] or 0) + 1
        if id == "brave-browser" then
          return "/icons/" .. k .. ".png"
        end
        return nil
      end,
      formatTime = function() return "14:16" end,
      readFile = function() return nil end,
      listDir = function() return nil end,
      getenv = function() return nil end,
    }
  end

  local lastTree
  -- The panel consumes the host globals ui/panel/noctalia; inject ui+panel
  -- directly (noctalia goes through WDID_TEST_NOCTALIA in the prelude).
  local function loadPanel(store)
    _G.WDID_TEST_NOCTALIA = function() return makeHost(store) end
    _G.ui = ui
    _G.panel = { render = function(tree) lastTree = tree end }
    local _, env = prelude.loadModule(base, "panel.luau")
    return env
  end
  local function cleanup()
    _G.WDID_TEST_NOCTALIA = nil
    _G.ui = nil
    _G.panel = nil
  end

  local nowKey = timeutil.dateKeyOf(os.time(), 0)
  local sessions = {
    { id = "s1", dateKey = nowKey, appId = "brave-browser", appName = "Brave", startedAtMs = (os.time() - 2000) * 1000, durationSeconds = 1980 },
    { id = "s2", dateKey = nowKey, appId = "kitty", appName = "Kitty", startedAtMs = (os.time() - 900) * 1000, durationSeconds = 600 },
  }

  -- State 1: tracker not initialized yet -> waiting hint, no session scroll.
  do
    local store = {}
    local env = loadPanel(store)
    env.render()
    check("state1: waiting hint shown", hasLabelText(lastTree, "Waiting for the tracker…"))
    check("state1: no session scroll region", not hasKind(lastTree, "scroll"))
    cleanup()
  end

  -- States 2+4: initialized, historical data exists, currentApp nil vs set.
  -- Either way today's history (total, top apps, sessions) MUST render.
  local function dataScenario(currentAppName, label)
    local store = {
      wdid_state = { schema = 1, tracking = true, paused = false, currentApp = currentAppName and "brave-browser" or nil, currentAppName = currentAppName or "", todayTotal = 2580, todayTopApps = {} },
      wdid_sessions = { sessions = sessions, rev = 1 },
    }
    local env = loadPanel(store)
    env.render()
    check(label .. ": total 43m rendered", hasLabelText(lastTree, "43m"))
    check(label .. ": top apps section present", hasLabelText(lastTree, "Top applications"))
    check(label .. ": top apps section appears exactly once", countLabelText(lastTree, "Top applications") == 1)
    check(label .. ": brave 33m row rendered", hasLabelText(lastTree, "33m"))
    -- The duration legitimately appears in both the top-apps row and the
    -- session row; the SECTION HEADING is what must be unique.
    check(label .. ": brave row appears at least once", countLabelText(lastTree, "33m") >= 1)
    check(label .. ": session scroll region present", hasKind(lastTree, "scroll"))
    check(label .. ": no empty-state text", not hasLabelText(lastTree, "No activity recorded yet"))
    return env
  end

  do
    local env = dataScenario(nil, "state2 (no focused app, has history)")
    check("state2: idle subtitle shown", hasLabelText(lastTree, "No application focused"))
    -- Tab switching on the live tree: 7 days keeps showing data.
    local weekBtn = findButton(lastTree, "tab-week")
    check("state2: week tab exists", weekBtn ~= nil)
    if weekBtn then
      weekBtn.p.onClick()
      check("week tab: total 43m rendered", hasLabelText(lastTree, "43m"))
      check("week tab: per-day section rendered", hasLabelText(lastTree, "Per day"))
      check("week tab: session scroll present", hasKind(lastTree, "scroll"))
    end
    local yBtn = findButton(lastTree, "tab-yesterday")
    if yBtn then
      yBtn.p.onClick()
      check("yesterday tab (no data): empty state shown", hasLabelText(lastTree, "No activity recorded yet"))
      check("yesterday tab (no data): no scroll", not hasKind(lastTree, "scroll"))
    end
    cleanup()
  end

  do
    local env = dataScenario("Brave", "state4 (focused app + history)")
    check("state4: current-session subtitle", hasLabelText(lastTree, "Current session · Brave"))
    check("state4: idle subtitle NOT shown", not hasLabelText(lastTree, "No application focused"))
    cleanup()
  end

  -- State 3: initialized, no focused app, NO history -> compact empty state.
  do
    local store = {
      wdid_state = { schema = 1, tracking = true, paused = false, currentAppName = "" },
      wdid_sessions = { sessions = {}, rev = 1 },
    }
    local env = loadPanel(store)
    env.render()
    check("state3: idle subtitle shown", hasLabelText(lastTree, "No application focused"))
    check("state3: empty-state message shown", hasLabelText(lastTree, "No activity recorded yet"))
    check("state3: no session scroll region", not hasKind(lastTree, "scroll"))
    cleanup()
  end

  -- Footer/scroll layout contract (the "Delete history overlaps the last
  -- session row" bug): the scroll owns the flex space, the Delete history
  -- control is a fixed root-level footer OUTSIDE the scroll, and the
  -- sessions heading sits ABOVE the viewport instead of consuming rows
  -- inside it. 63 sessions must ALL be present as scroll rows (rendering
  -- clips, the data must not shrink).
  do
    local busy = {}
    for i = 1, 63 do
      busy[i] = {
        id = "busy-" .. i,
        dateKey = nowKey,
        appId = "brave-browser",
        appName = "Brave",
        startedAtMs = (os.time() - i * 3600) * 1000,
        durationSeconds = 120,
      }
    end
    local function findNode(tree, key)
      if tree.p and tree.p.key == key then return tree end
      for _, k in ipairs(tree.kids or {}) do
        local hit = findNode(k, key)
        if hit then return hit end
      end
      return nil
    end
    local function contains(node, target)
      if node == target then return true end
      for _, k in ipairs(node.kids or {}) do
        if contains(k, target) then return true end
      end
      return false
    end
    local store = {
      wdid_state = { schema = 1, tracking = true, paused = false, currentAppName = "" },
      wdid_sessions = { sessions = busy, rev = 1 },
    }
    local env = loadPanel(store)
    env.render()
    local scrollNode = findNode(lastTree, "body-scroll")
    check("layout: session scroll region exists", scrollNode ~= nil)
    if scrollNode then
      check("layout: scroll takes remaining height (flexGrow 1)", scrollNode.p.flexGrow == 1)
      check("layout: every session is a scroll child (no cap)", #scrollNode.kids == #busy)
    end
    -- The trStub leaves plural keys unrendered, so assert the heading's
    -- PLACEMENT instead: the raw "panel.sessions_count" label must exist in
    -- the tree but never inside the scroll viewport.
    local headingNode = nil
    local function findHeading(node)
      if node.kind == "label" and node.p.text == "panel.sessions_count" then headingNode = node end
      for _, k in ipairs(node.kids or {}) do findHeading(k) end
    end
    findHeading(lastTree)
    check("layout: sessions heading rendered", headingNode ~= nil)
    if headingNode and scrollNode then
      check("layout: sessions heading outside the viewport", not contains(scrollNode, headingNode))
    end
    local footer = findNode(lastTree, "footer-delete")
    check("layout: delete-history footer exists", footer ~= nil)
    if footer and scrollNode then
      check("layout: delete-history is not inside the scroll", not contains(scrollNode, footer))
    end
    check("layout: root column flexes (scroll only flexes into a flexing parent)", lastTree.p.flexGrow == 1)
    cleanup()
  end

  -- Icon contract (targeted fix): top-app and session rows embed an
  -- ui.image resolved from the TECHNICAL app id; apps without a resolvable
  -- icon keep their row (fallback); the App ID tooltip survives; the host
  -- is consulted once per id+size across re-renders (cache).
  do
    local function findKey(tree, key)
      if tree.p and tree.p.key == key then return tree end
      for _, k in ipairs(tree.kids or {}) do
        local hit = findKey(k, key)
        if hit then return hit end
      end
      return nil
    end
    local function hasImageIn(node, path)
      if node.kind == "image" and node.p.path == path then return true end
      for _, k in ipairs(node.kids or {}) do
        if hasImageIn(k, path) then return true end
      end
      return false
    end
    local store = {
      wdid_state = { schema = 1, tracking = true, paused = false, currentAppName = "" },
      wdid_sessions = { sessions = sessions, rev = 1 },
    }
    local env = loadPanel(store)
    env.render()

    local topRow = findKey(lastTree, "app-1-brave-browser")
    check("icons: top-app row for brave exists", topRow ~= nil)
    check("icons: top-app row includes icon node (24px lookup)", topRow ~= nil and hasImageIn(topRow, "/icons/brave-browser@24.png"))

    local sessRow = findKey(lastTree, "sess-s1")
    check("icons: session row for brave exists", sessRow ~= nil)
    check("icons: session row includes smaller icon node (16px)", sessRow ~= nil and hasImageIn(sessRow, "/icons/brave-browser@16.png"))

    local kittyTop = findKey(lastTree, "app-2-kitty")
    check("icons: top-app without icon keeps its row (no image)", kittyTop ~= nil and not hasImageIn(kittyTop, "/icons/kitty@24.png"))
    local kittySess = findKey(lastTree, "sess-s2")
    check("icons: session without icon keeps its row (no image)", kittySess ~= nil and not hasImageIn(kittySess, "/icons/kitty@16.png"))

    local nameBtn = findButton(lastTree, "app-name-1-brave-browser")
    check("icons: top-app App ID tooltip preserved",
      nameBtn ~= nil and type(nameBtn.p.tooltip) == "string" and nameBtn.p.tooltip:find("brave-browser", 1, true) ~= nil)
    local sessBtn = findButton(lastTree, "sess-name-s1")
    check("icons: session App ID tooltip preserved",
      sessBtn ~= nil and type(sessBtn.p.tooltip) == "string" and sessBtn.p.tooltip:find("brave-browser", 1, true) ~= nil)

    -- Re-renders must not re-consult the host: the helper caches per id+size.
    -- Base counts are captured AFTER the first render above (which resolved
    -- through the host once); further renders must not grow them.
    local base24 = iconCounts["brave-browser@24"] or 0
    local base16 = iconCounts["brave-browser@16"] or 0
    check("icons: first render resolved through the host", base24 >= 1 and base16 >= 1)
    env.render()
    env.render()
    check("icons: host consulted once per id+size across re-renders",
      iconCounts["brave-browser@24"] == base24 and iconCounts["brave-browser@16"] == base16)
    cleanup()
  end

  -- Panel: unavailable + history -> banner AND history rows together; the
  -- user must never read the banner as data loss.
  do
    local store = {
      wdid_state = { schema = 1, provider = "none", trackingAvailable = false, tracking = true, paused = false, currentAppName = "", todayTotal = 1980, todayApps = 1, todayTopApps = {} },
      wdid_sessions = { sessions = sessions, rev = 1 },
    }
    local env = loadPanel(store)
    env.render()
    check("panel: unavailable subtitle shown", hasLabelText(lastTree, "Activity tracking is unavailable for this compositor."))
    check("panel: unavailable day banner shown", hasLabelText(lastTree, "Your existing history is still available."))
    check("panel: history stays visible while unavailable", hasLabelText(lastTree, "33m"))
    check("panel: unavailable is distinct from the idle state", not hasLabelText(lastTree, "No application focused"))
    cleanup()
  end

  -- Panel: unavailable + empty history -> compact empty state, no crash.
  do
    local store = {
      wdid_state = { schema = 1, provider = "none", trackingAvailable = false, tracking = true, paused = false, currentAppName = "", todayTotal = 0, todayApps = 0, todayTopApps = {} },
      wdid_sessions = { sessions = {}, rev = 1 },
    }
    local env = loadPanel(store)
    env.render()
    check("panel: unavailable without history shows empty state", hasLabelText(lastTree, "No activity recorded yet"))
    check("panel: unavailable banner present without history too", hasLabelText(lastTree, "Your existing history is still available."))
    cleanup()
  end
end

-- ── desktop widget icons ──────────────────────────────────────────────────

-- The desktop widget consumes the service's shared state only; its top-app
-- rows must embed the same cached, technical-id-keyed icon as the panel,
-- with iconless apps keeping their row untouched.
do
  local nowKey = timeutil.dateKeyOf(os.time(), 0)
  local store = {
    wdid_state = {
      schema = 1,
      tracking = true,
      paused = false,
      todayTotal = 2580,
      todayApps = 2,
      todayTopApps = {
        { appId = "brave-browser", appName = "Brave", seconds = 1980 },
        { appId = "kitty", appName = "Kitty", seconds = 600 },
      },
    },
  }
  local seen = {}
  _G.WDID_TEST_NOCTALIA = function()
    return {
      log = function() end,
      nowMs = function() return os.time() * 1000 end,
      tr = function(key) return key end,
      trp = function(key) return key end,
      setUpdateInterval = function() end,
      state = {
        get = function(k) return store[k] end,
        set = function() end,
        watch = function() end,
      },
      readFile = function() return nil end,
      listDir = function() return nil end,
      getenv = function() return nil end,
      appIconPath = function(id, size)
        seen[tostring(id) .. "@" .. tostring(size)] = true
        if id == "brave-browser" then
          return "/icons/brave@24.png"
        end
        return nil
      end,
    }
  end
  local function makeNode(kind, props, kids)
    return { kind = kind, p = props or {}, kids = kids or {} }
  end
  _G.ui = setmetatable({}, {
    __index = function(_, kind)
      return function(props, kids)
        return makeNode(kind, props, kids)
      end
    end,
  })
  local lastWidgetTree
  _G.desktopWidget = { render = function(tree) lastWidgetTree = tree end }
  local _, env = prelude.loadModule(base, "desktop_widget.luau")
  env.update()

  local function findKey(tree, key)
    if tree.p and tree.p.key == key then return tree end
    for _, k in ipairs(tree.kids or {}) do
      local hit = findKey(k, key)
      if hit then return hit end
    end
    return nil
  end
  local function hasImageIn(node, path)
    if node.kind == "image" and node.p.path == path then return true end
    for _, k in ipairs(node.kids or {}) do
      if hasImageIn(k, path) then return true end
    end
    return false
  end

  local braveRow = findKey(lastWidgetTree, "dw-app-1-brave-browser")
  check("desktop widget: brave top-app row exists", braveRow ~= nil)
  check("desktop widget: brave row includes icon node (24px lookup)", braveRow ~= nil and hasImageIn(braveRow, "/icons/brave@24.png"))
  check("desktop widget: icon resolved from the technical app id", seen["brave-browser@24"] == true)

  local kittyRow = findKey(lastWidgetTree, "dw-app-2-kitty")
  check("desktop widget: app without icon keeps its row (no image)", kittyRow ~= nil and not hasImageIn(kittyRow, "/icons/kitty@24.png"))

  local nameBtn = findKey(lastWidgetTree, "dw-app-name-1-brave-browser")
  check("desktop widget: App ID tooltip preserved",
    nameBtn ~= nil and type(nameBtn.p.tooltip) == "string" and nameBtn.p.tooltip:find("brave-browser", 1, true) ~= nil)

  _G.ui = nil
  _G.desktopWidget = nil
  _G.WDID_TEST_NOCTALIA = nil
end

-- ── launcher icons ────────────────────────────────────────────────────────

-- App rows must use the dedicated LauncherResult.icon field (a path for
-- ui.image), keep the technical id in badge, the human name as title, and
-- the glyph as the host-side fallback when no icon resolves.
do
  local nowKey = timeutil.dateKeyOf(os.time(), 0)
  local store = {
    wdid_state = { schema = 1, tracking = true, paused = false, currentAppName = "" },
    wdid_sessions = {
      rev = 1,
      sessions = {
        { id = "l1", dateKey = nowKey, appId = "brave-browser", appName = "Brave", startedAtMs = (os.time() - 2000) * 1000, durationSeconds = 1980 },
        { id = "l2", dateKey = nowKey, appId = "kitty", appName = "Kitty", startedAtMs = (os.time() - 900) * 1000, durationSeconds = 600 },
      },
    },
  }
  local seen = {}
  _G.WDID_TEST_NOCTALIA = function()
    return {
      log = function() end,
      nowMs = function() return os.time() * 1000 end,
      tr = function(key) return key end,
      trp = function(key) return key end,
      state = {
        get = function(k) return store[k] end,
        set = function() end,
        watch = function() end,
      },
      readFile = function() return nil end,
      listDir = function() return nil end,
      getenv = function() return nil end,
      string = { trim = function(s) return s end },
      appIconPath = function(id, size)
        seen[tostring(id) .. "@" .. tostring(size)] = true
        if id == "brave-browser" then
          return "/icons/brave@32.png"
        end
        return nil
      end,
    }
  end
  local _, lenv = prelude.loadModule(base, "launcher.luau")

  local rows = lenv.drillRows("today")
  local braveRow, kittyRow
  for _, row in ipairs(rows) do
    if row.badge == "brave-browser" then
      braveRow = row
    elseif row.badge == "kitty" then
      kittyRow = row
    end
  end

  check("launcher: brave app row present in today drill", braveRow ~= nil)
  check("launcher: icon uses the dedicated icon field", braveRow ~= nil and braveRow.icon == "/icons/brave@32.png")
  check("launcher: title stays the human-readable name", braveRow ~= nil and braveRow.title == "Brave")
  check("launcher: badge keeps the technical app id", braveRow ~= nil and braveRow.badge == "brave-browser")
  check("launcher: icon resolved from the technical app id", seen["brave-browser@32"] == true)

  check("launcher: iconless app keeps its row", kittyRow ~= nil)
  check("launcher: iconless app has no icon and keeps its glyph", kittyRow ~= nil and kittyRow.icon == nil and kittyRow.glyph == "app-window")

  _G.WDID_TEST_NOCTALIA = nil
end

-- ── provider selection & fallback (phase 1 portability) ──────────────────

-- Detection + selection must be evidence-based: environment variable first,
-- then the provider's required executable. Every path yields a usable
-- provider — the fallback never spawns anything and never fabricates data.
do
  section("capability")
  local capability = prelude.loadModule(base, "providers/capability.luau")

  -- detect(): environment variables per compositor.
  check("capability: hyprland env + hyprctl detected as hyprland",
    capability.detect(function(n) return n == "HYPRLAND_INSTANCE_SIGNATURE" and "sess" or nil end,
      function(n) return n == "hyprctl" end) == "hyprland")
  check("capability: hyprland env WITHOUT hyprctl degrades to none",
    capability.detect(function(n) return n == "HYPRLAND_INSTANCE_SIGNATURE" and "sess" or nil end,
      function() return false end) == "none")
  check("capability: niri env detected",
    capability.detect(function(n) return n == "NIRI_SOCKET" and "/sock" or nil end,
      function() return false end) == "niri")
  check("capability: sway env detected",
    capability.detect(function(n) return n == "SWAYSOCK" and "/sock" or nil end,
      function() return false end) == "sway")
  check("capability: no signals -> none",
    capability.detect(function() return nil end, function() return false end) == "none")

  -- fallback provider: interface-compatible, zero side effects, honest nils.
  local fallback = capability.newFallbackProvider({})
  check("capability: fallback reports unavailable", fallback.name == "none" and fallback.available == false)
  local sawApp, sawNil = "unset", false
  fallback.activeWindow(function(app)
    sawApp = "called"
    sawNil = app == nil
  end)
  check("capability: fallback activeWindow reports no application", sawApp == "called" and sawNil)
  fallback.start(function() end)
  fallback.stop()
  check("capability: fallback start/stop are side-effect free", fallback.available == false)

  -- selector: known provider wins; every other path lands on the fallback.
  local fake = { name = "fake-hypr", available = true, activeWindow = function() end }
  local sel = capability.newSelector({
    getenv = function(n) return n == "HYPRLAND_INSTANCE_SIGNATURE" and "sess" or nil end,
    commandExists = function(n) return n == "hyprctl" end,
    resolve = function(name)
      if name == "hyprland" then return fake end
      return nil
    end,
    log = function() end,
  })
  local picked, detected = sel.select({})
  check("capability: selection picks the hyprland provider when resolvable", picked == fake and detected == "hyprland")

  local selNoProvider = capability.newSelector({
    getenv = function(n) return n == "HYPRLAND_INSTANCE_SIGNATURE" and "sess" or nil end,
    commandExists = function() return true end,
    resolve = function() return nil end,
    log = function() end,
  })
  local fallbackPick, detectedNone = selNoProvider.select({})
  check("capability: unresolvable provider falls back (no crash)",
    fallbackPick.name == "none" and fallbackPick.available == false and detectedNone == "hyprland")

  local selNiri = capability.newSelector({
    getenv = function(n) return n == "NIRI_SOCKET" and "/sock" or nil end,
    commandExists = function() return true end,
    resolve = function() return nil end,
    log = function() end,
  })
  local niriPick, detectedNiri = selNiri.select({})
  check("capability: recognized-but-unimplemented compositor degrades (phase 1)",
    niriPick.name == "none" and detectedNiri == "niri")
end

-- Service-level integration: provider selection flows into the published
-- shared state, and the stored history stays accessible when tracking is
-- unavailable. Runs the REAL service.luau against a stub host backed by an
-- in-memory filesystem (so storage loads the pre-seeded history). Note:
-- phase 1 does NOT claim niri/sway tracking — niri/sway select the fallback.
do
  local nowKey = timeutil.dateKeyOf(os.time(), 0)
  local seedSessions = {
    { id = "hist-1", dateKey = nowKey, appId = "brave-browser", appName = "Brave", startedAtMs = (os.time() - 2000) * 1000, durationSeconds = 1980 },
  }
  local function runService(envVars, tools, storedSessions)
    local fs = {}
    local function encodePayload(sessions)
      return '{"version":1,"sessions":['
        .. '{"id":"' .. sessions[1].id .. '","dateKey":"' .. sessions[1].dateKey
        .. '","appId":"' .. sessions[1].appId .. '","appName":"' .. sessions[1].appName
        .. '","startedAtMs":' .. sessions[1].startedAtMs
        .. ',"durationSeconds":' .. sessions[1].durationSeconds .. "}]}",
        nil
    end
    if storedSessions then
      fs["/data/activity/history.json"] = encodePayload(storedSessions)
    end
    local store = {}
    _G.WDID_TEST_NOCTALIA = function()
      return {
        log = function() end,
        nowMs = function() return os.time() * 1000 end,
        getenv = function(n) return envVars[n] end,
        commandExists = function(n) return tools[n] == true end,
        runAsync = function() return false end,
        runStream = function() return false end,
        tr = function(key) return key end,
        notify = function() end,
        getConfig = function() return nil end,
        pluginDataDir = function() return "/data" end,
        mkdirAll = function() return true end,
        fileExists = function(p) return fs[p] ~= nil end,
        readFile = function(p) return fs[p], nil end,
        writeFile = function(p, c) fs[p] = c return true end,
        renameFile = function(a, b) fs[b] = fs[a] fs[a] = nil return true end,
        removeFile = function(p) fs[p] = nil return true end,
        listDir = function()
          local out = {}
          for k in pairs(fs) do
            out[#out + 1] = k
          end
          return out
        end,
        state = {
          get = function(k) return store[k] end,
          set = function(k, v) store[k] = v end,
          watch = function() end,
        },
      }
    end
    prelude.loadModule(base, "service.luau")
    _G.WDID_TEST_NOCTALIA = nil
    return store
  end

  -- Hyprland session with hyprctl: full tracking available.
  local hyprStore = runService({ HYPRLAND_INSTANCE_SIGNATURE = "sess" }, { hyprctl = true }, seedSessions)
  check("service: hyprland publishes trackingAvailable",
    hyprStore.wdid_state ~= nil and hyprStore.wdid_state.trackingAvailable == true and hyprStore.wdid_state.provider == "hyprland")

  -- Hyprland session WITHOUT hyprctl: honest degradation, not pretend tracking.
  local noCtlStore = runService({ HYPRLAND_INSTANCE_SIGNATURE = "sess" }, {}, seedSessions)
  check("service: missing required executable degrades to unavailable",
    noCtlStore.wdid_state.trackingAvailable == false and noCtlStore.wdid_state.provider == "none")
  check("service: degraded state keeps history totals",
    noCtlStore.wdid_state.todayTotal ~= nil and noCtlStore.wdid_state.todayTotal > 0)

  -- Niri session: recognized, but phase 1 ships no niri provider (fallback).
  local niriStore = runService({ NIRI_SOCKET = "/sock" }, { hyprctl = true }, seedSessions)
  check("service: niri session marks tracking unavailable (no niri provider yet)",
    niriStore.wdid_state.trackingAvailable == false and niriStore.wdid_state.provider == "niri")
  check("service: niri session keeps history accessible",
    niriStore.wdid_sessions ~= nil and type(niriStore.wdid_sessions.sessions) == "table" and #niriStore.wdid_sessions.sessions == 1)

  -- No compositor at all: fallback, no fabricated data, no sessions invented.
  local noneStore = runService({}, { hyprctl = true }, seedSessions)
  check("service: no compositor -> fallback provider",
    noneStore.wdid_state.trackingAvailable == false and noneStore.wdid_state.provider == "none")
  check("service: fallback fabricates no current application",
    noneStore.wdid_state.currentApp == nil and noneStore.wdid_state.currentAppName == "")
end

-- Panel / desktop widget / bar / launcher: honest unavailable state (states
-- must stay distinct: waiting-for-tracker, idle, unavailable, focused).
do
  local nowKey = timeutil.dateKeyOf(os.time(), 0)
  local histSessions = {
    { id = "u1", dateKey = nowKey, appId = "brave-browser", appName = "Brave", startedAtMs = (os.time() - 2000) * 1000, durationSeconds = 1980 },
  }
  local unavailableState = { schema = 1, provider = "none", trackingAvailable = false, tracking = true, paused = false, currentAppName = "", todayTotal = 1980, todayApps = 1, todayTopApps = {} }

  -- Real translation strings (same approach as the panel harness) so the
  -- assertions below match what users actually see, durations included.
  local trStrings = {}
  do
    local fh = io.open(base .. "/translations/en.json", "r")
    local okJ, enjson = json.decode(fh:read("*a"))
    fh:close()
    local function flatten(prefix, tbl)
      for k, v in pairs(tbl) do
        if type(v) == "table" then
          flatten(prefix .. k .. ".", v)
        else
          trStrings[prefix .. k] = v
        end
      end
    end
    flatten("", enjson)
  end
  local function trStub(key, a, b)
    local out = trStrings[key] or key
    local subst = type(a) == "table" and a or b
    if type(subst) == "table" then
      for k, v in pairs(subst) do
        out = out:gsub("{" .. k .. "}", tostring(v))
      end
    end
    return out
  end

  -- Desktop widget: unavailable -> keeps the historical total, never
  -- extrapolates a live open session, shows the unavailable label.
  do
    local store = {
      wdid_state = {
        schema = 1, tracking = true, paused = false,
        trackingAvailable = false, provider = "none",
        todayTotal = 1980, todayApps = 1,
        currentAppSinceMs = (os.time() - 500) * 1000, -- would inflate if misused
        todayTopApps = {},
      },
    }
    _G.WDID_TEST_NOCTALIA = function()
      return {
        log = function() end,
        nowMs = function() return os.time() * 1000 end,
        tr = trStub,
        trp = trStub,
        setUpdateInterval = function() end,
        state = {
          get = function(k) return store[k] end,
          set = function() end,
          watch = function() end,
        },
        readFile = function() return nil end,
        listDir = function() return nil end,
        getenv = function() return nil end,
        appIconPath = function() return nil end,
      }
    end
    local function makeNode(kind, props, kids)
      return { kind = kind, p = props or {}, kids = kids or {} }
    end
    _G.ui = setmetatable({}, {
      __index = function(_, kind)
        return function(props, kids)
          return makeNode(kind, props, kids)
        end
      end,
    })
    local lastTreeDw
    _G.desktopWidget = { render = function(tree) lastTreeDw = tree end }
    local _, denv = prelude.loadModule(base, "desktop_widget.luau")
    denv.update()
    local function hasLabelTextDw(want)
      local function walk(n)
        if n.kind == "label" and n.p.text == want then return true end
        for _, k in ipairs(n.kids or {}) do
          if walk(k) then return true end
        end
        return false
      end
      return walk(lastTreeDw)
    end
    check("desktop widget: unavailable label shown", hasLabelTextDw("Activity tracking is unavailable for this compositor."))
    check("desktop widget: historical total kept without live extrapolation", hasLabelTextDw("33m"))
    _G.ui = nil
    _G.desktopWidget = nil
    _G.WDID_TEST_NOCTALIA = nil
  end

  -- Bar widget: unavailable -> plug-off glyph, muted, tooltip explains; no
  -- live timer extrapolation.
  do
    local store = {
      wdid_state = {
        schema = 1, tracking = true, paused = false,
        trackingAvailable = false, provider = "none",
        todayTotal = 1980, todayApps = 1,
        currentAppSinceMs = (os.time() - 500) * 1000,
      },
    }
    _G.WDID_TEST_NOCTALIA = function()
      return {
        log = function() end,
        nowMs = function() return os.time() * 1000 end,
        tr = trStub,
        trp = trStub,
        setUpdateInterval = function() end,
        getConfig = function(key)
          if key == "glyph" then return "clock-hour-4" end
          return nil
        end,
        state = {
          get = function(k) return store[k] end,
          set = function() end,
          watch = function() end,
        },
      }
    end
    local function makeNode(kind, props, kids)
      return { kind = kind, p = props or {}, kids = kids or {} }
    end
    _G.ui = setmetatable({}, {
      __index = function(_, kind)
        return function(props, kids)
          return makeNode(kind, props, kids)
        end
      end,
    })
    local barTree, barTooltip
    _G.barWidget = {
      setVisible = function() end,
      isVertical = function() return false end,
      render = function(tree) barTree = tree end,
      setTooltip = function(t) barTooltip = t end,
    }
    local _, wenv = prelude.loadModule(base, "widget.luau")
    wenv.update()
    local glyphNode = barTree and barTree.kids and barTree.kids[1]
    check("bar: unavailable shows the plug-off glyph", glyphNode ~= nil and glyphNode.kind == "glyph" and glyphNode.p.name == "plug-off")
    check("bar: unavailable tooltip explains instead of pretending",
      type(barTooltip) == "string" and barTooltip:find("Activity tracking is unavailable for this compositor.", 1, true) ~= nil)
    check("bar: unavailable total stays historical (no fake ticking)",
      barTree ~= nil and barTree.kids[2] ~= nil and barTree.kids[2].p.text == "33m")
    _G.ui = nil
    _G.barWidget = nil
    _G.WDID_TEST_NOCTALIA = nil
  end

  -- Launcher: unavailable -> toggle replaced by an honest status row; the
  -- history drill keeps working and still lists applications.
  do
    local store = {
      wdid_state = unavailableState,
      wdid_sessions = { sessions = histSessions, rev = 1 },
    }
    _G.WDID_TEST_NOCTALIA = function()
      return {
        log = function() end,
        nowMs = function() return os.time() * 1000 end,
        tr = trStub,
        trp = trStub,
        state = {
          get = function(k) return store[k] end,
          set = function() end,
          watch = function() end,
        },
        readFile = function() return nil end,
        listDir = function() return nil end,
        getenv = function() return nil end,
        appIconPath = function(id, size) return "/icons/" .. id .. "@" .. size .. ".png" end,
        string = { trim = function(s) return s end },
      }
    end
    local _, lenv = prelude.loadModule(base, "launcher.luau")
    local results = {}
    _G.launcher = { setResults = function(_q, rows) results = rows end, setQuery = function() end }
    lenv.onQuery("")
    local hasUnavailable, hasToggle
    for _, row in ipairs(results) do
      if row.title == "Activity tracking is unavailable for this compositor." then
        hasUnavailable = row.id == "" -- action-less: nothing broken to activate
      elseif row.id == "act:toggle" then
        hasToggle = true
      end
    end
    check("launcher: unavailable replaces the live toggle with an honest row", hasUnavailable == true and hasToggle == nil)

    local drill = lenv.drillRows("today")
    local braveRow
    for _, row in ipairs(drill) do
      if row.badge == "brave-browser" then
        braveRow = row
      end
    end
    check("launcher: history drill still works while unavailable", braveRow ~= nil and braveRow.icon == "/icons/brave-browser@32.png")
    _G.launcher = nil
    _G.WDID_TEST_NOCTALIA = nil
  end
end

-- ── summary ──────────────────────────────────────────────────────────────────

print(string.format("\n%d checks, %d failures", count, failures))
if failures > 0 then
  os.exit(1)
end
