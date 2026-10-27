--!nonstrict
-- Claude Operator service: the only entry that reads Claude Code's files or the network.
-- The widget, panel and launcher render what it publishes (shapes in docs/DESIGN.md).
--
-- Every account is a Claude config dir (~/.claude, or whatever CLAUDE_CONFIG_DIR points
-- at). Claude Code writes <dir>/sessions/<pid>.json per running session (status
-- busy|idle|waiting, waitingFor, bridgeSessionId while Remote Control is on). Those are
-- read here every 2 s without spawning anything; everything heavier runs as a script
-- only when its input changed or its interval came round.
--
-- Account discovery, notifications, limits and Remote Control are derived from
-- claude-sessions (lfdominguez, MIT); the pid-reuse check from claude-cockpit
-- (nightwatch75, MIT).
--
-- Force a refresh: noctalia msg plugin edward/claude-operator:service all refresh

local shared = require("./shared.luau")
local PLUGIN = noctalia.pluginDir()
local SCRIPTS = PLUGIN .. "/scripts"
local HOME = noctalia.getenv("HOME") or ""
local DEFAULT_DIR = HOME .. "/.claude"
local DATA = noctalia.pluginDataDir()
local PRICING = DATA .. "/pricing.json"
local SAVED_ACCOUNTS = DATA .. "/accounts.json"
local SAVED_LIMITS = DATA .. "/limits.json"
local PINS = DATA .. "/pins.json"
local INDEX_MS = 5 * 60000 -- the saved-session index; also rebuilt when a session ends

local TICK_MS = 2000
local SLOW_MS = 60000 -- account discovery, Recent, Remote Control
local RANK = { waiting = 0, busy = 1, idle = 2 }
local HOUR_MS, DAY_MS = 3600000, 86400000

local accounts = {} -- dir -> { dir, label, email, limits, limitsAt, limitsPending, limitsErr, remote = { list, at, pending, err } }
local details = {} -- pid -> { key, data, pending }
local terminals = {} -- pid -> terminal name; a process's environment never changes
local tracked = {} -- pid -> { status, busySince }
local current = {} -- the published, sorted live sessions
local localBridges = {} -- claude.ai/code ids of Remote Control sessions running here
local remoteSeen = {} -- remote id -> last status category, for notifications
local lastSlow = -math.huge
local recentPending, usagePending, pricingPending = false, false, false
local usageAt = -math.huge
local indexPending, indexAt = false, -math.huge

local function cfg(key, fallback)
  local v = noctalia.getConfig(key)
  if v == nil then return fallback end
  return v
end

local function minutes(key, fallback) return (tonumber(cfg(key, fallback)) or fallback) * 60000 end

local function decode(text)
  local v = noctalia.json.decode(text or "")
  return type(v) == "table" and v or nil
end

-- Runs a script with argv, decodes its JSON stdout and hands it to done(value, result);
-- value is nil on a failed run or bad JSON. Returns false when the process did not start.
local function runJson(argv, timeoutMs, done)
  return noctalia.runAsync(argv, function(r)
    done(r.exitCode == 0 and decode(r.stdout) or nil, r)
  end, timeoutMs)
end

-- Publishes only real changes: the tick runs every 2 s, and every state.set wakes the
-- widget, panel and launcher to re-render.
local published = {}
local function publish(key, value)
  local encoded = noctalia.json.encode(value) or ""
  if published[key] == encoded then return end
  published[key] = encoded
  noctalia.state.set(key, value)
end

local function script(name, ...)
  local argv = { "bash", SCRIPTS .. "/" .. name }
  for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
  return argv
end

-- "2026-10-01T20:29:59.766+00:00" -> epoch ms, honouring the offset.
local function isoToMs(iso)
  local y, mo, d, h, mi, sec, sign, oh, om = string.match(iso or "",
    "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)[%.%d]*([%+%-]?)(%d*):?(%d*)")
  if not y then return nil end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  -- days since epoch (Howard Hinnant's days_from_civil)
  if mo <= 2 then y -= 1 end
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * ((mo + 9) % 12) + 2) // 5 + d - 1
  local days = era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
  local secs = days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
  if sign ~= "" and oh ~= "" then
    local off = tonumber(oh) * 3600 + (tonumber(om) or 0) * 60
    secs = sign == "+" and secs - off or secs + off
  end
  return secs * 1000
end

-- ── Accounts ────────────────────────────────────────────────────────────────

local function normDir(dir)
  if type(dir) ~= "string" or dir == "" then return nil end
  return (string.gsub(noctalia.expandPath(dir), "/+$", ""))
end

-- "~/.claude" -> "default", "~/.claude-work" -> "work".
local function labelFor(dir)
  if dir == DEFAULT_DIR then return "default" end
  local base = string.match(dir, "([^/]+)$") or dir
  local name = string.gsub(string.gsub(base, "^%.", ""), "^claude[%-_%.]?", "")
  return name ~= "" and name or base
end

-- Account metadata lives in .claude.json: inside the config dir, or beside ~/.claude for
-- the default one. It grows to hundreds of KB, so it is decoded only when it changed.
local function refreshEmail(a)
  local file = a.dir == DEFAULT_DIR and HOME .. "/.claude.json" or a.dir .. "/.claude.json"
  local info = noctalia.fileInfo(file)
  local stamp = info and `{info.size}:{info.mtime}` or nil
  if stamp == a.infoStamp then return end
  a.infoStamp = stamp
  local meta = decode(noctalia.readFile(file))
  a.email = meta and type(meta.oauthAccount) == "table" and meta.oauthAccount.emailAddress or nil
end

local savedLimits = decode(noctalia.readFile(SAVED_LIMITS)) or {}

local function addAccount(dir)
  dir = normDir(dir)
  if not dir or accounts[dir] or not noctalia.fileExists(dir) then return false end
  local saved = savedLimits[dir]
  if type(saved) == "table" then saved.stale = true end
  accounts[dir] = {
    dir = dir, label = labelFor(dir),
    -- Last known limits survive a restart; marked stale until the next fetch lands.
    limits = type(saved) == "table" and saved or nil,
    limitsAt = -math.huge,
    remote = { list = {}, at = -math.huge },
  }
  refreshEmail(accounts[dir])
  return true
end

-- Non-default accounts are remembered so their Recent sessions survive a restart.
local function saveAccounts()
  local dirs = {}
  for dir in pairs(accounts) do if dir ~= DEFAULT_DIR then dirs[#dirs + 1] = dir end end
  table.sort(dirs)
  noctalia.writeFile(SAVED_ACCOUNTS, noctalia.json.encode(dirs))
end

-- Known accounts: ~/.claude, dirs seen before, and (async, via running.sh) the config
-- dirs of running claude processes, including bind mounts over ~/.claude.
local function discoverAccounts()
  local added = addAccount(DEFAULT_DIR)
  for _, d in ipairs(decode(noctalia.readFile(SAVED_ACCOUNTS)) or {}) do added = addAccount(d) or added end
  for dir, a in pairs(accounts) do
    if noctalia.fileExists(dir) then refreshEmail(a) else accounts[dir] = nil; added = true end
  end
  if added then saveAccounts() end
  noctalia.runAsync(script("running.sh"), function(r)
    local found = false
    for line in string.gmatch(r.stdout or "", "[^\n]+") do found = addAccount(line) or found end
    if found then saveAccounts() end
  end, 10000)
end

-- Default first, then by label.
local function accountList()
  local list = {}
  for _, a in pairs(accounts) do list[#list + 1] = a end
  table.sort(list, function(x, y)
    if (x.dir == DEFAULT_DIR) ~= (y.dir == DEFAULT_DIR) then return x.dir == DEFAULT_DIR end
    return x.label < y.label
  end)
  return list
end

local function publishAccounts()
  local out = {}
  for _, a in ipairs(accountList()) do
    out[#out + 1] = { dir = a.dir, label = a.label, email = a.email, default = a.dir == DEFAULT_DIR, limits = a.limits }
  end
  publish("accounts", out)
end

-- ── Plan limits ─────────────────────────────────────────────────────────────

local WINDOW_MS = { session = 5 * HOUR_MS }

local function windowLabel(w)
  if w.kind == "session" then return "5h" end
  if w.kind == "weekly_all" then return "7d" end
  return (w.model or w.kind or "?") .. (w.group == "weekly" and " 7d" or "")
end

-- Usage samples per window, so the UI can project from the recent burn rate rather than
-- the window's average: the 5-hour window is mostly about the last half hour. A sample
-- is added on every successful fetch; a new resetsAt means a new window, which starts
-- an empty list. Lookback per window kind, and the shortest span a rate is trusted from.
local LOOKBACK = { session = HOUR_MS, weekly = DAY_MS }
local MIN_SPAN = { session = 30 * 60000, weekly = 3 * HOUR_MS }
-- Samples cover the whole window, for the Usage tab's forecast graph; weekly ones are
-- thinned to one per half hour (the newest wins), at most ~340 per window.
local THIN = { session = 0, weekly = 30 * 60000 }

-- The API's resets_at wobbles between fetches, so "same window" allows ten minutes.
local function sameWindow(prev, w)
  return prev ~= nil and prev.resetsAt ~= nil and w.resetsAt ~= nil and math.abs(prev.resetsAt - w.resetsAt) < 10 * 60000
end

local function addSample(w, prev, now)
  local kind = w.kind == "session" and "session" or "weekly"
  local same = sameWindow(prev, w)
  local start = (w.resetsAt or now) - (w.durationMs or 7 * DAY_MS)
  local samples = {}
  for _, smp in ipairs(same and type(prev.samples) == "table" and prev.samples or {}) do
    if smp[1] >= start then samples[#samples + 1] = smp end
  end
  local last = samples[#samples]
  if last and now - last[1] < THIN[kind] then samples[#samples] = nil end
  samples[#samples + 1] = { now, w.percent }
  w.samples = samples
  -- Recent rate: from the oldest sample inside the lookback to now.
  local first
  for _, smp in ipairs(samples) do
    if now - smp[1] <= LOOKBACK[kind] then first = smp break end
  end
  local span = first and now - first[1] or 0
  if span >= MIN_SPAN[kind] then
    w.rate = math.max(0, (w.percent - first[2]) / (span / HOUR_MS)) -- percent per hour
    w.rateSpanMs = span
  end
end

local function shapeLimits(raw, previous)
  local now = noctalia.nowMs()
  local prevById = {}
  for _, w in ipairs(previous and previous.windows or {}) do prevById[w.id] = w end
  local windows = {}
  for _, w in ipairs(type(raw.windows) == "table" and raw.windows or {}) do
    if type(w) == "table" and tonumber(w.percent) then
      local shaped = {
        id = `{w.kind or "window"}:{w.model or ""}`, label = windowLabel(w),
        kind = w.kind, group = w.group, model = w.model,
        percent = tonumber(w.percent), resetsAt = isoToMs(w.resets_at),
        durationMs = WINDOW_MS[w.kind] or 7 * DAY_MS, severity = w.severity,
      }
      local prev = prevById[shaped.id]
      addSample(shaped, prev, now)
      -- Saved with the limits, so a restart never repeats a window's notice.
      if sameWindow(prev, shaped) then
        shaped.warned = prev.warned
        shaped.rose = shaped.percent > (tonumber(prev.percent) or 0)
      end
      windows[#windows + 1] = shaped
    end
  end
  return { updated = now, stale = false, subscription = raw.subscription, tier = raw.tier, windows = windows }
end

-- One notice per window when the current rate reaches the limit within the hour (5-hour
-- window) or the day (weekly ones), and only while usage is still rising: a weekly
-- average can say "soon" for days after the last session.
local function warnLimits(a)
  if not cfg("notify_limits", true) then return end
  for _, w in ipairs(a.limits.windows) do
    local p = shared.pace(w)
    if p.status == "soon" and w.rose and not w.warned then
      w.warned = true
      local headline = shared.paceText(w, p)
      noctalia.notify(`Claude: {w.label} limit soon`, `{headline}. {w.label} is at {shared.round(w.percent)}%.`)
    end
  end
end

local function saveLimits()
  local out = {}
  for dir, a in pairs(accounts) do if a.limits then out[dir] = a.limits end end
  noctalia.writeFile(SAVED_LIMITS, noctalia.json.encode(out))
end

-- An expired token (Claude Code refreshes it on its next start) keeps the last limits,
-- marked stale with the reason; the reason is logged once per change, not every fetch.
-- api/oauth/usage is rate limited, and Claude Code's statusline and other tools may use
-- the same token. On a 429 the next try waits for the server's Retry-After, or a backoff
-- from 10 minutes doubling to an hour; a success resets it.
local BACKOFF_MS, BACKOFF_MAX_MS = 10 * 60000, HOUR_MS
-- Manual refreshes and settings changes never fetch sooner than this after the last try.
local MIN_GAP_MS = 2 * 60000

local function fetchLimits(a)
  if a.limitsPending or noctalia.nowMs() < (a.limitsHold or 0) then return end
  a.limitsPending, a.limitsAt = true, noctalia.nowMs()
  local started = runJson(script("limits.sh", a.dir), 20000, function(raw, r)
    a.limitsPending = false
    local err = nil
    if raw then
      a.limits = shapeLimits(raw, a.limits)
      warnLimits(a)
      saveLimits()
      a.limitsBackoff, a.limitsHold = nil, nil
    elseif r.exitCode == 4 then
      local wait = (tonumber(noctalia.string.trim(r.stdout or "")) or 0) * 1000
      a.limitsBackoff = math.min(BACKOFF_MAX_MS, a.limitsBackoff and a.limitsBackoff * 2 or BACKOFF_MS)
      a.limitsHold = noctalia.nowMs() + math.max(wait, a.limitsBackoff)
      err = `rate limited by Anthropic, next try {os.date("%H:%M", a.limitsHold // 1000)}`
      if a.limits then a.limits.stale, a.limits.error = true, err end
    else
      err = noctalia.string.trim(r.stderr or "")
      if err == "" then err = r.timedOut and "timed out" or `exit {r.exitCode}` end
      if a.limits then a.limits.stale, a.limits.error = true, err end
    end
    if err ~= a.limitsErr and err then noctalia.log(`claude-operator: limits ({a.label}): {err}`) end
    a.limitsErr = err
    publishAccounts()
  end)
  if not started then a.limitsPending = false end
end

-- ── Pricing and usage history ───────────────────────────────────────────────

local function publishPricing()
  local p = decode(noctalia.readFile(PRICING))
  publish("pricing", p and { updated = p.updated, rates = p.rates } or nil)
end

-- Once a day (the file records the date it was fetched); callback runs either way.
local function refreshPricing(done)
  local p = decode(noctalia.readFile(PRICING))
  if (p and p.updated == os.date("%Y-%m-%d")) or pricingPending then done() return end
  pricingPending = true
  local url = noctalia.string.trim(tostring(cfg("currency_api_url", "")))
  if url == "" then url = "https://api.frankfurter.dev/v1/latest" end
  local started = noctalia.runAsync(script("pricing.sh", PRICING, url), function(r)
    pricingPending = false
    for _, d in pairs(details) do d.key = nil end
    if r.exitCode ~= 0 then noctalia.log("claude-operator: pricing refresh failed: " .. noctalia.string.trim(r.stderr or "")) end
    publishPricing()
    done()
  end, 40000)
  if not started then pricingPending = false; done() end
end

local function refreshUsage()
  if usagePending then return end
  usagePending, usageAt = true, noctalia.nowMs()
  refreshPricing(function()
    local argv = script("usage-stats.sh", PRICING, DATA .. "/usage")
    for _, a in ipairs(accountList()) do argv[#argv + 1] = a.dir end
    local started = runJson(argv, 60000, function(usage, r)
      usagePending = false
      if usage then
        usage.updated = noctalia.nowMs()
        publish("usage", usage)
      else
        noctalia.log("claude-operator: usage stats failed: " .. noctalia.string.trim(r.stderr or ""))
      end
    end)
    if not started then usagePending = false end
  end)
end

-- ── Remote Control sessions elsewhere ───────────────────────────────────────

-- Every account's live Remote Control sessions, minus the ones running here.
local function publishElsewhere()
  local out, alive = {}, {}
  local on = cfg("show_elsewhere", true)
  local multi = #accountList() > 1
  for _, a in pairs(accounts) do
    for _, r in ipairs(on and a.remote.list or {}) do
      if not localBridges[r.id] then
        r.account, r.url, r.since = a.dir, "https://claude.ai/code/" .. r.id, isoToMs(r.lastEventAt) or 0
        out[#out + 1] = r
        alive[r.id] = true
        local was = remoteSeen[r.id]
        if was and was ~= "need_input" and r.category == "need_input" and cfg("notify_waiting", true) then
          noctalia.notify("Claude needs you (elsewhere)",
            (multi and `[{a.label}] ` or "") .. r.title .. (r.needs ~= "" and (": " .. r.needs) or ""))
        end
        remoteSeen[r.id] = r.category or ""
      end
    end
  end
  for id in pairs(remoteSeen) do if not alive[id] then remoteSeen[id] = nil end end
  table.sort(out, function(x, y)
    if (x.category == "need_input") ~= (y.category == "need_input") then return x.category == "need_input" end
    return x.since > y.since
  end)
  publish("elsewhere", out)
end

local function fetchRemote(a)
  local rem = a.remote
  if rem.pending then return end
  rem.pending, rem.at = true, noctalia.nowMs()
  local started = runJson(script("remote.sh", a.dir), 20000, function(list, r)
    rem.pending = false
    local err = nil
    if list then
      rem.list = list
    else
      err = noctalia.string.trim(r.stderr or "")
      if err == "" then err = `exit {r.exitCode}` end
      -- Rate limited (curl -f reports the 429): skip ten minutes of the once-a-minute poll.
      if string.find(err, "429", 1, true) then rem.at = noctalia.nowMs() + 9 * 60000 end
    end
    if err ~= rem.err and err then noctalia.log(`claude-operator: remote sessions ({a.label}): {err}`) end
    rem.err = err
    publishElsewhere()
  end)
  if not started then rem.pending = false end
end

-- ── Live sessions ───────────────────────────────────────────────────────────

-- Variables only one terminal sets, checked when TERM_PROGRAM says nothing useful.
local TERMINAL_MARKERS = {
  { "KITTY_WINDOW_ID=", "kitty" }, { "ALACRITTY_WINDOW_ID=", "alacritty" }, { "WEZTERM_PANE=", "wezterm" },
  { "GHOSTTY_RESOURCES_DIR=", "ghostty" }, { "KONSOLE_VERSION=", "konsole" }, { "TERM=foot", "foot" },
  { "VTE_VERSION=", "vte" },
}

-- Which terminal hosts the session, with "tmux · " in front inside tmux; kitty and tmux
-- get exact tab / pane focusing (see focus.sh). Plain finds plus an anchored match: an
-- unanchored pattern over a ~15 KB environment costs ~10 ms in the shell's runtime,
-- enough to blow the callback budget.
local function terminalOf(pid)
  local t = terminals[pid]
  if t then return t end
  local env = "\0" .. (noctalia.readFile("/proc/" .. tostring(pid) .. "/environ") or "")
  local function value(name)
    local _, e = string.find(env, "\0" .. name .. "=", 1, true)
    return e and string.match(env, "^[^%z]*", e + 1) or nil
  end
  local program = value("TERM_PROGRAM")
  if program == "tmux" or program == "" then program = nil end
  if not program then
    for _, m in ipairs(TERMINAL_MARKERS) do
      if string.find(env, "\0" .. m[1], 1, true) then program = m[2] break end
    end
  end
  t = program or "terminal"
  if value("TMUX") then t = "tmux · " .. t end
  terminals[pid] = t
  return t
end

-- A state file whose pid now belongs to another process is a crash leftover: Claude
-- Code records the process start time (field 22 of /proc/<pid>/stat) as procStart.
local function alive(s)
  local stat = noctalia.readFile("/proc/" .. tostring(s.pid) .. "/stat")
  if not stat then return false end
  if not s.procStart then return true end
  local rest = string.match(stat, "^.*%)%s*(.*)$") or ""
  local i = 3 -- the remainder starts at field 3 (state); comm may hold spaces or parens
  for field in string.gmatch(rest, "%S+") do
    if i == 22 then return field == tostring(s.procStart) end
    i += 1
  end
  return false
end

-- A pid's ancestors, nearest first (cached: a process never changes parent while it
-- lives). Used to spot sessions running inside another session, such as a hook that
-- starts `claude` through the Agent SDK to review a change.
local ancestry = {} -- pid -> { ppid, grandparent pid, ... }

local function ancestorsOf(pid)
  local list = ancestry[pid]
  if list then return list end
  list = {}
  local p = pid
  for _ = 1, 16 do
    local stat = noctalia.readFile("/proc/" .. tostring(p) .. "/stat")
    local ppid = stat and tonumber(string.match(string.match(stat, "^.*%)%s*(.*)$") or "", "^%S+%s+(%d+)"))
    if not ppid or ppid <= 1 then break end
    list[#list + 1] = ppid
    p = ppid
  end
  ancestry[pid] = list
  return list
end

-- Claude Code files a transcript under the dir the session started in, encoded; a
-- session that later moved (cd, worktree) has a cwd that no longer matches, so a miss
-- falls back to one search by session id, remembered for the session's lifetime.
local function findTranscript(s, d)
  if d.path and noctalia.fileExists(d.path) then return d.path end
  local guess = `{s.account}/projects/{(string.gsub(s.cwd, "[^%w]", "-"))}/{s.sessionId}.jsonl`
  if noctalia.fileExists(guess) then d.path = guess return guess end
  if not d.searching and s.sessionId:match("^[%x-]+$") then
    d.searching = true
    noctalia.runAsync({ "find", s.account .. "/projects", "-mindepth", "2", "-maxdepth", "2",
      "-name", s.sessionId .. ".jsonl", "-print", "-quit" }, function(r)
      d.searching = false
      local found = string.match(r.stdout or "", "[^\n]+")
      if found then d.path = found end
    end, 10000)
  end
  return nil
end

local function publishSessions()
  for _, s in ipairs(current) do
    local d = details[s.pid]
    s.d = d and d.data or nil
    s.transcript = d and d.path or nil
  end
  publish("sessions", current)
end

-- details.sh re-runs only when the transcript's size or mtime changed.
local function refreshDetails(s)
  -- Without prices the cost and context window would be cached wrong until the
  -- transcript next changes; refreshPricing re-queues every session when it lands.
  if not noctalia.fileExists(PRICING) then return end
  local d = details[s.pid] or {}
  details[s.pid] = d
  local path = findTranscript(s, d)
  local info = path and noctalia.fileInfo(path)
  if not info then return end
  local key = `{info.size}:{info.mtime}`
  if d.pending or d.key == key then return end
  d.pending = true
  local started = runJson(script("details.sh", path, PRICING), 15000, function(data)
    d.pending = false
    if data then
      d.key, d.data = key, data
      publishSessions()
    end
  end)
  if not started then d.pending = false end
end

local function readSessions(a, into)
  local dir = a.dir .. "/sessions"
  for _, name in ipairs(noctalia.listDir(dir) or {}) do
    local path = string.find(name, "/") and name or dir .. "/" .. name
    -- Only <pid>.json: the <pid>.<hash>.key files beside them hold a peer token.
    if string.match(path, "/%d+%.json$") then
      local s = decode(noctalia.readFile(path))
      if s and tonumber(s.pid) and alive(s) then
        into[#into + 1] = {
          pid = s.pid,
          account = a.dir,
          sessionId = s.sessionId or "",
          name = s.name or tostring(s.pid),
          cwd = s.cwd or "",
          status = RANK[s.status] and s.status or "idle",
          waitingFor = s.waitingFor or "",
          since = s.statusUpdatedAt or s.updatedAt or s.startedAt or 0,
          terminal = terminalOf(s.pid),
          remote = type(s.bridgeSessionId) == "string" and "https://claude.ai/code/" .. s.bridgeSessionId or nil,
        }
      end
    end
  end
end

local function label(s)
  local d = details[s.pid]
  local title = d and d.data and d.data.title or s.name
  local a = accounts[s.account]
  return #accountList() > 1 and a and `[{a.label}] {title}` or title
end

local function dur(ms)
  local m = math.floor(ms / 60000)
  if m < 60 then return `{m}m` end
  return `{m // 60}h {m % 60}m`
end

-- Notifications and bookkeeping. Returns true when a session ended (Recent is stale).
local function track(sessions)
  local seen, gone = {}, false
  for _, s in ipairs(sessions) do
    seen[s.pid] = true
    local t = tracked[s.pid]
    if t then
      if t.status ~= "waiting" and s.status == "waiting" and cfg("notify_waiting", true) then
        noctalia.notify("Claude needs you", label(s) .. (s.waitingFor ~= "" and (": " .. s.waitingFor) or ""))
      elseif t.status == "busy" and s.status == "idle" and cfg("notify_finished", true) and t.busySince then
        local took = s.since - t.busySince
        if took >= minutes("finished_min_minutes", 2) then
          noctalia.notify("Claude finished", `{label(s)} · {dur(took)}`)
        end
      end
    else
      t = { history = { { s.since > 0 and s.since or noctalia.nowMs(), s.status } } }
      tracked[s.pid] = t
    end
    if s.status == "busy" and t.status ~= "busy" and t.status ~= "waiting" then t.busySince = s.since end
    if t.status and t.status ~= s.status then
      t.history[#t.history + 1] = { s.since > 0 and s.since or noctalia.nowMs(), s.status }
    end
    -- The last hour of transitions, plus the one that was current when it began.
    local cutoff = noctalia.nowMs() - HOUR_MS
    while #t.history > 1 and t.history[2][1] <= cutoff do table.remove(t.history, 1) end
    s.timeline = t.history
    t.status = s.status
  end
  for pid in pairs(tracked) do
    if not seen[pid] then tracked[pid] = nil; details[pid] = nil; terminals[pid] = nil; gone = true end
  end
  for pid in pairs(ancestry) do
    if not noctalia.fileExists("/proc/" .. tostring(pid)) then ancestry[pid] = nil end
  end
  return gone
end

local function refreshRecent()
  local count = tonumber(cfg("recent_count", 8)) or 8
  if count <= 0 then publish("recent", {}) return end
  if recentPending then return end
  recentPending = true
  local argv = script("recent.sh", tostring(count + 10))
  for _, a in ipairs(accountList()) do argv[#argv + 1] = a.dir end
  local started = runJson(argv, 15000, function(list)
    recentPending = false
    if not list then return end
    local live = {}
    for _, s in ipairs(current) do live[s.sessionId] = true end
    local out = {}
    for _, x in ipairs(list) do
      if not live[x.sessionId] and #out < count then out[#out + 1] = x end
    end
    publish("recent", out)
  end)
  if not started then recentPending = false end
end

-- ── Saved sessions and pins ─────────────────────────────────────────────────

-- Every saved session, for the Sessions tab and the launcher. list-sessions.sh caches
-- each transcript's summary, so a rebuild costs a stat per unchanged session.
local function refreshIndex()
  if indexPending then return end
  indexPending, indexAt = true, noctalia.nowMs()
  local argv = script("list-sessions.sh", DATA .. "/sessions")
  for _, a in ipairs(accountList()) do argv[#argv + 1] = a.dir end
  local started = runJson(argv, 60000, function(list, r)
    indexPending = false
    if not list then
      noctalia.log("claude-operator: session index failed: " .. noctalia.string.trim(r.stderr or ""))
      return
    end
    -- Published to every entry: ~190 KB for 490 sessions. The size is left out; the
    -- path stays, since deleting by a path rebuilt from cwd misses long, non-ASCII and
    -- empty-cwd project dirs.
    local kept = {}
    for _, x in ipairs(list) do
      x.size = nil
      if #x.prompt > 160 then x.prompt = string.sub(x.prompt, 1, 160) .. "…" end
      -- Agent SDK runs (hooks, scripts) are not sessions anyone resumes.
      if not x.auto then kept[#kept + 1] = x end
    end
    table.sort(kept, function(x, y) return x.mtime > y.mtime end)
    publish("index", kept)
  end)
  if not started then indexPending = false end
end

local pins = decode(noctalia.readFile(PINS)) or {}

local function togglePin(cwd)
  if type(cwd) ~= "string" or cwd == "" then return end
  local out, found = {}, false
  for _, p in ipairs(pins) do
    if p == cwd then found = true else out[#out + 1] = p end
  end
  if not found then out[#out + 1] = cwd end
  pins = out
  noctalia.writeFile(PINS, noctalia.json.encode(pins))
  publish("pins", pins)
end

-- ── Tick ────────────────────────────────────────────────────────────────────

local function poll()
  local now = noctalia.nowMs()
  local slow = now - lastSlow >= SLOW_MS
  if slow then lastSlow = now; discoverAccounts() end

  local sessions = {}
  for _, a in pairs(accounts) do
    readSessions(a, sessions)
    if now - a.limitsAt >= minutes("limits_refresh_minutes", 5) then fetchLimits(a) end
    if cfg("show_elsewhere", true) and now - a.remote.at >= SLOW_MS then fetchRemote(a) end
  end
  if now - usageAt >= minutes("limits_refresh_minutes", 5) then refreshUsage() end

  -- A session started from inside another one (a hook running claude through the Agent
  -- SDK, say) is that session's helper, not a line of its own: it is counted on its
  -- parent and gets no card, lamp or notification.
  local byPid, own = {}, {}
  for _, s in ipairs(sessions) do byPid[s.pid] = s end
  for _, s in ipairs(sessions) do
    local parent
    for _, a in ipairs(ancestorsOf(s.pid)) do
      if byPid[a] then parent = byPid[a] break end
    end
    if parent then parent.helpers = (parent.helpers or 0) + 1 else own[#own + 1] = s end
  end
  sessions = own

  localBridges = {}
  for _, s in ipairs(sessions) do
    if s.remote then localBridges[string.match(s.remote, "[^/]+$")] = true end
  end
  local gone = track(sessions)

  local hideMs = (tonumber(cfg("hide_idle_hours", 0)) or 0) * HOUR_MS
  local shown = {}
  for _, s in ipairs(sessions) do
    if not (hideMs > 0 and s.status == "idle" and now - s.since > hideMs) then shown[#shown + 1] = s end
  end
  table.sort(shown, function(x, y)
    if RANK[x.status] ~= RANK[y.status] then return RANK[x.status] < RANK[y.status] end
    return x.since > y.since
  end)
  current = shown
  for _, s in ipairs(sessions) do refreshDetails(s) end
  publishAccounts()
  publishSessions()
  publishElsewhere()
  if gone or slow then refreshRecent() end
  if gone or now - indexAt >= INDEX_MS then refreshIndex() end
end

-- Refresh everything that runs on a timer, now.
-- The refresh button and IPC. Plan limits only when the last try is over MIN_GAP_MS old
-- (a rate-limit hold still applies): the other sources are local or cheap.
local function refreshAll()
  lastSlow, usageAt, indexAt = -math.huge, -math.huge, -math.huge
  local now = noctalia.nowMs()
  for _, a in pairs(accounts) do
    if now - a.limitsAt >= MIN_GAP_MS then a.limitsAt = -math.huge end
    a.remote.at = -math.huge
  end
  poll()
end

-- "refresh": the panel's refresh button. "open": the panel opened, so re-check the cheap,
-- fast-moving sources (Remote Control, Recent) without spending a plan-limits request.
noctalia.state.watch("command", function(v)
  if type(v) ~= "table" then return end
  if v.action == "refresh" then
    refreshAll()
  elseif v.action == "reindex" then
    refreshIndex()
  elseif v.action == "pin" then
    togglePin(v.cwd)
  elseif v.action == "open" then
    lastSlow = -math.huge
    for _, a in pairs(accounts) do a.remote.at = -math.huge end
    poll()
  end
end)
function update() poll() end
function onIpc(event) if event == "refresh" then refreshAll() end end
-- A settings change re-reads local sources only; no setting changes what the plan
-- limits are, and toggling several settings must not burn through the rate limit.
function onConfigChanged()
  lastSlow, usageAt, indexAt = -math.huge, -math.huge, -math.huge
  poll()
end

noctalia.mkdirAll(DATA)
publishPricing()
publish("pins", pins)
noctalia.setUpdateInterval(TICK_MS)
poll()
