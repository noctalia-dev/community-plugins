--!nonstrict
-- Pure decision logic for ambient-light panel brightness.
--
-- Nothing in this module touches the host API, sysfs or the clock, so the whole
-- thing runs under a bare `luau` interpreter and is exercised by tests/policy.test.luau.
-- als-brightness/service.luau is the only place that reads hardware and talks to Noctalia.
--
-- Every constant below is traceable to a measurement recorded in
-- docs/DESIGN.md and .copilot session files/probe-evidence.md.

local M = {}

local function log_of(raw)
  -- +1 keeps 0 (a fully occluded sensor) out of the -infinity branch. The
  -- occluded floor measured on this machine is 4 raw, but 0 is still possible.
  if raw < 0 then raw = 0 end
  return math.log10(raw + 1)
end

M.log_of = log_of

M.DEFAULTS = {
  -- NOTE: the mapping curve itself is no longer here. Phase 2 moved it into
  -- curve.luau, where it is owned by configuration rather than by constants, so
  -- there is exactly one implementation of the curve. What remains in this module
  -- is the temporal policy, the override window and the guards.

  min_percent = 15,
  max_percent = 100,

  -- Asymmetric stabiliser on the log reading. Rise slowly, fall fast: the sensor
  -- swings +/-10000 raw within a single 50 ms sample and moves 70+ raw
  -- second-to-second under a hand, so a fast loop would pump visibly.
  rise_tau_s = 5.0,
  fall_tau_s = 0.5,

  -- Output shaping.
  dead_band_percent = 1.0,
  slew_percent_per_s = 30.0,

  -- User-override window. The band is Android's idea: a manual change stays
  -- valid only while the lighting is still recognisably what it was, rather
  -- than expiring on a bare timer while the room has not changed at all.
  override_band_low = 0.5,
  override_band_high = 2.0,
  override_timeout_s = 300,
  override_tolerance_percent = 2.0,
}

function M.clamp(value, cfg)
  cfg = cfg or M.DEFAULTS
  if value < cfg.min_percent then return cfg.min_percent end
  if value > cfg.max_percent then return cfg.max_percent end
  return value
end

--- Target panel percent for a *log* sensor reading.
--
--- REMOVED in Phase 2. The curve is now the owner's, parsed and interpolated by
--- curve.luau. policy.percent_for_log was a second implementation of the same
--- idea, and two implementations would drift apart the moment either changed.
--- What is left here is the log transform, which the service still needs in order
--- to hand curve.luau a reading in the same domain as the configured nodes.

--- One asymmetric-EMA step on the log reading. prev may be nil (first sample).
function M.stabilize(prev_log, raw, dt, cfg)
  cfg = cfg or M.DEFAULTS
  local l = log_of(raw)
  if prev_log == nil then return l end
  local tau = (l > prev_log) and cfg.rise_tau_s or cfg.fall_tau_s
  local alpha = dt / (tau + dt)
  if alpha > 1 then alpha = 1 end
  if alpha < 0 then alpha = 0 end
  return prev_log + alpha * (l - prev_log)
end

--- Rate limit on the commanded percent so a step is never jarring.
function M.slew(prev_cmd, target, dt, cfg)
  cfg = cfg or M.DEFAULTS
  if prev_cmd == nil then return target end
  local budget = cfg.slew_percent_per_s * dt
  local delta = target - prev_cmd
  if delta > budget then delta = budget end
  if delta < -budget then delta = -budget end
  return prev_cmd + delta
end

--- True when the commanded value has moved enough to be worth a write.
function M.should_write(last_written, target, cfg)
  cfg = cfg or M.DEFAULTS
  if last_written == nil then return true end
  return math.abs(target - last_written) >= cfg.dead_band_percent
end

--- A change we did not command, beyond tolerance, is a manual change by the user.
function M.is_manual_change(last_written, observed, cfg)
  cfg = cfg or M.DEFAULTS
  if last_written == nil then return false end
  if observed == nil then return false end
  return math.abs(observed - last_written) > cfg.override_tolerance_percent
end

--- Has a recorded override expired? Left the lighting band, or timed out.
-- `now_s` is in SECONDS, matching `override.at` and `cfg.override_timeout_s`.
-- The host clock, `noctalia.nowMs()`, is in MILLISECONDS and must be divided by
-- 1000 by the caller. Mixing the two makes every timeout fire on the first tick
-- -- which is exactly the bug this parameter name exists to prevent.
function M.override_expired(override, raw, now_s, cfg)
  cfg = cfg or M.DEFAULTS
  if override == nil then return true end
  if (now_s - override.at) >= cfg.override_timeout_s then return true end
  local anchor = override.raw or 0
  if anchor <= 0 then return false end
  local ratio = raw / anchor
  return ratio < cfg.override_band_low or ratio > cfg.override_band_high
end

--- May the adapter touch the panel right now?
-- Returns ok, reason. Order is deliberate: the cheapest and most certain
-- signals are checked first, and the reason string is logged so a suspension
-- is always attributable rather than mysterious.
function M.guard(s)
  s = s or {}
  if s.dpms ~= "On" then
    return false, "dpms=" .. tostring(s.dpms)
  end
  if s.lid_closed then return false, "lid_closed" end
  if s.idle_engaged then return false, "idle_engaged" end
  if s.locked then return false, "locked" end
  if s.override_active then return false, "user_override" end
  return true, "ok"
end

--- Percent of max, from the sysfs brightness pair.
function M.percent_of(value, max_value)
  if value == nil or max_value == nil or max_value <= 0 then return nil end
  return (value / max_value) * 100.0
end

return M
