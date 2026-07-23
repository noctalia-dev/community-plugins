-- The presence orb (desktop widget) — the ambient "wow" half of the attention
-- pulse. Where the bar dot is a small static glyph, the orb is the SAME state icon
-- blown up on the desktop, magnifying in and out like a "bat signal": calm and slow
-- at idle, quick and insistent when Claude needs you.
--
-- It is a pure VIEW. pulse.luau already rolls all sessions up for the bar dot and
-- now mirrors that rollup into noctalia.state ("claude.pulse"); the orb just subscribes
-- and animates. No hook, IPC, or session bookkeeping lives here — one source of
-- truth (the bar pulse), two surfaces (bar dot + desktop orb).
--
-- Unlike the bar dot's DISCRETE glyph/color, the orb does PER-FRAME motion:
-- desktopWidget.setNeedsFrameTick(true) asks the host for onFrameTick(dt) callbacks
-- (dt = seconds since last frame); a raised-cosine "breath" drives the glyph's size
-- (the magnification) and opacity together. Breath speed/depth come from the state,
-- so the motion itself carries meaning. We keep ticking a slow idle breath even with
-- no sessions — ambient presence is the whole point of the orb.
--
-- API surface (verified against the noctalia 5.0.0 binary — no source ships; props
-- read from the ui reconciler's BoxProps/applyProps tables):
--   desktopWidget.render(tree)            -- declarative ui.* tree
--   desktopWidget.setNeedsFrameTick(bool) -- opt into onFrameTick(dt)
--   ui.glyph{ name,size,color,opacity,width,height }  ui.column/row  ui.label{ text,
--     fontSize,color,maxWidth,maxLines,textAlign }   noctalia.state.watch(key, cb)
-- NB: ui.box is a LEAF (RectNode) — it draws no children, its fill prop is `fill`
-- (not color/backgroundColor) and its soft glow is `softness`; there is no overlay
-- control, which is why the orb is a magnifying glyph rather than a glyph-on-disc.
-- Colors are the global scheme accents (secondary/primary/error) — same map as the
-- bar dot. See pulse.luau for the shared state→visual map.

-- Per-state look + motion. `color` is the accent the icon is drawn in; `glyph` is the
-- Tabler icon (same one the bar dot shows). `period` = seconds per full breath;
-- `omin`/`omax` = opacity bounds. Faster + deeper = more urgent. `word` labels it.
-- Slow, glowing breath — NOT a strobe. Periods are multi-second (a human breath is
-- ~4s), opacity floors stay high so the icon glows down rather than blinking to dark,
-- and the size swing (below) is gentle. Urgency reads as a *faster, deeper* breath,
-- but even "needs you" stays a breath, never a flicker.
-- User-facing display strings live in translations/<lang>.json; the per-state
-- status word is keyed by state name ("state.orb.<state>") and resolved at render
-- time. cur.state is always a known state (the watch below maps anything else to
-- "idle"), so no fallback guard is needed here.
local function tr(key, args) return noctalia.tr(key, args) end
local function orb_word(state) return tr("state.orb." .. state) end

local VISUAL = {
  idle            = { glyph = "robot",          color = "secondary", period = 11.0, omin = 0.45, omax = 0.80 },
  turn_start      = { glyph = "brain",          color = "primary",   period = 7.5,  omin = 0.55, omax = 1.00 },
  text            = { glyph = "message-dots",   color = "primary",   period = 7.0,  omin = 0.58, omax = 1.00 },
  tool_start      = { glyph = "tool",           color = "secondary", period = 7.5,  omin = 0.55, omax = 1.00 },
  needs_attention = { glyph = "bell-ringing",   color = "error",     period = 4.5,  omin = 0.55, omax = 1.00 },
  turn_end        = { glyph = "bell",           color = "primary",   period = 8.0,  omin = 0.55, omax = 0.95 },
  error           = { glyph = "alert-triangle", color = "error",     period = 5.0,  omin = 0.55, omax = 1.00 },
}

-- The orb IS the bar icon, swelling gently in and out — a desktop "bat signal". The
-- glyph size eases between MIN and MAX with the breath (a soft swell, not a zoom); a
-- fixed BOX reserves space so the swell never nudges the label below it.
local GLYPH_MIN = 70
local GLYPH_MAX = 75
local GLYPH_BOX = 84

-- Live status mirrored from the bar pulse. `count` 0 means no active sessions.
local cur = { state = "idle", count = 0, model = "?", tin = 0, tout = 0 }
local phase = 0.0     -- breath phase accumulator (seconds), wrapped per period

local function kfmt(n)
  n = tonumber(n) or 0
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n))
end

-- 0..1..0 over one period (raised cosine): 0 at phase 0, 1 at half period.
local function breath()
  local v = VISUAL[cur.state] or VISUAL.idle
  local s = 0.5 - 0.5 * math.cos((phase / v.period) * 2 * math.pi)
  return v, s
end

-- One compact status line under the orb. Kept short so it doesn't get clipped by a
-- narrow widget box: just the state word, or a session count, plus burn when there's
-- a single attributable session.
local function subtitle()
  if cur.count > 1 then
    return tr("orb.sessions", { count = cur.count })
  end
  if cur.count == 1 and cur.model ~= "?" and (cur.tin + cur.tout) > 0 then
    return orb_word(cur.state) .. " · " .. kfmt(cur.tin) .. "/" .. kfmt(cur.tout)
  end
  return orb_word(cur.state)
end

local function render()
  local v, s = breath()
  local opacity = v.omin + (v.omax - v.omin) * s
  local size = GLYPH_MIN + (GLYPH_MAX - GLYPH_MIN) * s -- the magnification swing

  desktopWidget.render(ui.column({ gap = 6, padding = 12, align = "center" }, {
    -- The "bat signal": the state icon itself, magnifying larger/smaller and breathing
    -- opacity in the accent color — the same glyph the bar dot shows for this state.
    -- A fixed width/height reserves the icon's footprint so the pulse doesn't shove
    -- the label as it grows. (ui.glyph can't carry the box's soft `softness` glow, and
    -- there's no overlay control, so the icon pulses crisp rather than haloed.)
    ui.glyph({
      name = v.glyph, size = size, color = v.color, opacity = opacity,
      width = GLYPH_BOX, height = GLYPH_BOX,
    }),
    ui.label({
      text = subtitle(), fontSize = 12, color = "on_surface_variant",
      maxWidth = 180, maxLines = 1, textAlign = "center",
    }),
  }))
end

-- Per-frame breath. `dt` is MILLISECONDS since the last frame (≈16.7 at 60 Hz, ≈6.9
-- at 144 Hz — verified empirically; the host passes real elapsed ms, so dividing by
-- 1000 makes `period` a true wall-clock second count, identical on every monitor).
-- Accumulate into `phase` and wrap at the current state's period so it can't grow
-- unbounded.
function onFrameTick(dt)
  local v = VISUAL[cur.state] or VISUAL.idle
  phase = (phase + (tonumber(dt) or 0) / 1000) % v.period
  render()
end

-- New status from the bar pulse. We don't reset `phase` on state change — the
-- breath glides into the new tempo instead of snapping, which reads calmer.
noctalia.state.watch("claude.pulse", function(snap)
  if type(snap) ~= "table" then return end
  cur.state = (type(snap.state) == "string" and VISUAL[snap.state]) and snap.state or "idle"
  cur.count = tonumber(snap.count) or 0
  cur.model = (type(snap.model) == "string" and snap.model ~= "") and snap.model or "?"
  cur.tin = tonumber(snap.tin) or 0
  cur.tout = tonumber(snap.tout) or 0
  render()
end)

-- Breathe from the first frame, even before any session reports in (idle presence).
desktopWidget.setNeedsFrameTick(true)
render()
