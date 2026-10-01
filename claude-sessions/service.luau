--!nonstrict
-- Every Claude Code account is a config dir (~/.claude, or whatever CLAUDE_CONFIG_DIR points at).
-- In each, Claude Code writes sessions/<pid>.json with status busy|idle|waiting (+ waitingFor).
-- Files of crashed sessions linger, so keep only those whose pid is still alive.
-- Per-session details (title, current tool, cost, ...) come from the transcript via details.sh,
-- re-read only when the transcript's mtime changes. Recently closed sessions come from recent.sh.
local PLUGIN = noctalia.pluginDir()
local HOME = noctalia.getenv("HOME") or ""
local DEFAULT_DIR = HOME .. "/.claude"
local DATA_DIR = noctalia.pluginDataDir()
local SAVED = DATA_DIR and DATA_DIR .. "/accounts.json" or nil
local RANK = { waiting = 0, busy = 1, idle = 2 }
local SLOW_EVERY = 30 -- polls (~1 min): account discovery, Recent

-- Plan limits. If the claude-dashboard plugin is installed, its statusline caches Anthropic's
-- oauth/usage response per account (cache-<sha256(token)[:16]>.json) whenever a session redraws,
-- and we just read it. When that cache is missing or stale we call the API ourselves via
-- limits.sh (the account's own OAuth token, read-only).
local FRESH_MS = 5 * 60000 -- dashboard cache counts as fresh / min gap between our own API calls
local DASHBOARD_DIR = noctalia.expandPath("~/.cache/claude-dashboard")
local LIMITS = { { key = "five_hour", label = "5h" }, { key = "seven_day", label = "7d" },
  { key = "seven_day_fable", label = "Fable 7d" }, { key = "seven_day_sonnet", label = "Sonnet 7d" } }

local accounts = {} -- dir -> { dir, label, email, hash, limits, api = { windows, at, lastTry, pending } }
local details = {} -- pid -> { mtime, data, pending }
local terminals = {} -- pid -> terminal kind; a process's env never changes
local tracked = {} -- pid -> { status, busySince }
local current = {}
local ticks = 0
local recentPending = false

local function cfg(key, fallback)
  local v = noctalia.getConfig(key)
  if v == nil then return fallback end
  return v
end

local function normDir(dir)
  if type(dir) ~= "string" or dir == "" then return nil end
  return (string.gsub(noctalia.expandPath(dir), "/+$", ""))
end

-- ── Accounts ────────────────────────────────────────────────────────────────

-- "~/.claude" -> "default", "~/.claude-work" -> "work", "~/claude/personal" -> "personal".
local function labelFor(dir)
  local labels = cfg("account_labels", {})
  if type(labels) == "table" then
    for k, v in pairs(labels) do
      if normDir(k) == dir and v ~= "" then return v end
    end
  end
  if dir == DEFAULT_DIR then return "default" end
  local base = string.match(dir, "([^/]+)$") or dir
  local name = string.gsub(string.gsub(base, "^%.", ""), "^claude[%-_%.]?", "")
  return name ~= "" and name or base
end

local function refreshAccountInfo(a)
  a.label = labelFor(a.dir)
  -- Account metadata lives in .claude.json: inside the config dir, or next to ~/.claude by default.
  local file = a.dir == DEFAULT_DIR and HOME .. "/.claude.json" or a.dir .. "/.claude.json"
  local info = noctalia.json.decode(noctalia.readFile(file) or "")
  a.email = type(info) == "table" and type(info.oauthAccount) == "table" and info.oauthAccount.emailAddress or nil
  a.hashPending = noctalia.runAsync({ PLUGIN .. "/limits.sh", a.dir, "hash" }, function(r)
    a.hash = r.exitCode == 0 and noctalia.string.trim(r.stdout or "") or nil
    a.hashPending = false
  end, 5000)
end

local function addAccount(dir)
  dir = normDir(dir)
  if not dir or accounts[dir] or not noctalia.fileExists(dir) then return false end
  local a = { dir = dir, api = { at = 0, lastTry = -math.huge } }
  accounts[dir] = a
  refreshAccountInfo(a)
  return true
end

-- Remembers non-default accounts in the plugin's data dir so their Recent sessions survive a restart.
local function saveAccounts()
  if not SAVED then return end
  local dirs = {}
  for dir in pairs(accounts) do if dir ~= DEFAULT_DIR then dirs[#dirs + 1] = dir end end
  table.sort(dirs)
  noctalia.mkdirAll(DATA_DIR)
  noctalia.writeFile(SAVED, noctalia.json.encode(dirs))
end

-- Known accounts: the default dir, the `config_dirs` setting, dirs seen before, and (async, via
-- running.sh) the config dirs of running claude processes.
local function discoverAccounts()
  local added = addAccount(DEFAULT_DIR)
  for _, d in ipairs(cfg("config_dirs", {}) or {}) do added = addAccount(d) or added end
  local saved = SAVED and noctalia.json.decode(noctalia.readFile(SAVED) or "")
  for _, d in ipairs(type(saved) == "table" and saved or {}) do added = addAccount(d) or added end
  for dir, a in pairs(accounts) do
    if noctalia.fileExists(dir) then refreshAccountInfo(a) else accounts[dir] = nil; added = true end
  end
  if added then saveAccounts() end
  noctalia.runAsync({ PLUGIN .. "/running.sh" }, function(r)
    local found = false
    for line in string.gmatch(r.stdout or "", "[^\n]+") do found = addAccount(line) or found end
    if found then saveAccounts() end
  end, 10000)
end

-- Accounts in display order: default first, then by label.
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
  noctalia.state.set("accounts", out)
end

-- ── Plan limits ─────────────────────────────────────────────────────────────

-- "2026-10-01T20:29:59.766+00:00" -> epoch ms (UTC; honours the offset).
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

local function setLimits(a, windows, updated, source)
  local out = { updated = updated, source = source, windows = {} }
  for _, w in ipairs(windows) do
    if w.percent then
      out.windows[#out.windows + 1] = { label = w.label, percent = w.percent, resetsAt = isoToMs(w.resets_at) }
    end
  end
  a.limits = out
end

-- This account's claude-dashboard cache as { windows, timestamp }, or nil.
local function dashboardLimits(a)
  if not a.hash or a.hash == "" then return nil end
  local c = noctalia.json.decode(noctalia.readFile(`{DASHBOARD_DIR}/cache-{a.hash}.json`) or "")
  if type(c) ~= "table" or type(c.data) ~= "table" then return nil end
  local windows = {}
  for _, l in ipairs(LIMITS) do
    local w = c.data[l.key]
    if type(w) == "table" then windows[#windows + 1] = { label = l.label, percent = w.utilization, resets_at = w.resets_at } end
  end
  return { windows = windows, timestamp = c.timestamp or 0 }
end

local function fetchApiLimits(a)
  local api = a.api
  if api.pending then return end
  api.pending, api.lastTry = true, noctalia.nowMs()
  local started = noctalia.runAsync({ PLUGIN .. "/limits.sh", a.dir, "fetch" }, function(r)
    api.pending = false
    local list = r.exitCode == 0 and noctalia.json.decode(r.stdout) or nil
    if type(list) == "table" then
      api.windows, api.at = list, noctalia.nowMs()
      setLimits(a, list, api.at, "api")
      publishAccounts()
    elseif (r.stderr or "") ~= "" then
      noctalia.log(`claude-sessions: limits API ({a.label}): {noctalia.string.trim(r.stderr)}`)
    end
  end, 20000)
  if not started then api.pending = false end
end

local function readLimits(a)
  if a.hashPending then return end -- don't hit the API before we know which dashboard cache is ours
  local now, api = noctalia.nowMs(), a.api
  local dash = dashboardLimits(a)
  if dash and now - dash.timestamp < FRESH_MS then
    setLimits(a, dash.windows, dash.timestamp, "claude-dashboard")
    return
  end
  -- Dashboard absent or stale: show the newest data we have, and refresh from the API.
  if api.windows and (not dash or api.at > dash.timestamp) then
    setLimits(a, api.windows, api.at, "api")
  elseif dash then
    setLimits(a, dash.windows, dash.timestamp, "claude-dashboard")
  end
  if now - api.lastTry >= FRESH_MS then fetchApiLimits(a) end
end

-- ── Sessions ────────────────────────────────────────────────────────────────

-- Which terminal hosts the session: kitty sessions get exact tab focusing (see focus.sh).
local function terminalOf(pid)
  local t = terminals[pid]
  if t then return t end
  local env = noctalia.readFile("/proc/" .. tostring(pid) .. "/environ") or ""
  if string.find(env, "KITTY_WINDOW_ID=", 1, true) then
    t = "kitty"
  else
    t = string.match(env, "TERM_PROGRAM=([^%z]+)") or "terminal"
  end
  terminals[pid] = t
  return t
end

local function publish()
  for _, s in ipairs(current) do
    local d = details[s.pid]
    s.d = d and d.data or nil
  end
  noctalia.state.set("sessions", current)
end

local function refreshDetails(s)
  local path = `{s.account}/projects/{(string.gsub(s.cwd, "[^%w]", "-"))}/{s.sessionId}.jsonl`
  local info = noctalia.fileInfo(path)
  if not info then return end
  local d = details[s.pid] or {}
  details[s.pid] = d
  if d.pending or d.mtime == info.mtime then return end
  d.pending = true
  local started = noctalia.runAsync({ PLUGIN .. "/details.sh", path, s.sessionId, s.account }, function(r)
    d.pending = false
    local data = r.exitCode == 0 and noctalia.json.decode(r.stdout) or nil
    if type(data) == "table" then
      d.mtime = info.mtime
      d.data = data
      publish()
    end
  end, 15000)
  if not started then d.pending = false end
end

local function refreshRecent()
  local count = tonumber(cfg("recent_count", 8)) or 8
  if count <= 0 then noctalia.state.set("recent", {}) return end
  if recentPending then return end
  recentPending = true
  local cmd = { PLUGIN .. "/recent.sh", tostring(count + 10) }
  for _, a in ipairs(accountList()) do cmd[#cmd + 1] = a.dir end
  local started = noctalia.runAsync(cmd, function(r)
    recentPending = false
    local list = r.exitCode == 0 and noctalia.json.decode(r.stdout) or nil
    if type(list) ~= "table" then return end
    local live = {}
    for _, s in ipairs(current) do live[s.sessionId] = true end
    local out = {}
    for _, x in ipairs(list) do
      if not live[x.sessionId] and #out < count then out[#out + 1] = x end
    end
    noctalia.state.set("recent", out)
  end, 15000)
  if not started then recentPending = false end
end

local function label(s)
  local d = details[s.pid]
  local title = d and d.data and d.data.title or s.name
  local multi = #accountList() > 1
  return multi and accounts[s.account] and `[{accounts[s.account].label}] {title}` or title
end

local function dur(ms)
  local m = math.floor(ms / 60000)
  if m < 60 then return `{m}m` end
  return `{m // 60}h {m % 60}m`
end

-- Notifications + bookkeeping. Returns true when a session disappeared (so Recent should refresh).
local function track(sessions)
  local alive, gone = {}, false
  for _, s in ipairs(sessions) do
    alive[s.pid] = true
    local t = tracked[s.pid]
    if t then
      if t.status ~= "waiting" and s.status == "waiting" and cfg("notify_waiting", true) then
        noctalia.notify("Claude needs you", label(s) .. (s.waitingFor ~= "" and (": " .. s.waitingFor) or ""))
      elseif t.status == "busy" and s.status == "idle" and cfg("notify_finished", true) and t.busySince then
        local took = s.since - t.busySince
        if took >= (tonumber(cfg("finished_min_minutes", 2)) or 2) * 60000 then
          noctalia.notify("Claude finished", `{label(s)} · {dur(took)}`)
        end
      end
    else
      t = {}
      tracked[s.pid] = t
    end
    if s.status == "busy" and t.status ~= "busy" and t.status ~= "waiting" then t.busySince = s.since end
    t.status = s.status
  end
  for pid in pairs(tracked) do
    if not alive[pid] then tracked[pid] = nil; details[pid] = nil; terminals[pid] = nil; gone = true end
  end
  return gone
end

local function readSessions(a, into)
  local dir = a.dir .. "/sessions"
  for _, name in ipairs(noctalia.listDir(dir) or {}) do
    local path = string.find(name, "/") and name or dir .. "/" .. name
    if string.sub(path, -5) == ".json" then
      local s = noctalia.json.decode(noctalia.readFile(path) or "")
      if type(s) == "table" and s.pid and noctalia.fileExists("/proc/" .. tostring(s.pid)) then
        into[#into + 1] = {
          pid = s.pid,
          account = a.dir,
          sessionId = s.sessionId or "",
          name = s.name or tostring(s.pid),
          cwd = s.cwd or "",
          status = s.status or "idle",
          waitingFor = s.waitingFor or "",
          since = s.statusUpdatedAt or s.updatedAt or 0,
          terminal = terminalOf(s.pid),
        }
      end
    end
  end
end

local function poll()
  if ticks % SLOW_EVERY == 0 then discoverAccounts() end
  local hideMs = (tonumber(cfg("hide_idle_hours", 0)) or 0) * 3600000
  local now = noctalia.nowMs()
  local sessions = {}
  for _, a in pairs(accounts) do
    readSessions(a, sessions)
    readLimits(a)
  end
  local gone = track(sessions)
  local shown = {}
  for _, s in ipairs(sessions) do
    if not (hideMs > 0 and s.status == "idle" and now - s.since > hideMs) then shown[#shown + 1] = s end
  end
  table.sort(shown, function(a, b)
    local ra, rb = RANK[a.status] or 3, RANK[b.status] or 3
    if ra ~= rb then return ra < rb end
    return a.since > b.since
  end)
  current = shown
  for _, s in ipairs(sessions) do refreshDetails(s) end
  publishAccounts()
  publish()
  if gone or ticks % SLOW_EVERY == 1 then refreshRecent() end
  ticks += 1
end

noctalia.state.watch("command", function(v)
  if type(v) == "table" and v.action == "refresh" then ticks = 0; poll() end
end)
function update() poll() end
function onIpc(event) if event == "refresh" then ticks = 0; poll() end end
function onConfigChanged() ticks = 0; poll() end
noctalia.setUpdateInterval(2000)
poll()
