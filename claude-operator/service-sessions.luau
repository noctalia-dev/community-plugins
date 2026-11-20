--!nonstrict
-- Live sessions: the running claude processes, read from each account's sessions/ files
-- every tick; which terminal hosts each one, whether its pid is still that process and
-- whose child it is; its transcript and details (details.sh); the notifications for a
-- session that needs you or finished; and the recently closed ones to resume (recent.sh).

local core = require("./service-core.luau")
local acc = require("./service-accounts.luau")
local accounts, details = core.accounts, core.details
local cfg, minutes, decode = core.cfg, core.minutes, core.decode
local runJson, publish, script = core.runJson, core.publish, core.script
local PRICING, RANK, HOUR_MS = core.PRICING, core.RANK, core.HOUR_MS
local M = {}

local terminals = {} -- pid -> terminal name; a process's environment never changes
local tracked = {} -- pid -> { status, busySince }
local recentPending = false

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

function M.ancestorsOf(pid)
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

function M.publishSessions()
  for _, s in ipairs(core.current) do
    local d = details[s.pid]
    s.d = d and d.data or nil
    s.transcript = d and d.path or nil
  end
  publish("sessions", core.current)
end

-- details.sh re-runs only when the transcript's size or mtime changed.
function M.refreshDetails(s)
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
      M.publishSessions()
    end
  end)
  if not started then d.pending = false end
end

function M.readSessions(a, into)
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
  return #acc.accountList() > 1 and a and `[{a.label}] {title}` or title
end

local function dur(ms)
  local m = math.floor(ms / 60000)
  if m < 60 then return `{m}m` end
  return `{m // 60}h {m % 60}m`
end

-- Notifications and bookkeeping. Returns true when a session ended (Recent is stale).
function M.track(sessions)
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

function M.refreshRecent()
  local count = tonumber(cfg("recent_count", 8)) or 8
  if count <= 0 then publish("recent", {}) return end
  if recentPending then return end
  recentPending = true
  local argv = script("recent.sh", tostring(count + 10))
  for _, a in ipairs(acc.accountList()) do argv[#argv + 1] = a.dir end
  local started = runJson(argv, 15000, function(list)
    recentPending = false
    if not list then return end
    local live = {}
    for _, s in ipairs(core.current) do live[s.sessionId] = true end
    local out = {}
    for _, x in ipairs(list) do
      if not live[x.sessionId] and #out < count then out[#out + 1] = x end
    end
    publish("recent", out)
  end)
  if not started then recentPending = false end
end

return M
