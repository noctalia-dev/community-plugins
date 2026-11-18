--!nonstrict
-- The night-light temperature WRITE PATH: when to splice Noctalia's colortemp
-- config, and what each splice attempt does to the applied-K bookkeeping.
--
-- Not the temperature curve: the mapping (ambient K -> panel K) is
-- `curve_temperature`, built by curve_source.luau and evaluated by
-- adaptation.decide(). This module owns the write side only -- the "should we
-- splice the colortemp config now" gate (should_apply) and the splice run
-- itself (write_path).
--
-- Before this module, the applied_k / last_temp_s bookkeeping was spread across
-- the return paths of service.apply_temperature: each path decided by hand
-- whether the attempt counted as "applied", and a path that forgot to record
-- (or recorded on a failure) would make the service re-splice forever or stop
-- splicing at all. write_path() is now the ONE function where every exit path
-- that skips or performs a splice is visible, and it is the only writer of
-- state.applied_k / state.last_temp_s. The write cadence that decides how often
-- a splice may happen at all (docs/DESIGN.md section 6.1) stays the gate's.
--
-- Shape, like hardware.discover() and adaptation.decide(): explicit state and an
-- injected environment in, an ordered action list out. Everything here is pure
-- -- the IO is injected (read_file / write_file / rename / reload), so the whole
-- write path runs under a bare `luau` in tests/temperature.test.luau.
--
--   actions = temperature.write_path(state, kelvin, now_s, env)
--   worth   = temperature.should_apply(state, target_k, now_s, cfg)
--
--   state  the applied-K bookkeeping, explicit data:
--            applied_k    kelvin last written (number|nil)
--            last_temp_s  that write's time in SECONDS (number|nil)
--   env    the injected IO (the same idea as hardware's env):
--            settings_path      Noctalia's settings.toml (nil = degraded probe)
--            read_file(path)    -> text|nil
--            write_file(path, text) -> boolean
--            rename(from, to)   -> boolean
--            reload()           ask Noctalia to re-read its config
--
-- Return: the ordered action list for the executor (service.perform):
--   {kind="log",      line}                 append to the log ring
--   {kind="warn_once", key, line}           log once per run
-- Every line is byte-identical to the line service.luau used to write at the
-- same point -- they are the maintainer's evidence stream.

local M = {}

-- Require resolution differs between the two environments this file runs in:
-- the Noctalia host resolves "./colortemp.luau" (with the extension) while the
-- standalone luau resolves "./colortemp" (without) and rejects the extension
-- form. Try the host form first, fall back to the interpreter form (same as
-- adaptation.luau).
local function import(name)
  local ok, mod = pcall(require, "./" .. name .. ".luau")
  if not ok then
    mod = require("./" .. name)
  end
  return mod
end

local colortemp = import("colortemp")

--- Should we splice the colortemp config now? The gate, with the applied-K
--- state explicit: worth rewriting when the target moved at least step_k from
--- the last applied value, and at most once per min_interval_s. The thresholds
--- are colortemp's guard rails (pinned in tests/colortemp.test.luau); this is
--- the state wiring -- where applied_k and last_temp_s are read.
function M.should_apply(state, target_k, now_s, cfg)
  state = state or {}
  return colortemp.should_apply(state.applied_k, target_k, state.last_temp_s, now_s, cfg)
end

--- Run one splice attempt and report what happened to the bookkeeping. The
--- write path's exit paths, in ONE function:
---
---   "no-settings-path"  the probe never found settings.toml (HOME unset):
---                       skip, warn once, never guess a path
---   "unreadable"        settings.toml could not be read: skip, log
---   "unchanged"         the config already holds the target: no write, but
---                       the target IS recorded as applied, so the gate stops
---                       reconsidering until the ambient moves
---   "tmp-write-failed"  the sibling tmp file could not be written: skip, log
---   "replace-failed"    the rename over settings.toml failed: skip, log
---   "applied"           spliced, replaced, config-reload asked for: record
---                       and log
---
--- Only "unchanged" and "applied" record; every other path leaves the
--- bookkeeping untouched so the gate reconsiders on its own cadence. That
--- asymmetry is the historical bug surface -- tests/temperature.test.luau has
--- one named test per path.
function M.write_path(state, kelvin, now_s, env)
  local actions = {}
  local settings_path = env.settings_path
  if settings_path == nil then
    -- Degraded at the probe (HOME unset): skip, and never guess a path.
    actions[#actions + 1] = {
      kind = "warn_once", key = "settings-path",
      line = "colortemp skipped: no settings path (HOME unset)",
    }
    return actions
  end

  local text = env.read_file(settings_path)
  if text == nil then
    actions[#actions + 1] = { kind = "log", line = "colortemp: cannot read " .. settings_path }
    return actions
  end

  local new_text, changed = colortemp.splice(text, kelvin)
  if not changed then
    -- Already correct; record it so we stop reconsidering until the ambient moves.
    state.applied_k = kelvin
    state.last_temp_s = now_s
    return actions
  end

  local tmp = settings_path .. ".als-brightness.tmp"
  if not env.write_file(tmp, new_text) then
    actions[#actions + 1] = { kind = "log", line = "colortemp: cannot write " .. tmp }
    return actions
  end
  if not env.rename(tmp, settings_path) then
    actions[#actions + 1] = { kind = "log", line = "colortemp: cannot replace " .. settings_path }
    return actions
  end

  -- The edit is an atomic replace (write a sibling, rename over the target), so
  -- Noctalia's own inotify sees one IN_MOVED_TO; the explicit config-reload is
  -- belt-and-braces (docs/DESIGN.md section 6.1). It is asked for before the
  -- line is logged, exactly as the old service path did it.
  env.reload()
  state.applied_k = kelvin
  state.last_temp_s = now_s
  actions[#actions + 1] = { kind = "log", line = string.format("colortemp: applied %dK", math.floor(kelvin)) }
  return actions
end

return M
