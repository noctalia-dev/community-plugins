--!nonstrict
-- The spawn policy: when may the service start a face-watch episode?
--
-- Pure decision over injected inputs -- no IO, no clock reads of its own -- so
-- the whole policy runs under a bare `luau` in tests/policy.test.luau.
--
--   ok, reason = policy.decide(state, cfg, observed)
--
--   state    { last_start_ms }  bookkeeping the caller owns (mutated on allow)
--   cfg      enabled / cooldown_s  (wrong types fall back to DEFAULTS)
--   observed { locked, episode_running }  current reality (bool|nil)
--
-- Rules, in order:
--   * master switch off           -> "disabled"
--   * session locked              -> "locked"     (never capture on a lockscreen)
--   * a check is already live  -> "running"    (one check at a time)
--   * inside the cooldown window  -> "cooldown"   (power cap on camera wake-ups)
--   * otherwise                   -> allow

local M = {}

M.DEFAULTS = {
  enabled = true,
  -- Minimum seconds between episode starts. Bounds camera+CPU wake-ups even if
  -- Noctalia fires idle-begin faster than the idle chain can cancel itself.
  cooldown_s = 10,
}

local function is_finite(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function number_setting(cfg, key)
  local value = cfg[key]
  if is_finite(value) then return value end
  return M.DEFAULTS[key]
end

--- Decide whether a new episode may start. Mutates state.last_start_ms on allow.
function M.decide(state, cfg, observed)
  state = state or {}
  cfg = cfg or {}
  observed = observed or {}

  local enabled = cfg.enabled
  if type(enabled) ~= "boolean" then enabled = M.DEFAULTS.enabled end
  if not enabled then
    return false, "disabled"
  end

  if observed.locked then
    return false, "locked"
  end

  if observed.episode_running then
    return false, "running"
  end

  local now_ms = observed.now_ms
  local last = state.last_start_ms
  local cooldown_ms = number_setting(cfg, "cooldown_s") * 1000
  if is_finite(now_ms) and is_finite(last) and (now_ms - last) < cooldown_ms then
    return false, "cooldown"
  end

  if is_finite(now_ms) then
    state.last_start_ms = now_ms
  end
  return true, "ok"
end

return M
