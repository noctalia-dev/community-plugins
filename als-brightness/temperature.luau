--!nonstrict
-- The night-light temperature WRITE PATH: when to apply a runtime temperature
-- override via `noctalia.nightlight`, and how the night-light watch enforces it.
--
-- Not the temperature curve: the mapping (ambient K -> panel K) is
-- `curve_temperature`, built by curve_source.luau and evaluated by
-- adaptation.decide(). This module owns the write side only -- the "should we
-- apply a new temperature now" gate (should_apply), the runtime apply path
-- (apply_path), and the watch reconciler (reconcile_watch).
--
-- Shape, like hardware.discover() and adaptation.decide(): explicit state and an
-- injected environment in, an ordered action list out. Everything here is pure
-- -- the IO is injected (nightlight_state / set_enabled / set_temperature), so
-- the whole write path runs under a bare `luau`.
--
--   actions = temperature.apply_path(state, kelvin, now_s, env)
--   actions = temperature.reconcile_watch(state, nl_state, active, env)
--   worth   = temperature.should_apply(state, target_k, now_s, cfg)
--
--   state  the applied-K bookkeeping, explicit data:
--            applied_k    integer kelvin last applied (number|nil)
--            last_temp_s  that write's time in SECONDS (number|nil)
--   env    the injected IO:
--            nightlight_state()         -> table|nil
--            set_enabled(enabled: bool) -> nothing
--            set_temperature(k: int?)   -> nothing

local M = {}

local function import(name)
  local ok, mod = pcall(require, "./" .. name .. ".luau")
  if not ok then
    mod = require("./" .. name)
  end
  return mod
end

local colortemp = import("colortemp")

--- Should we apply a new temperature override now?
function M.should_apply(state, target_k, now_s, cfg)
  state = state or {}
  return colortemp.should_apply(state.applied_k, target_k, state.last_temp_s, now_s, cfg)
end

--- Apply a runtime temperature override through Noctalia's night-light API.
---
--- `noctalia.nightlight.setTemperature()` requires an integer in 1000..10000
--- and only tints while night light is enabled; `setEnabled(true)` clears any
--- active override, so it is always called first when night light is off.
function M.apply_path(state, kelvin, now_s, env)
  local actions = {}
  local nl = env.nightlight_state and env.nightlight_state() or nil
  if nl == nil then
    actions[#actions + 1] = {
      kind = "warn_once", key = "nightlight-unavailable",
      line = "colortemp skipped: noctalia.nightlight.state() unavailable",
    }
    return actions
  end

  local target = math.floor(kelvin + 0.5)
  state.applied_k = target
  state.last_temp_s = now_s
  if not nl.enabled then
    env.set_enabled(true)
  end
  env.set_temperature(target)

  actions[#actions + 1] = { kind = "log", line = string.format("colortemp: applied %dK", target) }
  return actions
end

--- Enforce night-light enabled + `state.applied_k` from `noctalia.nightlight.watch()`.
---
--- Loop-safe: only calls `set_enabled(true)` when `nl_state.enabled` is false,
--- and only calls `set_temperature(applied_k)` when `temperatureOverride` differs
--- from `state.applied_k`. Does nothing when inactive or before the first apply.
function M.reconcile_watch(state, nl_state, active, env)
  local actions = {}
  if not active or state == nil or state.applied_k == nil or nl_state == nil then
    return actions
  end

  local target = state.applied_k
  if not nl_state.enabled then
    env.set_enabled(true)
    env.set_temperature(target)
    actions[#actions + 1] = {
      kind = "log",
      line = string.format("colortemp: re-enabled night light at %dK", target),
    }
  elseif nl_state.temperatureOverride ~= target then
    env.set_temperature(target)
    actions[#actions + 1] = {
      kind = "log",
      line = string.format("colortemp: restored override %dK", target),
    }
  end
  return actions
end

return M
