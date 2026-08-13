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
--     payload = "model,in,out,cacheCreate,cacheRead,session" (hooks/pulse.py).
--     Each real session is tracked by its id; session_end removes it.
--   • claude.luau writes "claude.state" (the launcher quick-ask) → watched here as
--     one ephemeral pseudo-session ("ask"), removed when the ask completes.
--
-- On every change it republishes a rollup to noctalia.state ("claude.pulse"); the
-- bar dot (pulse.luau) and the desktop orb (orb.luau) are pure subscribers of that
-- key — one source of truth, two surfaces. The service defines NO update(): it is
-- purely event-driven, so the host's per-service timer tick is a cheap no-op.

-- ── priority (aggregation only) ──────────────────────────────────────────────
-- With several sessions in different states, the rollup reports the most urgent:
-- a session that needs you outranks one merely working, which outranks one idle.
local STATE_PRIO = {
  needs_attention = 6, error = 5, tool_start = 4,
  turn_start = 3, text = 3, turn_end = 2, idle = 1,
}

-- sid -> { sid, state, model, tin, tout, cr, seq }. `seq` is a monotonic counter
-- (no os.time dependency in the sandbox) used to order sessions by recency.
local sessions = {}
local seq = 0
local last_ask = nil -- last claude.state value folded into the "ask" session

-- ── payload plumbing ─────────────────────────────────────────────────────────
local function split(s, sep)
  local out = {}
  for part in (s .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = part end
  return out
end

-- "model,in,out,cacheCreate,cacheRead,session" -> a session delta, or nil. "in"
-- (fresh prompt tokens) is tiny next to cache reads, so the displayed input is
-- fresh + cache-create (full-rate work); cache reads are tracked separately.
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
  }
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
  if p then
    s.model, s.tin, s.tout, s.cr = p.model, p.tin, p.tout, p.cr
  end
  sessions[sid] = s
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
  noctalia.state.set("claude.pulse", snap)
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
  local p = parse_payload(payload)
  local sid = (p and p.sid) or "default"
  if event == "session_end" or (sid == "default" and MANUAL_REST[event]) then
    sessions[sid] = nil
  else
    touch(sid, event, p)
  end
  publish()
end

-- ── init ─────────────────────────────────────────────────────────────────────
-- Watch the quick-ask channel, then fold any value already present (a stream in
-- flight when the service (re)loads) and publish an initial idle rollup so a
-- subscriber that reads "claude.pulse" before the first event sees a valid state.
noctalia.state.watch("claude.state", fold_ask)
local init = noctalia.state.get and noctalia.state.get("claude.state")
if type(init) == "string" and init ~= "" then
  last_ask = init
  if not (init == "turn_end" or init == "error") then touch("ask", init, nil) end
end
publish()
