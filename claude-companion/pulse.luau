-- The attention pulse (bar widget) — a glanceable live readout of Claude across
-- ALL active sessions. Two feeds converge on the session table:
--   • Claude Code hooks fire the plugin-dispatch IPC → onIpc here (the reflex):
--       noctalia msg plugin lowcache/claude-companion:pulse all <event> [payload]
--     payload = "model,in,out,cacheCreate,cacheRead,session" (hooks/pulse.py).
--     Each real session is tracked by its id; SessionEnd removes it.
--   • claude.luau writes "claude.state" (the launcher quick-ask) → POLLED here (bar
--     widgets don't fire state.watch in v5 — D8 / README) as one ephemeral pseudo-
--     session ("ask"), removed when the ask completes.
--
-- Bar plugin widgets have no per-frame tick (that's desktop-only), so the breath
-- runs on noctalia.setUpdateInterval(ms) + the global update(): a raised-cosine
-- BRIGHTNESS breath (the winner of the barpulse A/B prototype — the bar ignores
-- 8-digit #RRGGBBAA alpha, but a 6-digit #RRGGBB scaled toward black reads as a
-- glow). Discrete state (glyph/tooltip/session rollup) renders on events; the
-- timer only advances the breath. A state change snaps the breath to its peak,
-- so transitions read as a bright flash before settling into the rhythm.
--
-- The bar API is the `barWidget.*` table (NOT `widget`). Glyph names are Tabler
-- icon names; an unknown name renders the skull fallback.
-- The companion presence orb (orb.luau, a [[desktop_widget]]) is a pure view:
-- this bar dot mirrors its session rollup to noctalia.state ("claude.pulse", at the
-- end of render below) and the orb subscribes — same state map, two surfaces.

-- ── live palette ─────────────────────────────────────────────────────────────
-- Accent roles follow the global scheme so the dot matches the other bar
-- widgets: `secondary` for the ambient/working states (idle, tool), `primary`
-- for the Claude-active states (thinking/responding/done), `error` for the
-- attention bell + hard errors. Brightness math needs real RGB, so the roles
-- are resolved from the active palette JSON on disk:
--   custom    → $XDG_CONFIG_HOME/noctalia/palettes/<name>.json
--   community → $XDG_STATE_HOME/noctalia/community-palettes/<urlEncode(name)>.json
-- (noctalia.string.urlEncode is the same urlEncode noctalia names the cache
-- file with, so the round-trip is exact.)
-- Builtin + wallpaper-generated palettes have no on-disk JSON (they
-- live in the binary / the generator), so those sources keep the fallback
-- accents below.
local ACCENTS = { secondary = "EAFF00", primary = "B4FF00", error = "FF4D1F" }

local function xdg(env, fallback)
  local v = noctalia.getenv and noctalia.getenv(env)
  if type(v) == "string" and v ~= "" then return v end
  return noctalia.expandPath(fallback)
end

-- Minimal [theme] reader: walk lines, track the section, keep quoted k/v pairs.
-- (Indented subsections like [theme.templates] end the block; their keys are
-- arrays/bools and would not match the quoted-string pattern anyway.)
local function theme_cfg(toml)
  local cfg, in_theme = {}, false
  for line in (toml .. "\n"):gmatch("([^\n]*)\n") do
    local sec = line:match("^%s*%[([^%]]+)%]")
    if sec then
      in_theme = (sec == "theme")
    elseif in_theme then
      local k, v = line:match('^%s*([%w_]+)%s*=%s*"(.-)"')
      if k then cfg[k] = v end
    end
  end
  return cfg
end

local function resolve_accents()
  local toml = noctalia.readFile(xdg("XDG_STATE_HOME", "~/.local/state") .. "/noctalia/settings.toml")
  if type(toml) ~= "string" then return end
  local cfg = theme_cfg(toml)
  local path
  if cfg.source == "custom" and cfg.custom_palette then
    path = xdg("XDG_CONFIG_HOME", "~/.config") .. "/noctalia/palettes/" .. cfg.custom_palette .. ".json"
  elseif cfg.source == "community" and cfg.community_palette then
    path = xdg("XDG_STATE_HOME", "~/.local/state") .. "/noctalia/community-palettes/"
        .. noctalia.string.urlEncode(cfg.community_palette) .. ".json"
  else
    return -- builtin / wallpaper-generated: keep current accents
  end
  local raw = noctalia.readFile(path)
  if type(raw) ~= "string" then return end
  local pal = noctalia.json.decode(raw)
  if type(pal) ~= "table" then return end
  local m = pal[noctalia.isDarkMode() and "dark" or "light"] or pal.dark or pal
  if type(m) ~= "table" then return end
  local function hex(c)
    return type(c) == "string" and c:match("^#(%x%x%x%x%x%x)$") or nil
  end
  ACCENTS.secondary = hex(m.mSecondary) or ACCENTS.secondary
  ACCENTS.primary = hex(m.mPrimary) or ACCENTS.primary
  ACCENTS.error = hex(m.mError) or ACCENTS.error
end

-- ── state map ────────────────────────────────────────────────────────────────
-- `color` names an ACCENTS role; `period` is the breath cycle in seconds —
-- urgency reads as tempo (needs-you breathes fast, idle slow).
local VISUAL = {
  idle            = { glyph = "robot",          color = "secondary", tip = "Claude: idle",                    period = 8.0 },
  turn_start      = { glyph = "brain",          color = "primary",   tip = "Claude: thinking",                period = 5.0 },
  text            = { glyph = "message-dots",   color = "primary",   tip = "Claude: responding",              period = 4.5 },
  tool_start      = { glyph = "tool",           color = "secondary", tip = "Claude: running a tool",          period = 5.0 },
  needs_attention = { glyph = "bell-ringing",   color = "error",     tip = "Claude needs you",                period = 3.0 },
  turn_end        = { glyph = "bell",           color = "primary",   tip = "Claude: done — ready for you",    period = 5.5 },
  error           = { glyph = "alert-triangle", color = "error",     tip = "Claude: error",                   period = 3.5 },
}

-- With several sessions in different states, the bar shows the most urgent one:
-- a session that needs you outranks one merely working, which outranks one idle.
local STATE_PRIO = {
  needs_attention = 6, error = 5, tool_start = 4,
  turn_start = 3, text = 3, turn_end = 2, idle = 1,
}
-- Compact per-session words for the multi-session tooltip.
local STATE_WORD = {
  idle = "idle", turn_start = "thinking", text = "responding",
  tool_start = "tool", needs_attention = "needs you",
  turn_end = "done", error = "error",
}

-- sid -> { sid, state, model, tin, tout, cr, seq }. `seq` is a monotonic counter
-- (no os.time dependency in the widget sandbox) used to order by recency.
local sessions = {}
local seq = 0

-- ── breath ───────────────────────────────────────────────────────────────────
local INTERVAL_MS = 60          -- ~16 fps re-render (bars can't do 60 fps)
local BMIN, BMAX = 0.45, 1.00   -- brightness floor/ceiling the glyph breathes between
local PALETTE_EVERY = 128       -- re-resolve accents every ~7.7 s so theme changes follow

local cur = "idle"              -- most-urgent state across sessions (drives glyph + tempo)
local phase = VISUAL.idle.period / 2  -- breath clock, seconds; born at peak brightness
local ticks = 0
local last_ask = nil           -- last claude.state seen by the quick-ask poll (below)

local function level_for(period) -- raised-cosine brightness in [BMIN, BMAX]
  local t = phase % period
  local s = 0.5 - 0.5 * math.cos((t / period) * 2 * math.pi)
  return BMIN + (BMAX - BMIN) * s
end

-- Scale an "RRGGBB" accent toward black by factor b, returning "#RRGGBB".
local function dimmed(rgb, b)
  local function ch(i)
    local x = math.floor((tonumber(rgb:sub(i, i + 1), 16) or 0) * b + 0.5)
    if x < 0 then x = 0 elseif x > 255 then x = 255 end
    return x
  end
  return string.format("#%02X%02X%02X", ch(1), ch(3), ch(5))
end

local function paint()
  local v = VISUAL[cur] or VISUAL.idle
  barWidget.setGlyphColor(dimmed(ACCENTS[v.color] or ACCENTS.secondary, level_for(v.period)))
end

-- ── session plumbing ─────────────────────────────────────────────────────────
local function split(s, sep)
  local out = {}
  for part in (s .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = part end
  return out
end

local function kfmt(s)
  local n = tonumber(s) or 0
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n))
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

local function burn_line(s)
  local l = string.format("%s · %s in / %s out", s.model, kfmt(s.tin), kfmt(s.tout))
  if (s.cr or 0) > 0 then l = l .. " · " .. kfmt(s.cr) .. " cached" end
  return l
end

local function ordered()
  local arr = {}
  for _, s in pairs(sessions) do arr[#arr + 1] = s end
  table.sort(arr, function(a, b) return (a.seq or 0) > (b.seq or 0) end)
  return arr
end

local function render()
  local arr = ordered()
  local count = #arr

  local best, bestp = "idle", 0
  for _, s in ipairs(arr) do
    local p = STATE_PRIO[s.state] or 0
    if p > bestp then bestp = p; best = s.state end
  end
  if best ~= cur then
    cur = best
    -- snap the breath to its peak so a state change reads as a bright flash
    phase = (VISUAL[cur] or VISUAL.idle).period / 2
  end
  local v = VISUAL[cur] or VISUAL.idle
  barWidget.setGlyph(v.glyph)
  paint()

  local tip
  if count == 0 then
    tip = VISUAL.idle.tip
  elseif count == 1 then
    local s = arr[1]
    local sv = VISUAL[s.state] or VISUAL.idle
    tip = has_burn(s) and (sv.tip .. "\n" .. burn_line(s)) or sv.tip
  else
    local lines = { string.format("Claude — %d sessions", count) }
    local Tin, Tout = 0, 0
    for _, s in ipairs(arr) do
      local line = s.sid .. " · " .. (STATE_WORD[s.state] or s.state)
      if has_burn(s) then
        line = line .. " · " .. s.model .. " " .. kfmt(s.tin) .. "/" .. kfmt(s.tout)
        Tin = Tin + s.tin; Tout = Tout + s.tout
      end
      lines[#lines + 1] = line
    end
    if (Tin + Tout) > 0 then
      lines[#lines + 1] = string.format("Σ %s in / %s out", kfmt(Tin), kfmt(Tout))
    end
    tip = table.concat(lines, "\n")
  end
  barWidget.setTooltip(tip)

  -- Mirror the rollup to shared state so the presence orb (orb.luau, a separate
  -- desktop widget) renders the same status without re-deriving it. The bar dot
  -- stays the single place that aggregates sessions; the orb is a pure subscriber.
  -- Published only here (events), never from the breath timer, so orb watchers
  -- aren't spammed 16×/s. Snapshot carries only what the orb needs: the most-
  -- urgent state, the session count, and burn totals (single-session figures
  -- when count==1, the sum when >1).
  local snap = { state = best, count = count, model = "?", tin = 0, tout = 0, cr = 0 }
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

-- launcher quick-ask path (no session id, no telemetry). Ephemeral: shown while
-- streaming, dropped when it finishes — the answer is delivered via notify, so a
-- lingering "done" would only inflate the session count.
--
-- POLLED, not watched: bar widgets don't fire noctalia.state.watch callbacks in
-- v5 (D8 / README "Rough edges"), so update() reads claude.state each tick the
-- same way it re-reads the palette. Only a *change* touches the session table and
-- re-renders, so a steady state costs a single state.get and nothing more.
local function poll_ask()
  local s = noctalia.state.get and noctalia.state.get("claude.state")
  if type(s) ~= "string" then s = nil end
  if s == last_ask then return end
  last_ask = s
  if s == nil or s == "turn_end" or s == "error" then
    sessions["ask"] = nil
  else
    touch("ask", s, nil)
  end
  render()
end

-- hook reflex path: per-session state + token telemetry, full lifecycle. The
-- dispatcher always tags the event with a session id; `session_end` (the Claude
-- Code SessionEnd hook) retires the session so stale entries never accumulate.
--
-- A payload-less event carries no session id (real hook events always do) — only a
-- manual `noctalia msg … :pulse all <event>` poke from the CLI does. Those land in a
-- single "default" test slot. To keep such a poke from leaving a sticky phantom
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
  render()
end

-- Click the dot to show the answer panel — the full-length surface for /claude ?
-- quick-ask answers (the toast only carries a preview; claude.luau publishes the
-- complete text to "claude.answer" and answer.luau renders it scrollable).
-- panel-OPEN, not -toggle: open is idempotent, so it survives the click handler
-- firing more than once per click (a toggle nets out to closed again — click
-- appeared dead in live testing). Dismiss is click-outside/Esc, panel idiom.
function onClick()
  if not noctalia.runAsync("noctalia msg panel-open 'lowcache/claude-companion:answer'") then
    noctalia.notifyError("pulse", "could not launch the answer panel")
  end
end

-- Breath timer. Re-arm the interval each tick (the pattern proven live in the
-- barpulse prototype), advance the clock, repaint the glyph brightness only —
-- glyph/tooltip/rollup are event-driven in render().
function update()
  noctalia.setUpdateInterval(INTERVAL_MS)
  phase = phase + INTERVAL_MS / 1000
  if phase > 1e6 then phase = 0 end
  ticks = ticks + 1
  if ticks % PALETTE_EVERY == 0 then resolve_accents() end
  poll_ask()  -- surface quick-ask state changes (bar widgets can't watch)
  paint()
end

resolve_accents()
noctalia.setUpdateInterval(INTERVAL_MS)
render()
