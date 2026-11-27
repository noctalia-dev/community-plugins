--!nonstrict
-- Ambient colour temperature -> panel warmth, via Noctalia's native night-light
-- runtime API (`noctalia.nightlight.setTemperature`).
--
-- Driving Noctalia's own GammaService keeps a single writer of
-- zwlr_gamma_control_v1 (two writers would fight over the same LUT) without
-- touching settings.toml, triggering config-reload, or popping an OSD.
--
-- The panel CCT tracks the ambient CCT via the user's `curve_temperature`
-- setting (evaluated by curve.luau). It is deliberately not a night-light
-- *schedule* (that is what Noctalia already does); this reacts to the light in
-- the room.

local M = {}

M.MAP_DEFAULTS = {
  -- The mapping itself is the `curve_temperature` setting, evaluated by
  -- curve.luau.
  min_k = 2500,
  max_k = 6500,

  -- Only upload a new LUT when the target moves at least this far, and never
  -- more often than this. Matches Noctalia's own 50 K perceptual step while
  -- avoiding unnecessary compositor stalls.
  step_k = 50,
  min_interval_s = 10,
}

--- Clamp a panel temperature into the range this display can actually use.
-- The curve supplies the shape; the clamp is the guard rail, and it stays here
-- rather than in the curve so that an over-eager node cannot command a
-- temperature the panel has no gamma table for.
function M.clamp_k(value, cfg)
  cfg = cfg or M.MAP_DEFAULTS
  if value == nil then return nil end
  if value < cfg.min_k then return cfg.min_k end
  if value > cfg.max_k then return cfg.max_k end
  return value
end

--- Worth applying a new temperature override?
function M.should_apply(applied_k, target_k, last_applied_s, now_s, cfg)
  cfg = cfg or M.MAP_DEFAULTS
  if applied_k == nil then return true end
  if math.abs(target_k - applied_k) < cfg.step_k then return false end
  if last_applied_s ~= nil and (now_s - last_applied_s) < cfg.min_interval_s then
    return false
  end
  return true
end

return M
