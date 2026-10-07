--!nonstrict
-- The keyboard-backlight policy: two states driven by ambient light.
--
-- Ambient ABOVE the threshold -> keyboard backlight OFF; ambient BELOW -> ON at
-- the dark level. The threshold is curve-anchored: the caller inverts the live
-- panel curve (curve.solve_x at anchor_percent) and passes the answer in as
-- opts.anchor_raw, so the keyboard's dark point tracks the owner's curve rather
-- than a magic lux count. Nothing here reads the curve, the hardware or the
-- clock: like temperature.luau, this is pure decision plus bookkeeping over
-- injected inputs, so the whole policy runs under a bare `luau` in
-- tests/keyboard.test.luau.
--
--   actions = keyboard.decide(state, observed, cfg, opts)
--
--   state     the caller-owned `state.kbd` bookkeeping (mutated in place):
--               mode      "light" | "dark" | nil -- the state WE are enforcing
--               cmd_raw   raw level of our last command, or the adopted
--                         sysfs readback (number|nil)
--               inhibit   auto-adaptation held off after a manual change
--               changes   manual-change instants in SECONDS inside the window
--               scale     learned threshold multiplier (default 1.0)
--   observed  the IO snapshot the decision reads:
--               log      stabilised log10(raw + 1) reading (policy.log_of
--                        domain) or nil
--               raw      ambient raw counts at this instant, or nil
--               kbd_raw  sysfs readback of the keyboard-backlight raw level,
--                        or nil
--               idle, locked        session state (bool)
--               guards   {dpms=, lid_closed=} -- hardware.guard_state output
--   cfg       enabled / anchor_percent / buffer_percent / dark_percent plus
--             the learning constants (wrong types fall back to DEFAULTS)
--   opts      the injected context:
--               now_s      the clock reading, in SECONDS
--               anchor_raw T0: the ambient raw level where the live panel
--                          curve reaches anchor_percent, or nil
--               kbd_max    max_brightness of the keyboard LED, or nil
--
-- Return: an ordered action list for the executor. At most one set_keyboard
-- per call:
--   {kind="set_keyboard", percent, raw}  command the keyboard backlight
--   {kind="log", line}                   append to the log ring
--   {kind="warn_once", key, line}        log once per run
--   {kind="kbd_manual", now_s}           a manual change was adopted
--   {kind="kbd_learned", now_s}          state.scale moved; persist it
--
-- Manual changes (the owner's Fn keys, detected by the caller from the sysfs
-- readback) are respected: the physical state is adopted and adaptation is
-- inhibited until ambient crosses the band edge that WOULD have triggered a
-- state change, then released and adapted on that crossing tick.

local M = {}

-- Require resolution differs between the two environments this file runs in:
-- the Noctalia host resolves "./policy.luau" (with the extension) while the
-- standalone luau resolves "./policy" (without) and rejects the extension form.
-- Try the host form first, fall back to the interpreter form (same shim as
-- temperature.luau).
local function import(name)
  local ok, mod = pcall(require, "./" .. name .. ".luau")
  if not ok then
    mod = require("./" .. name)
  end
  return mod
end

local policy = import("policy")

M.DEFAULTS = {
  -- Opt-in: the keyboard backlight stays the owner's until they ask for this.
  enabled = false,

  -- The threshold is where the live panel curve reaches this percent -- the
  -- keyboard's dark point moves with the curve the owner already tuned.
  anchor_percent = 40,

  -- Hysteresis half-width as a fraction of T0. The band is multiplicative in
  -- RAW counts (the anchor's scale, not an absolute lux figure) and therefore
  -- additive in the log domain the stabiliser lives in -- which is why the
  -- edges below are computed with policy.log_of.
  buffer_percent = 15,

  -- 0 means automatic: the lowest non-off level (see kbd_auto_percent).
  dark_percent = 0,

  -- Habit learning: too many Fn presses inside a short window mean the anchor
  -- is in the wrong place; the learned scale nudges it toward the ambient the
  -- owner changed it at. EMA alpha matches the profile learning's.
  learn_window_s = 600,
  learn_count = 3,
  learn_alpha = 0.125,
  scale_min = 0.5,
  scale_max = 2.0,
}

M.WINDOWS = {
  anchor_percent = { min = 25, max = 75, step = 1 },
  buffer_percent = { min = 0, max = 50, step = 1 },
  dark_percent = { min = 0, max = 100, step = 1 },
}

--- Round half away from zero: the host's std::round
--- (noctalia-dev/noctalia:src/system/keyboard_backlight_service.cpp) and the
--- rule the raw-level bookkeeping must share, or a level can read back one off
--- and be mistaken for a manual change.
local function round_half_away(x)
  if x >= 0 then return math.floor(x + 0.5) end
  return -math.floor(-x + 0.5)
end

local function is_finite(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

--- House `setting_number` tolerance: a wrong-typed setting falls back to the
--- shipped default instead of taking the policy down with it.
local function number_setting(cfg, key)
  local value = cfg[key]
  if is_finite(value) then return value end
  return M.DEFAULTS[key]
end

--- The automatic dark level: the smallest integer percent p in [1, 100] whose
--- raw level is at least 1, i.e. min{p : round(p * max / 100) >= 1} with round
--- half away from zero. Integer-only host IPC makes this necessary: the host
--- rejects a fractional percent outright (std::from_chars into int), and
--- percent 1 of a small LED can round to raw 0 -- the keyboard would never
--- light up in the dark.
---
--- Returns `percent, nil`, or `nil, reason` when max_brightness is nil, not a
--- finite number, not positive, or too small for any percent to reach level 1.
function M.kbd_auto_percent(max_brightness)
  if max_brightness == nil then
    return nil, "max_brightness is nil"
  end
  if not is_finite(max_brightness) then
    return nil, "max_brightness is not a finite number"
  end
  if max_brightness <= 0 then
    return nil, "max_brightness is not positive"
  end
  for p = 1, 100 do
    if round_half_away(p * max_brightness / 100) >= 1 then
      return p, nil
    end
  end
  return nil, "max_brightness is too small to reach level 1"
end

--- The raw level a percent commands: round(percent/100 * max) clamped to
--- [0, max] -- what the executor should read back from sysfs. Nil when max is
--- unusable, so the cmd_raw bookkeeping stays UNKNOWN rather than guessing
--- (manual detection is disabled while it is). Percent 0 needs no max: the raw
--- level is 0 for every LED.
local function raw_for_percent(percent, kbd_max)
  if percent <= 0 then return 0 end
  if not is_finite(kbd_max) or kbd_max <= 0 then return nil end
  local raw = round_half_away(percent / 100 * kbd_max)
  if raw < 0 then raw = 0 end
  if raw > kbd_max then raw = kbd_max end
  return raw
end

--- One decision tick. Mutates `state` (like adaptation.decide mutates the
--- session); returns the ordered action list. Pure: no IO, no clock reads.
function M.decide(state, observed, cfg, opts)
  state = state or {}
  observed = observed or {}
  cfg = cfg or {}
  opts = opts or {}

  local enabled = cfg.enabled
  if type(enabled) ~= "boolean" then enabled = M.DEFAULTS.enabled end
  if not enabled then return {} end

  -- A reading that is not a number is as unusable as a missing one: the band
  -- comparison must never see a string.
  if not is_finite(observed.log) then
    return { {
      kind = "warn_once", key = "kbd-reading",
      line = "keyboard skipped: no stabilised reading",
    } }
  end
  local log = observed.log

  local anchor_raw = opts.anchor_raw
  if not is_finite(anchor_raw) or anchor_raw <= 0 then
    return { {
      kind = "warn_once", key = "kbd-anchor",
      line = "keyboard skipped: no threshold anchor",
    } }
  end

  local scale = state.scale
  if not is_finite(scale) then scale = 1.0 end

  local b = number_setting(cfg, "buffer_percent") / 100
  if b > 0.9 then b = 0.9 end

  -- Band edges in the LOG domain: multiplicative in raw counts is additive
  -- here, which is the domain the stabilised reading lives in.
  local t_eff = anchor_raw * scale
  local log_low = policy.log_of(t_eff * (1 - b))
  local log_high = policy.log_of(t_eff * (1 + b))

  local actions = {}

  -- ── manual change detection ───────────────────────────────────────────────
  -- Only while awake: the idle dim (and any auto-driven level) is authored
  -- policy, not a preference -- learning from it would file our own writes as
  -- the owner's habit.
  local kbd_raw = observed.kbd_raw
  if not observed.idle and is_finite(state.cmd_raw) and is_finite(kbd_raw)
      and math.floor(kbd_raw + 0.5) ~= state.cmd_raw then
    -- Adopt the physical state: the owner's level is the truth until ambient
    -- crosses the edge that would have changed it.
    state.mode = (kbd_raw > 0) and "dark" or "light"
    state.cmd_raw = kbd_raw
    state.inhibit = true

    local window = number_setting(cfg, "learn_window_s")
    local now_s = opts.now_s
    local kept = {}
    for _, t in ipairs(type(state.changes) == "table" and state.changes or {}) do
      if is_finite(t) and (now_s - t) <= window then
        kept[#kept + 1] = t
      end
    end
    kept[#kept + 1] = now_s
    state.changes = kept
    actions[#actions + 1] = { kind = "kbd_manual", now_s = now_s }

    if #kept >= number_setting(cfg, "learn_count") then
      -- Habit learning: nudge the multiplicative scale toward the ambient the
      -- change happened at (ratio 1 when the reading is unknown -- a no-op),
      -- clamped so a single odd corner cannot drag the threshold away.
      local ratio = 1.0
      if is_finite(observed.raw) and t_eff > 0 then
        ratio = observed.raw / t_eff
      end
      local alpha = number_setting(cfg, "learn_alpha")
      local smin = number_setting(cfg, "scale_min")
      local smax = number_setting(cfg, "scale_max")
      local next_scale = scale + alpha * (ratio - scale)
      if next_scale < smin then next_scale = smin end
      if next_scale > smax then next_scale = smax end
      state.scale = next_scale
      state.changes = {}
      actions[#actions + 1] = { kind = "kbd_learned", now_s = now_s }
      actions[#actions + 1] = {
        kind = "log", line = string.format("keyboard: learned threshold scale %.3f", next_scale),
      }
    end

    -- The change is at most one tick old: it must stand this tick even if
    -- ambient is already past the release edge, or a manual change made in a
    -- changed room would be stomped by the very write it should have
    -- overridden. Release is for the NEXT crossing.
    return actions
  end

  -- ── inhibit ───────────────────────────────────────────────────────────────
  -- While inhibited, emit NO set_keyboard. The release condition is the edge
  -- that would have triggered the state change from the mode we adopted: on
  -- release, fall through to the normal decision ON THIS TICK, so the adapted
  -- write and the release cannot drift apart.
  if state.inhibit then
    local released = (state.mode == "light" and log <= log_low)
      or (state.mode == "dark" and log >= log_high)
    if not released then return actions end
    state.inhibit = false
  end

  -- ── normal decision ───────────────────────────────────────────────────────
  -- target_mode stays nil inside the band while the mode is already known:
  -- nothing crosses, nothing happens.
  local target_mode
  if log <= log_low then
    target_mode = "dark"
  elseif log >= log_high then
    target_mode = "light"
  elseif state.mode == nil then
    -- Bootstrap inside the band: the readback knows which side the keyboard is
    -- physically on; without one, the nearer band edge stands in for the side
    -- the reading is on (a strictly-inside reading carries no edge of its own).
    if is_finite(kbd_raw) then
      target_mode = (kbd_raw > 0) and "dark" or "light"
    else
      target_mode = (log >= (log_low + log_high) / 2) and "light" or "dark"
    end
  end

  if target_mode == nil or state.mode == target_mode then
    return actions
  end

  if state.mode == nil and is_finite(kbd_raw)
      and ((target_mode == "dark") == (kbd_raw > 0)) then
    -- Initial mode without a spurious write: the physical state already is
    -- what the reading asks for, so adopting it is bookkeeping only.
    state.mode = target_mode
    state.cmd_raw = kbd_raw
    return actions
  end

  local percent
  if target_mode == "light" then
    percent = 0
  else
    local dark_percent = number_setting(cfg, "dark_percent")
    if dark_percent > 0 then
      percent = round_half_away(dark_percent)
      if percent < 1 then percent = 1 end
      if percent > 100 then percent = 100 end
    else
      local auto, reason = M.kbd_auto_percent(opts.kbd_max)
      if auto == nil then
        return { {
          kind = "warn_once", key = "kbd-max",
          line = "keyboard dark level skipped: " .. reason,
        } }
      end
      percent = auto
    end
  end

  -- The guards gate every write. override_active is deliberately absent: the
  -- panel's manual-override window is per-actuator and must not block the
  -- keyboard -- the Fn keys ARE the keyboard's manual control, and they are
  -- handled above instead.
  local guards = observed.guards or {}
  local ok = policy.guard({
    dpms = guards.dpms,
    lid_closed = guards.lid_closed,
    idle_engaged = observed.idle,
    locked = observed.locked,
  })
  if not ok then return {} end

  local raw = raw_for_percent(percent, opts.kbd_max)
  actions[#actions + 1] = { kind = "set_keyboard", percent = percent, raw = raw }
  state.mode = target_mode
  state.cmd_raw = raw
  state.inhibit = false
  return actions
end

return M
