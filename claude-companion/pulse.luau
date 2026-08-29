-- The attention pulse (bar widget) — a glanceable live readout of Claude across all
-- active sessions. This is the VIEW half of the pulse: a pure subscriber. The
-- aggregator (pulse-svc.luau, a headless [[service]]) owns all session bookkeeping and
-- publishes a rollup to noctalia.state ("claude.pulse"); this widget watches that key
-- and reflects it in the bar — a glyph (Tabler icon name; an unknown name renders the
-- skull fallback) whose accent color breathes a raised-cosine BRIGHTNESS glow (the bar
-- ignores 8-digit #RRGGBBAA alpha, but a 6-digit #RRGGBB scaled toward black reads as a
-- glow). Discrete state (glyph/tooltip) renders on each snapshot; the 60 ms timer only
-- advances the breath. A state change snaps the breath to its peak, so transitions read
-- as a bright flash before settling into the rhythm.
--
-- The companion presence orb (orb.luau, a [[desktop_widget]]) subscribes to the same
-- "claude.pulse" key: one source of truth (the service), the bar dot and the orb are
-- two views of it. Bar widgets DO receive noctalia.state.watch callbacks as of the
-- Noctalia 5 beta (the old "bars must poll" workaround is gone). The bar API is the
-- `barWidget.*` table (NOT `widget`).

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

local function tr(key, args) return noctalia.tr(key, args) end

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
  idle            = { glyph = "robot",          color = "secondary", tip = "state.tip.idle",                    period = 8.0 },
  turn_start      = { glyph = "brain",          color = "primary",   tip = "state.tip.turn_start",              period = 5.0 },
  text            = { glyph = "message-dots",   color = "primary",   tip = "state.tip.text",                    period = 4.5 },
  tool_start      = { glyph = "tool",           color = "secondary", tip = "state.tip.tool_start",              period = 5.0 },
  needs_attention = { glyph = "bell-ringing",   color = "error",     tip = "state.tip.needs_attention",         period = 3.0 },
  turn_end        = { glyph = "bell",           color = "primary",   tip = "state.tip.turn_end",                period = 5.5 },
  error           = { glyph = "alert-triangle", color = "error",     tip = "state.tip.error",                   period = 3.5 },
}

-- Compact per-session words for the multi-session tooltip (Stage 2, once the
-- rollup carries a per-session list).
local STATE_WORD = {
  idle = "state.word.idle", turn_start = "state.word.turn_start", text = "state.word.text",
  tool_start = "state.word.tool_start", needs_attention = "state.word.needs_attention",
  turn_end = "state.word.turn_end", error = "state.word.error",
}

-- ── breath ───────────────────────────────────────────────────────────────────
local INTERVAL_MS = 60          -- ~16 fps re-render (bars can't do 60 fps)
local BMIN, BMAX = 0.45, 1.00   -- brightness floor/ceiling the glyph breathes between
local PALETTE_EVERY = 128       -- re-resolve accents every ~7.7 s so theme changes follow
local SETTINGS_EVERY = 16       -- re-read user settings ~1 s so slider drags apply promptly

-- Latest rollup from the aggregator (pulse-svc), received via state.watch. `cur`
-- tracks the state currently driving the glyph + tempo so a change can snap the breath.
local snap = { state = "idle", count = 0, model = "?", tin = 0, tout = 0, cr = 0 }
local cur = "idle"
local phase = VISUAL.idle.period / 2  -- breath clock, seconds; born at peak brightness
local ticks = 0
local breath_speed = 1.0  -- user setting (breath_speed): phase-rate multiplier
local glow_floor = BMIN   -- user setting (pulse_glow_floor): brightness floor at the breath trough

-- Re-read user settings (cheap; called at load + periodically from update()).
local function read_settings()
  local v = noctalia.getConfig and noctalia.getConfig("breath_speed")
  if type(v) == "number" and v > 0 then breath_speed = v end
  local g = noctalia.getConfig and noctalia.getConfig("pulse_glow_floor")
  if type(g) == "number" and g >= 0 and g < BMAX then glow_floor = g end
end

local function level_for(period) -- raised-cosine brightness in [glow_floor, BMAX]
  local t = phase % period
  local s = 0.5 - 0.5 * math.cos((t / period) * 2 * math.pi)
  return glow_floor + (BMAX - glow_floor) * s
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

-- ── tooltip helpers ──────────────────────────────────────────────────────────
local function kfmt(s)
  local n = tonumber(s) or 0
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n))
end

local function has_burn(s)
  return s.model and s.model ~= "?" and ((s.tin or 0) + (s.tout or 0)) > 0
end

local function burn_line(s)
  local l = tr("pulse.burn", { model = s.model, tin = kfmt(s.tin), tout = kfmt(s.tout) })
  if (s.cr or 0) > 0 then l = l .. " · " .. tr("pulse.cached", { n = kfmt(s.cr) }) end
  return l
end

-- ── render (pure view of the rollup) ─────────────────────────────────────────
-- Glyph + accent for the most-urgent state, a tooltip, and a breath snapped to peak
-- on a state change. The service is the single aggregator; this only views its rollup.
-- The multi-session tooltip currently shows count + Σ burn; per-session lines return
-- in Stage 2 when the rollup carries a `sessions` list (see STATE_WORD).
local function render()
  if snap.state ~= cur then
    cur = snap.state
    phase = (VISUAL[cur] or VISUAL.idle).period / 2 -- snap the breath to its peak (bright flash)
  end
  local v = VISUAL[cur] or VISUAL.idle
  barWidget.setGlyph(v.glyph)
  paint()

  local tip
  if snap.count == 0 then
    tip = tr(VISUAL.idle.tip)
  elseif snap.count == 1 then
    tip = has_burn(snap) and (tr(v.tip) .. "\n" .. burn_line(snap)) or tr(v.tip)
  else
    -- A thin rule separates each session so concurrent sessions read as distinct
    -- blocks rather than one wall of text (fixed width; tooltip font is proportional
    -- so it reads as a divider, not a measured column).
    local DIV = "──────────────"
    local lines = { tr("pulse.sessions_header", { count = snap.count }) }
    local Tin, Tout = 0, 0
    for i, s in ipairs(snap.sessions) do
      if i > 1 then lines[#lines + 1] = DIV end
      local sw = STATE_WORD[s.state] and tr(STATE_WORD[s.state]) or s.state
      local line = s.sid .. " · " .. sw
      if has_burn(s) then
        line = line .. " · " .. s.model .. " " .. kfmt(s.tin) .. "/" .. kfmt(s.tout)
        Tin = Tin + s.tin; Tout = Tout + s.tout
      end
      lines[#lines + 1] = line
    end
    -- fallback to the rollup's Σ figures if no per-session list was published
    if #snap.sessions == 0 and (snap.tin + snap.tout) > 0 then
      lines[#lines + 1] = DIV
      lines[#lines + 1] = tr("pulse.total", { tin = kfmt(snap.tin), tout = kfmt(snap.tout) })
    elseif (Tin + Tout) > 0 then
      lines[#lines + 1] = DIV
      lines[#lines + 1] = tr("pulse.total", { tin = kfmt(Tin), tout = kfmt(Tout) })
    end
    tip = table.concat(lines, "\n")
  end
  barWidget.setTooltip(tip)
end

-- Normalize + adopt a "claude.pulse" snapshot, then render. Defensive against a
-- malformed or partial payload (state store round-trips values as JSON). The
-- `sessions` array (v2) feeds the multi-session tooltip; older publishers omit it.
local function apply(s)
  if type(s) ~= "table" then return end
  local sess = {}
  if type(s.sessions) == "table" then
    for i, e in ipairs(s.sessions) do
      if type(e) == "table" then
        sess[i] = {
          sid = tostring(e.sid or "?"),
          state = type(e.state) == "string" and e.state or "idle",
          model = (type(e.model) == "string" and e.model ~= "") and e.model or "?",
          tin = tonumber(e.tin) or 0, tout = tonumber(e.tout) or 0, cr = tonumber(e.cr) or 0,
        }
      end
    end
  end
  snap = {
    state = (type(s.state) == "string" and VISUAL[s.state]) and s.state or "idle",
    count = tonumber(s.count) or 0,
    model = (type(s.model) == "string" and s.model ~= "") and s.model or "?",
    tin = tonumber(s.tin) or 0,
    tout = tonumber(s.tout) or 0,
    cr = tonumber(s.cr) or 0,
    sessions = sess,
  }
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
    noctalia.notifyError(tr("pulse.title"), tr("pulse.panel_launch_failed"))
  end
end

-- Right-click opens the sessions panel: the tooltip already lists concurrent
-- sessions, but you cannot act on a tooltip — it disappears on the way to it. Same
-- panel-open (not -toggle) reasoning as onClick above. onRightClick needs no
-- plugin_api bump: the dispatch in plugin_widget.cpp is ungated (the level-14
-- gate covers the DECLARATIVE `actions` manifest table, not these globals).
function onRightClick()
  if not noctalia.runAsync("noctalia msg panel-open 'lowcache/claude-companion:sessions'") then
    noctalia.notifyError(tr("pulse.title"), tr("pulse.panel_launch_failed"))
  end
end

-- Middle-click opens the ask panel. Quick-ask was only reachable as `/claude ? …`,
-- which meant opening the launcher, typing a prefix and remembering the `?` — a lot
-- of ceremony for the lightest thing here, and the reason the feature went unused.
-- Same panel-open (not -toggle) reasoning as onClick above. Left is the answer,
-- right is sessions, middle was free.
function onMiddleClick()
  if not noctalia.runAsync("noctalia msg panel-open 'lowcache/claude-companion:ask'") then
    noctalia.notifyError(tr("pulse.title"), tr("pulse.panel_launch_failed"))
  end
end

-- Breath timer. Re-arm the interval each tick (the pattern proven live in the
-- barpulse prototype), advance the clock, repaint the glyph brightness only —
-- glyph/tooltip are event-driven in render() (fired from the state.watch below).
function update()
  noctalia.setUpdateInterval(INTERVAL_MS)
  phase = phase + INTERVAL_MS / 1000 * breath_speed
  if phase > 1e6 then phase = 0 end
  ticks = ticks + 1
  if ticks % PALETTE_EVERY == 0 then resolve_accents() end
  if ticks % SETTINGS_EVERY == 0 then read_settings() end
  paint()
end

-- Subscribe to the aggregator's rollup, seed from any snapshot already published
-- before we subscribed (the service publishes at launch), then paint an initial
-- frame even if nothing has reported yet (defaults to idle).
noctalia.state.watch("claude.pulse", apply)
resolve_accents()
read_settings()
noctalia.setUpdateInterval(INTERVAL_MS)
apply(noctalia.state.get and noctalia.state.get("claude.pulse"))
render()
