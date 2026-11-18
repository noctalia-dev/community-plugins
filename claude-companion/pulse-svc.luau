-- The pulse aggregator (headless [[service]]) — the single source of truth for
-- Claude session state across ALL active sessions. This is the reflex half of the
-- attention pulse, split out of the bar widget (pulse.luau) so capture no longer
-- depends on the bar dot being placed: a [[service]] runtime starts at shell launch
-- and stays alive regardless of surfaces, retiring the old "pulse must sit on a bar"
-- invariant (D10 / PROTOCOL.md "Deployment invariant").
--
-- Two feeds converge on the session table, both event-driven (no polling):
--   • Claude Code hooks → onIpc (the reflex):
--       noctalia msg plugin lowcache/claude-companion:pulse-svc all <event> [payload]
--     payload = "model,in,out,cacheCreate,cacheRead,session[,pid]" (hooks/pulse.py).
--     Each real session is tracked by its id; session_end removes it, and so does
--     the liveness sweep once the session's Claude process is gone.
--   • claude.luau writes "claude.state" (the launcher quick-ask) → watched here as
--     one ephemeral pseudo-session ("ask"), removed when the ask completes.
-- A third feed needs no hooks at all: update() reads Claude Code's own per-process
-- session files, so a session shows up (working / needs you / idle) before any hook
-- is installed. Hooks add tool detail and token burn; the newest signal wins, so the
-- file also corrects what hooks never report (an Esc interrupt, a pending question).
--
-- On every change it republishes a rollup to noctalia.state ("claude.pulse"); the
-- bar dot (pulse.luau) and the desktop orb (orb.luau) are pure subscribers of that
-- key — one source of truth, two surfaces. The only timer work is the liveness
-- sweep in update(), which reads procfs and does nothing until a session has a pid.

-- ── priority (aggregation only) ──────────────────────────────────────────────
-- With several sessions in different states, the rollup reports the most urgent:
-- a session that needs you outranks one merely working, which outranks one idle.
local STATE_PRIO = {
  needs_attention = 6, error = 5, tool_start = 4,
  turn_start = 3, text = 3, turn_end = 2, idle = 1,
}

-- sid -> { sid, state, model, tin, tout, cr, seq, pid?, pstart?, hooked?, hook_at?, detected? }.
-- `seq` is a monotonic counter
-- (no os.time dependency in the sandbox) used to order sessions by recency.
local sessions = {}
local seq = 0
local last_ask = nil -- last claude.state value folded into the "ask" session
-- sid -> ended pid (or true if unknown) after session_end, so a still-exiting process is
-- not re-detected while a resume in a NEW process still is.
local ended = {}

-- ── payload plumbing ─────────────────────────────────────────────────────────
local function split(s, sep)
  local out = {}
  for part in (s .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = part end
  return out
end

-- "model,in,out,cacheCreate,cacheRead,session[,pid]" -> a session delta, or nil.
-- "in" (fresh prompt tokens) is tiny next to cache reads, so the displayed input is
-- fresh + cache-create (full-rate work); cache reads are tracked separately. pid is
-- digits-only because it becomes part of a /proc path.
local function parse_payload(tel)
  if not tel or tel == "" then return nil end
  local f = split(tel, ",")
  local sid = f[6]
  if not sid or sid == "" then return nil end
  return {
    sid = sid,
    model = (f[1] and f[1] ~= "") and f[1] or "?",
    tin = (tonumber(f[2]) or 0) + (tonumber(f[4]) or 0),
    tout = tonumber(f[3]) or 0,
    cr = tonumber(f[5]) or 0,
    pid = (f[7] and f[7]:match("^%d+$") and #f[7] <= 8) and f[7] or nil,
  }
end

-- ── liveness ─────────────────────────────────────────────────────────────────
-- SessionEnd never fires when Claude dies (terminal closed, kill, crash), which left
-- such a session at its last state forever. A session whose events carry a pid is
-- retired once /proc/<pid>/stat is gone or its start time changed (pid reused).
-- Host readFile only, zero spawns. A session whose pid could not be read at first
-- sight (procfs hidden, no pid sent) is never swept: fail open, as before.
local SWEEP_MS = 5000

-- starttime is field 22; comm (field 2) may hold spaces or parens, so count from
-- the LAST ')'.
local function proc_start(pid)
  local raw = noctalia.readFile and noctalia.readFile("/proc/" .. pid .. "/stat")
  if type(raw) ~= "string" then return nil end
  local rest = raw:match(".*%)%s+(.*)")
  local i = 2
  for tok in (rest or ""):gmatch("%S+") do
    i = i + 1
    if i == 22 then return tok end
  end
  return nil
end

local function has_burn(s)
  return s.model and s.model ~= "?" and ((s.tin or 0) + (s.tout or 0)) > 0
end

local function ordered()
  local arr = {}
  for _, s in pairs(sessions) do arr[#arr + 1] = s end
  table.sort(arr, function(a, b) return (a.seq or 0) > (b.seq or 0) end)
  return arr
end

local function touch(sid, state, p)
  seq = seq + 1
  local s = sessions[sid] or { sid = sid }
  s.state = state
  s.seq = seq
  s.hooked = true -- every caller is an event feed; detection builds its own entries
  s.hook_at = noctalia.nowMs and noctalia.nowMs() or nil -- epoch ms, the file's clock too
  if p then
    s.model, s.tin, s.tout, s.cr = p.model, p.tin, p.tout, p.cr
    if p.pid and p.pid ~= s.pid then
      local start = proc_start(p.pid)
      if start then s.pid, s.pstart = p.pid, start end
    end
  end
  sessions[sid] = s
end

-- ── consent mode mirror ──────────────────────────────────────────────────────
-- hooks/consent.py runs as a Claude Code hook, outside the shell, so it cannot call
-- noctalia.getConfig. The service mirrors the `consent_mode` setting into a file the
-- hook reads instead, keeping the Noctalia setting the single source of truth.
--
-- A MISSING file means off, which is what makes this safe: if the shell is not
-- running there is nothing that could answer a prompt, and the gate stays inert.
local MODES = { off = true, learn = true, enforce = true }

local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- No guessed fallback: a wrong runtime dir is worse than none. Absent the variable
-- the mirror is skipped, the mode file never appears, and the gate reads that as off
-- — the same conclusion hooks/consent.py reaches for the same reason.
local function runtime_dir()
  local v = noctalia.getenv and noctalia.getenv("XDG_RUNTIME_DIR")
  if type(v) == "string" and v ~= "" then return v .. "/claude-companion" end
  return nil
end

-- Written only when it would change something: publish() runs on every event, and a
-- shell-out per tool call is not free. The comparison is against the FILE, not a
-- cached value -- the runtime dir is tmpfs, and a cached "already wrote it" strands
-- the gate reading "off" for the rest of the session if that file goes away.
local function mirror_mode()
  local m = noctalia.getConfig and noctalia.getConfig("consent_mode")
  if not MODES[m] then m = "off" end
  local dir = runtime_dir()
  if not dir then return end
  if noctalia.readFile(dir .. "/mode") == m then return end
  noctalia.runAsync(
    "mkdir -p -m 700 " .. shq(dir) ..
    " && (umask 077; printf %s " .. shq(m) .. " > " .. shq(dir .. "/mode") .. ")"
  )
end

-- ── presence (the agent's own voice) ─────────────────────────────────────────
-- Everything else here is INFERRED: hooks fire on lifecycle edges and this service
-- deduces a state. Presence is the one channel where the agent says what it is doing
-- in its own words (shim/noctalia-mcp.py set_presence), and it rides a file for the
-- same reason the consent request does — a payload is one space-free token, and prose
-- is not. An ABSENT file means no message, so clearing is an unlink, not a sentinel.
--
-- It is deliberately NOT a session: presence attaches to the rollup, not the session
-- table, so it can never inflate the count or outrank a real state. MCP servers are
-- not handed the Claude session id, so there is nothing to attribute it to yet.
local presence = nil

local function read_presence()
  local dir = runtime_dir()
  if not dir then presence = nil; return end
  local raw = noctalia.readFile(dir .. "/presence")
  if type(raw) ~= "string" or raw == "" then presence = nil; return end
  local ok, data = pcall(noctalia.json.decode, raw)
  if not ok or type(data) ~= "table" or type(data.message) ~= "string" or data.message == "" then
    presence = nil
    return
  end
  presence = data.message
end

-- ── publish ──────────────────────────────────────────────────────────────────
-- Roll every live session up to the most-urgent state + burn totals and mirror it
-- to shared state. Both surfaces subscribe to "claude.pulse" and never re-derive it.
-- Schema (v2): top-level fields (state/count/model/tin/tout/cr) are the single-glance
-- rollup the orb reads — single-session values when count==1, the Σ when >1. The
-- `sessions` array (most-recent first) carries per-session detail for the bar's
-- multi-session tooltip; the orb ignores it, so the top-level shape stays backward
-- compatible. Published only on events (never a timer), so subscribers aren't spammed.
local function publish()
  local arr = ordered()
  local count = #arr

  local best, bestp = "idle", 0
  for _, s in ipairs(arr) do
    local p = STATE_PRIO[s.state] or 0
    if p > bestp then bestp = p; best = s.state end
  end

  local snap = { state = best, count = count, model = "?", tin = 0, tout = 0, cr = 0, sessions = {} }
  for i, s in ipairs(arr) do
    snap.sessions[i] = {
      sid = s.sid, state = s.state, model = s.model or "?",
      tin = s.tin or 0, tout = s.tout or 0, cr = s.cr or 0,
      nohooks = (s.detected and not s.hooked) or nil,
    }
  end
  if count == 1 and has_burn(arr[1]) then
    local s = arr[1]
    snap.model, snap.tin, snap.tout, snap.cr = s.model, s.tin, s.tout, s.cr
  elseif count > 1 then
    local Tin, Tout = 0, 0
    for _, s in ipairs(arr) do
      if has_burn(s) then Tin = Tin + s.tin; Tout = Tout + s.tout end
    end
    snap.tin, snap.tout = Tin, Tout
  end
  snap.message = presence
  noctalia.state.set("claude.pulse", snap)
  mirror_mode()
end

-- ── quick-ask feed (launcher) ────────────────────────────────────────────────
-- claude.luau publishes the /claude ? stream state to "claude.state" (no session id,
-- no telemetry). Shown while streaming, dropped when it finishes — the answer is
-- delivered via notify, so a lingering "done" would only inflate the session count.
-- Event-driven via state.watch (cross-runtime in Noctalia 5 beta), so the service
-- holds no timer for it. Only a *change* touches the session table + republishes.
local function fold_ask(v)
  local s = (type(v) == "string" and v ~= "") and v or nil
  if s == last_ask then return end
  last_ask = s
  if s == nil or s == "turn_end" or s == "error" then
    sessions["ask"] = nil
  else
    touch("ask", s, nil)
  end
  publish()
end

-- ── hook reflex ──────────────────────────────────────────────────────────────
-- Per-session state + token telemetry, full lifecycle. The dispatcher always tags
-- the event with a session id; session_end (the Claude Code SessionEnd hook) retires
-- the session so stale entries never accumulate.
--
-- A payload-less event carries no session id (real hook events always do) — only a
-- manual `noctalia msg … :pulse-svc all <event>` poke from the CLI does. Those land
-- in a single "default" test slot. To keep such a poke from leaving a sticky phantom
-- session, any RESTING state (idle / turn_end / error) retires "default" too — so
-- `… all idle` cleanly clears the orb after a manual test, without a plugin reload.
local MANUAL_REST = { idle = true, turn_end = true, error = true }
function onIpc(event, payload)
  if type(event) ~= "string" then return end

  -- A consent prompt is outstanding: publish the request id for the panel to pick up
  -- and drive that session to needs_attention so the bar reflects it. Payload is
  -- "<request id>,<session id>" (hooks/consent.py). No resolve event is needed — the
  -- PostToolUse hook's turn_start re-touches the session either way, and the panel
  -- treats the request FILE as the source of truth, so a stale id renders as empty.
  -- The agent set or cleared its presence line. The file is the source of truth, so
  -- one bare poke serves both: re-read, and an absent file clears the message.
  if event == "presence" then
    read_presence()
    publish()
    return
  end

  if event == "consent_request" then
    local f = split(tostring(payload or ""), ",")
    local rid, sid = f[1], f[2]
    if not rid or rid == "" then return end
    -- Parallel tool calls produce parallel prompts, so this is a queue, not a slot:
    -- overwriting it left every request but the newest with no surface, stalled until
    -- its deadline. The panel shows them oldest-first and skips ids whose request file
    -- is already gone, so entries retire themselves and this only has to be bounded.
    local q = {}
    local snap = noctalia.state.get and noctalia.state.get("claude.consent")
    if type(snap) == "table" and type(snap.ids) == "table" then
      for _, v in ipairs(snap.ids) do
        if v ~= rid and #q < 15 then q[#q + 1] = v end
      end
    end
    q[#q + 1] = rid
    noctalia.state.set("claude.consent", { id = q[1], ids = q, sid = sid or "" })
    if sid and sid ~= "" then
      touch(sid, "needs_attention", nil)
      publish()
    end
    return
  end

  local p = parse_payload(payload)
  local sid = (p and p.sid) or "default"
  if event == "session_end" or (sid == "default" and MANUAL_REST[event]) then
    if event == "session_end" then ended[sid] = (sessions[sid] and sessions[sid].pid) or true end
    sessions[sid] = nil
  else
    touch(sid, event, p)
  end
  publish()
end

-- ── hookless detection ───────────────────────────────────────────────────────
-- Claude Code keeps <config>/sessions/<pid>.json per live process (undocumented;
-- read defensively). A file survives SIGKILL, so the pid must be alive with the same
-- start time; a file without procStart cannot prove that and is skipped. Only
-- kind=interactive; entrypoint sdk-* is `claude -p` / SDK runs
-- (the quick-ask, scripts, a memd curator) and is skipped. Status mapping is the one
-- Claude Code 2.1.272 writes: busy / waiting (permission or input) / idle / shell.
local DETECT_STATE = { busy = "turn_start", waiting = "needs_attention", idle = "idle", shell = "idle" }
-- Coarse classes for reconciling a hooked session with its file: a newer file status
-- replaces the hook state only when the class differs, so hook detail (tool vs
-- thinking, done vs idle) survives whenever the two agree.
local CLASS = {
  turn_start = "work", tool_start = "work", text = "work",
  needs_attention = "wait", idle = "rest", turn_end = "rest", error = "rest",
}

local function sessions_dir()
  local root = noctalia.getenv and noctalia.getenv("CLAUDE_CONFIG_DIR")
  if type(root) ~= "string" or root == "" then root = "~/.claude" end
  return root .. "/sessions"
end

-- short sid -> { pid, pstart, status } for every live interactive session.
local function scan()
  local found = {}
  if noctalia.getConfig and noctalia.getConfig("detect_sessions") == false then return found end
  local dir = sessions_dir()
  local names = noctalia.listDir and noctalia.listDir(dir)
  if type(names) ~= "table" then return found end
  for _, name in ipairs(names) do
    local pid = type(name) == "string" and name:match("^(%d+)%.json$")
    local raw = pid and noctalia.readFile(dir .. "/" .. name)
    local ok, d = pcall(noctalia.json.decode, type(raw) == "string" and raw or "")
    if ok and type(d) == "table" and type(d.sessionId) == "string"
      and (d.kind == nil or d.kind == "interactive")
      and not (type(d.entrypoint) == "string" and d.entrypoint:sub(1, 4) == "sdk-") then
      local sid = d.sessionId:match("^([%w_]+)")
      local start = proc_start(pid)
      local prev = sid and found[sid]
      if sid and start and d.procStart ~= nil and tostring(d.procStart) == start
        and not (prev and (tonumber(prev.pstart) or 0) > (tonumber(start) or 0)) then
        found[sid] = { pid = pid, pstart = start, status = d.status, status_at = tonumber(d.statusUpdatedAt) } -- newest process wins
      end
    end
  end
  return found
end

function update()
  local changed = false
  for sid, s in pairs(sessions) do
    if s.pid and proc_start(s.pid) ~= s.pstart then
      sessions[sid] = nil
      changed = true
    end
  end

  local found = scan()
  for sid, pid in pairs(ended) do
    local f = found[sid]
    if not f or (pid ~= true and f.pid ~= pid) then ended[sid] = nil end
  end
  for sid, f in pairs(found) do
    local s = sessions[sid]
    local state = DETECT_STATE[f.status] or "idle"
    if s == nil and not ended[sid] then
      seq = seq + 1
      sessions[sid] = { sid = sid, state = state, seq = seq, pid = f.pid, pstart = f.pstart, detected = true }
      changed = true
    elseif s ~= nil then
      if not s.pid then s.pid, s.pstart = f.pid, f.pstart end -- arms liveness for pid-less hooks
      -- Hooks never fire for an Esc interrupt or while a question awaits an answer;
      -- a file status written after the last hook event is the fresher truth.
      local adopt
      if s.hooked then
        adopt = f.status_at ~= nil and s.hook_at ~= nil and f.status_at > s.hook_at
          and CLASS[s.state] ~= CLASS[state]
      else
        adopt = s.state ~= state
      end
      if adopt then
        seq = seq + 1
        s.state, s.seq = state, seq
        changed = true
      end
    end
  end
  -- A detection-only session whose file is gone exited cleanly (or detection was
  -- turned off); hooked sessions are left to session_end and the liveness sweep.
  for sid, s in pairs(sessions) do
    if s.detected and not s.hooked and not found[sid] then
      sessions[sid] = nil
      changed = true
    end
  end
  if changed then publish() end
end

-- ── init ─────────────────────────────────────────────────────────────────────
-- Watch the quick-ask channel, then fold any value already present (a stream in
-- flight when the service (re)loads) and publish an initial idle rollup so a
-- subscriber that reads "claude.pulse" before the first event sees a valid state.
read_presence()
if noctalia.setUpdateInterval then noctalia.setUpdateInterval(SWEEP_MS) end
noctalia.state.watch("claude.state", fold_ask)
local init = noctalia.state.get and noctalia.state.get("claude.state")
if type(init) == "string" and init ~= "" then
  last_ask = init
  if not (init == "turn_end" or init == "error") then touch("ask", init, nil) end
end
publish()
