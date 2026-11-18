-- EXPERIMENTAL — prototyping always-visible bar-widget animation, since the desktop
-- orb only shows on bare desktop. The real pulse.luau bar is UNTOUCHED; this is a
-- throwaway comparison surface. The winning behaviour gets folded into pulse.luau.
--
-- Bar plugin widgets have NO per-frame tick (that's desktop-only) — they re-render on
-- a timer via noctalia.setUpdateInterval(ms) + a global update(). The only animatable
-- channel is the glyph colour. Rather than alpha (the bar didn't honour 8-digit
-- #RRGGBBAA), we breathe BRIGHTNESS: scale the accent RGB toward black (the near-black
-- surface) and emit a plain 6-digit "#RRGGBB" so the glyph glows brighter/dimmer while
-- keeping its hue. Two waveforms to compare by eye:
--   MODE "A"  raised-cosine sine breath  (smooth glow, like the orb)
--   MODE "B"  square wave                (discrete blink)
--
-- It reads state from the same claude.pulse rollup pulse.luau publishes (so it needs none
-- of the session bookkeeping). Flip MODE + reload to compare.
--
-- State RGB is hardcoded from the active dark palette (volnix:
-- mSecondary/mPrimary/mError) to validate the look fast.

local MODE = "A"          -- "A" sine breath | "B" square blink
local INTERVAL_MS = 60    -- ~16 fps re-render (bars can't do 60 fps)
local BMIN, BMAX = 0.45, 1.00   -- brightness floor/ceiling the glyph breathes between

-- glyph + accent RGB (hex, no #) per state — same glyph/role map as the bar dot/orb.
local VISUAL = {
  idle            = { glyph = "robot",          rgb = "EAFF00", period = 8.0 },
  turn_start      = { glyph = "brain",          rgb = "B4FF00", period = 5.0 },
  text            = { glyph = "message-dots",   rgb = "B4FF00", period = 4.5 },
  tool_start      = { glyph = "tool",           rgb = "EAFF00", period = 5.0 },
  needs_attention = { glyph = "bell-ringing",   rgb = "FF4D1F", period = 3.0 },
  turn_end        = { glyph = "bell",           rgb = "B4FF00", period = 5.5 },
  error           = { glyph = "alert-triangle", rgb = "FF4D1F", period = 3.5 },
}

local state = "idle"
local phase = 0.0

local function level_for(v)            -- brightness scale in [BMIN, BMAX]
  local t = phase % v.period
  if MODE == "B" then
    return (t < v.period * 0.5) and BMAX or BMIN    -- bright for the first half, dim for the second
  end
  local s = 0.5 - 0.5 * math.cos((t / v.period) * 2 * math.pi)
  return BMIN + (BMAX - BMIN) * s
end

-- Scale an "RRGGBB" accent toward black by factor b, returning "#RRGGBB".
local function dim(rgb, b)
  local function ch(i)
    local x = math.floor((tonumber(rgb:sub(i, i + 1), 16) or 0) * b + 0.5)
    if x < 0 then x = 0 elseif x > 255 then x = 255 end
    return x
  end
  return string.format("#%02X%02X%02X", ch(1), ch(3), ch(5))
end

local function paint()
  local v = VISUAL[state] or VISUAL.idle
  barWidget.setGlyph(v.glyph)
  barWidget.setGlyphColor(dim(v.rgb, level_for(v)))
  barWidget.setTooltip(string.format("barpulse [%s] · %s", MODE, state))
end

-- Pull the most-urgent state from the bar pulse's published rollup. Bar widgets don't
-- seem to receive noctalia.state.watch callbacks (the desktop orb does; this bar one
-- did not), so we POLL noctalia.state.get each tick instead — cheap, and the timer is
-- already running. Only adopt a recognised state so a nil/garbage read can't blank it.
local function refresh_state()
  local snap = noctalia.state.get and noctalia.state.get("claude.pulse")
  if type(snap) == "table" and type(snap.state) == "string" and VISUAL[snap.state] then
    state = snap.state
  elseif type(snap) == "string" and VISUAL[snap] then
    state = snap
  end
end

-- Timer loop. Re-arm the interval each tick (mirrors the scratchpad pattern), refresh
-- the state by polling, and advance the breath by the known step (no dt on bar widgets).
function update()
  noctalia.setUpdateInterval(INTERVAL_MS)
  refresh_state()
  phase = phase + INTERVAL_MS / 1000
  if phase > 1e6 then phase = 0 end
  paint()
end

refresh_state()
noctalia.setUpdateInterval(INTERVAL_MS)
paint()
