--!nonstrict
-- The adaptation session: what the session should DO this tick.
--
-- Before this module the idle/override/learning timeline was glue inside
-- service.luau's update()/onIpc: the ordering (detect -> record -> poll ->
-- expire -> guard -> adapt -> temperature), the state machine behind the
-- suspend/resume log lines and the ms->s conversion all lived there, and no
-- test could load service.luau. Five historical defects were found by RUNNING
-- that glue (docs/DESIGN.md section 8 names four, section 9.5 the fifth), and
-- three of them -- the idle dim recorded as a preference, the override
-- re-recording itself every tick, the seconds/milliseconds mix -- are exactly
-- the timeline decisions this module now owns, so each has a named regression
-- test in tests/adaptation.test.luau.
--
-- decide() is pure: no host API, no sysfs, no filesystem, no clock. It runs
-- under a bare `luau`. The CLOCK IS INJECTED as a reading -- `opts.now_ms`, in
-- MILLISECONDS, named for its unit -- because the host clock (noctalia.nowMs)
-- is in ms while the policy windows are in SECONDS. The conversion happens in
-- exactly one place (the now_s / dt_s computation below), which is where the
-- historical ms/s mix (docs/DESIGN.md section 5) can never return: every
-- parameter below names its unit.
--
-- The interface is shaped like hardware.discover(): data in, one decision out.
--   actions = adaptation.decide(session, tick, observed, events, cfg, opts)
--
--   session   the timeline state, explicit data (mutated in place):
--               log            stabilised log10 reading (number|nil)
--               last_written   percent last commanded (number|nil)
--               override       active manual-change window
--                              {raw=<counts>, percent=<0-100>, at=<SECONDS>}|nil
--               idle           idle handshake engaged (bool)
--               locked         session locked (bool; the executor's status
--                              poll writes it -- see the poll_lock action)
--               last_reason    last suspension reason, so the suspend/resume
--                              lines fire on CHANGE only
--               last_ms        previous tick's clock reading in MILLISECONDS
--               applied_k      kelvin last written (number|nil;
--                              temperature.write_path records it from the
--                              splice outcomes -- its ONE owner)
--               last_temp_s    that write's time in SECONDS (also
--                              temperature.write_path's)
--               profile        the learned profile (profile.new() shape)
--               curve_settings the curve config snapshot rebuilds re-use
--               cs             the curve_source report (built curves + the
--                              source strings the log lines quote)
--               kbd            the keyboard-backlight bookkeeping
--                              keyboard.decide mutates ({mode=, cmd_raw=,
--                              inhibit=, changes=, scale=}; scale seeds from
--                              profile.kbd_scale and is written back into it
--                              on kbd_learned)
--   tick      the tick counter, or nil for an event-time call (onIpc): events
--             are processed either way, the tick body only when tick ~= nil.
--   observed  the IO snapshot the decision reads (numbers or nil):
--               raw        ambient counts      percent  panel percent 0-100
--               ambient_k  colour-temp sensor  guards   {dpms=, lid_closed=}
--               kbd_raw    keyboard-backlight raw level (manual-change input)
--   events    ordered timeline events since the previous decision (strings):
--             "idle-engaged" | "idle-released" | "user-adjusted" | anything
--             else (logged as unknown). The IPC vocabulary comes from the
--             idle handshake in docs/DESIGN.md ("The idle handshake").
--   cfg       policy knobs (policy.DEFAULTS shape) plus
--             enabled / colortemp_enabled, and kbd -- the keyboard-backlight
--             cfg, keyed exactly as keyboard.DEFAULTS names its setting keys
--             (enabled / anchor_percent / buffer_percent / dark_percent).
--   opts      the injected context: now_ms (the clock reading, MILLISECONDS);
--             paths ({als_raw=, bl_cur=, kbd_cur=, kbd_max=}) -- path strings
--             for the two read-failure lines, never read from inside this
--             module, with paths.kbd_cur as the probe's keyboard-presence
--             decision; and kbd_max (the keyboard LED's max_brightness, read
--             once at start).
--
-- Return: an ordered action list. decide() never performs IO; the executor
-- (service.luau) walks the list in order. The observation behind a `record`
-- action has ALREADY been folded into session.profile and session.cs (the
-- arithmetic is pure); the executor persists it. Action kinds:
--   {kind="log",            line}                 append to the log ring
--   {kind="warn_once",      key, line}            log once per run
--   {kind="write",          percent}              command the panel
--   {kind="record",         raw, percent, now_s}  persist the observation
--   {kind="save_profile",   now_s, force}         persist profile.json
--   {kind="poll_lock"}                            sample `noctalia msg status`
--   {kind="apply_temperature", kelvin, now_s}     run the settings splice
--   {kind="set_keyboard",  percent, raw}          command the keyboard backlight
--   {kind="kbd_manual",    now_s}                 the owner's Fn press took over
--   {kind="kbd_learned",   now_s}                 kbd.scale moved; persist it
--
-- Every log line this module returns is byte-identical to the line service.luau
-- used to write at the same point -- they are the maintainer's evidence stream.
-- The IO-side lines (colortemp splice outcomes, hardware/startup diagnostics)
-- stay with the executor.
--
-- The keyboard-backlight step is appended last and rides the tick even when the
-- panel timeline suspends: keyboard.decide owns its own guard (dpms / lid /
-- idle / locked) and deliberately excludes the panel's manual-override window
-- -- per actuator, the Fn keys ARE the keyboard's manual control. The master
-- switch (cfg.enabled), a failed ambient/backlight read and the override-expiry
-- tick skip the step: those hold every actuator for the tick.

local M = {}

-- Require resolution differs between the two environments this file runs in:
-- the Noctalia host resolves "./policy.luau" (with the extension) while the
-- standalone luau resolves "./policy" (without) and rejects the extension form.
-- Try the host form first, fall back to the interpreter form.
local function import(name)
  local ok, mod = pcall(require, "./" .. name .. ".luau")
  if not ok then
    mod = require("./" .. name)
  end
  return mod
end

local policy = import("policy")
local curve = import("curve")
local curve_source = import("curve_source")
local profile = import("profile")
local colortemp = import("colortemp")
local temperature = import("temperature")
local keyboard = import("keyboard")

-- Cadence, in ticks (1 Hz ticks). The lock poll is its own slow lane because
-- `noctalia msg status` is a shell-out (see service.poll_locked).
local HEARTBEAT_TICKS = 60
local POLL_LOCK_TICKS = 10

-- ── learning ─────────────────────────────────────────────────────────────────
--- Record an observation and rebuild the live curves, in place.
--
--- An observation is simply an override the owner made: where the ambient was,
--- and what they set the panel to. Recorded in the curve's own domain, so the
--- fit can lay it straight onto the authored x positions.
--
--- The learned curve only changes when an observation lands, so this is the only
--- place it needs rebuilding. resolve() is pure and silent: it re-lays the
--- learned nudges on the exact config snapshot the last reload took, so
--- precedence and curves cannot shift under an observation.
local function record(session, raw, percent, now_s, cfg)
  profile.add(session.profile, {
    x = curve_source.map_brightness_x(raw),
    y = percent,
    raw = raw,
    at = now_s,
  }, cfg)
  session.cs = curve_source.resolve(session.curve_settings, { profile = session.profile })
end

-- ── the suspend/resume state machine ─────────────────────────────────────────
--- The suspend/resume lines fire on CHANGE only: a repeating line would evict
--- real history out of the bounded log ring. `stored` is what session.last_reason
--- remembers; it is deliberately not always the logged text (the disabled state
--- stores "disabled" and logs "suspended: disabled by setting").
local function suspend_on_change(session, stored, line, log)
  if session.last_reason ~= stored then
    session.last_reason = stored
    log(line)
  end
end

-- ── events (the IPC vocabulary) ──────────────────────────────────────────────
-- The idle chain is an explicit handshake, because logind IdleHint is never set
-- on this setup and DPMS only flips at the 70 s screen-off, leaving a ~20 s
-- window where the panel is deliberately dimmed and still DPMS-On. The idle
-- behaviour in ~/.config/noctalia/config.toml emits these events (see
-- docs/DESIGN.md, "The idle handshake").
local function handle_event(session, event, observed, cfg, now_s, log, actions)
  if event == "idle-engaged" then
    session.idle = true
    log("idle engaged")
  elseif event == "idle-released" then
    session.idle = false
    -- Re-baseline from whatever brightnessctl -r just restored, so the restore
    -- is never mistaken for a user override.
    session.override = nil
    session.last_written = observed.percent
    session.log = nil
    log(string.format("idle released, re-baselined at %s",
      session.last_written and string.format("%.1f%%", session.last_written) or "nil"))
  elseif event == "user-adjusted" then
    if session.idle then
      -- The 30% idle dim is authored policy, not a preference, and while it is
      -- in force the panel is not showing what the owner asked for. Recording
      -- here would file the dim as their preferred brightness -- exactly the
      -- mistake the idle handshake exists to prevent. This was caught on
      -- hardware: with the session idle, an injected user-adjusted event wrote
      -- 30% into the profile as a learned value (docs/DESIGN.md section 9.5).
      --
      -- Swallowing the event is safe: idle-release re-baselines from whatever
      -- brightnessctl -r restored, and the tick picks up any genuine change
      -- afterwards.
      log("user-adjusted ignored while idle (the dim is not a preference)")
      return
    end
    local raw = observed.raw or 0
    local percent = observed.percent or 0
    session.override = { raw = raw, percent = percent, at = now_s }
    log("user override via keybinding")
    -- The definitive signal is also the best observation: the owner has told us
    -- exactly where the ambient was and what they wanted.
    record(session, raw, percent, now_s, cfg)
    actions[#actions + 1] = { kind = "record", raw = raw, percent = percent, now_s = now_s }
    actions[#actions + 1] = { kind = "save_profile", now_s = now_s, force = true }
  else
    log("unknown ipc event: " .. tostring(event))
  end
end

-- ── the decision ─────────────────────────────────────────────────────────────
function M.decide(session, tick, observed, events, cfg, opts)
  cfg = cfg or policy.DEFAULTS
  observed = observed or {}
  events = events or {}
  opts = opts or {}

  -- The one ms -> s conversion. opts.now_ms is the INJECTED clock reading in
  -- MILLISECONDS; everything below this line works in SECONDS (policy
  -- functions take seconds; session.override.at and session.last_temp_s are
  -- seconds). Mixing the two makes every timeout fire on the first tick --
  -- which is exactly the bug these parameter names exist to prevent
  -- (docs/DESIGN.md section 5).
  local now_s = opts.now_ms / 1000.0

  local actions = {}
  local function log(line)
    actions[#actions + 1] = { kind = "log", line = line }
  end

  -- Events happen at their own instants: the executor calls decide() as each
  -- IPC event arrives (tick = nil), so their lines and state land in the log
  -- at event time, not deferred to the next tick.
  for _, event in ipairs(events) do
    handle_event(session, event, observed, cfg, now_s, log, actions)
  end
  if tick == nil then return actions end

  -- ── the keyboard-backlight step ───────────────────────────────────────────
  -- The two-state keyboard policy (keyboard.luau) rides the same tick but NOT
  -- the panel's guard: its own guard decides on dpms / lid / idle / locked, and
  -- deliberately excludes the panel's manual-override window -- per actuator,
  -- the Fn keys ARE the keyboard's manual control. That is why this also runs
  -- on the suspend path: the step must reach keyboard.decide whenever the panel
  -- holds (an open panel override must not freeze the keyboard), and
  -- keyboard.decide's own guard is what holds the keyboard back.
  local function kbd_step()
    local kbd_cfg = cfg.kbd
    if type(kbd_cfg) ~= "table" or kbd_cfg.enabled ~= true then return end
    -- Presence is the probe's decision (hardware.discover fills paths.kbd_cur
    -- only when a kbd_backlight LED exists), passed in like every path.
    if opts.paths == nil or opts.paths.kbd_cur == nil then return end

    -- The threshold anchor is where the live panel curve reaches
    -- anchor_percent. The curve compiles x in the log10(raw + 1) domain
    -- (curve_source.map_brightness_x), so solve_x answers in that domain and
    -- the ONE inversion to raw counts happens right here: raw = 10^x - 1.
    local anchor_pct = kbd_cfg.anchor_percent
    if not curve.is_finite(anchor_pct) then
      anchor_pct = keyboard.DEFAULTS.anchor_percent
    end
    local anchor_x, why = curve.solve_x(session.cs.brightness.built, anchor_pct)
    if anchor_x == nil then
      -- Anchor outside the curve range: skip this tick's keyboard decision
      -- rather than guess a threshold.
      actions[#actions + 1] = {
        kind = "warn_once", key = "kbd-anchor",
        line = "keyboard skipped: " .. why,
      }
      return
    end

    if session.kbd == nil then
      session.kbd = { mode = nil, cmd_raw = nil, inhibit = false, changes = {}, scale = 1.0 }
    end

    local kbd_actions = keyboard.decide(session.kbd, {
      log = session.log, -- the stabilised reading (policy.log_of domain)
      raw = observed.raw,
      kbd_raw = observed.kbd_raw,
      idle = session.idle,
      locked = session.locked,
      guards = observed.guards,
    }, kbd_cfg, {
      now_s = now_s, -- SECONDS: the one ms->s conversion, shared with the timeline
      anchor_raw = 10 ^ anchor_x - 1,
      kbd_max = opts.kbd_max,
    })
    for _, action in ipairs(kbd_actions) do
      if action.kind == "kbd_learned" then
        -- Pure bookkeeping, exactly like record() folds observations into the
        -- profile: the learned scale lands here; the executor persists it.
        session.profile.kbd_scale = session.kbd.scale
      end
      actions[#actions + 1] = action
    end
  end

  -- Tick timeline, in order. Each stage is a separate pure call so the
  -- ordering is explicit and tested: detect -> record -> poll -> expire ->
  -- guard -> adapt -> temperature.
  local dt_s = session.last_ms and (opts.now_ms - session.last_ms) / 1000.0 or 1.0
  session.last_ms = opts.now_ms
  if dt_s <= 0 then dt_s = 1.0 end

  if not cfg.enabled then
    suspend_on_change(session, "disabled", "suspended: disabled by setting", log)
    return actions
  end

  local raw = observed.raw
  if raw == nil then
    -- Probed once at start; a later failure skips the write rather than feeding
    -- zeros into the curve. Restart the plugin to re-probe the hardware.
    actions[#actions + 1] = {
      kind = "warn_once", key = "als-read",
      line = "ambient read failed at " .. tostring(opts.paths and opts.paths.als_raw)
        .. "; not writing",
    }
    return actions
  end
  local observed_pct = observed.percent
  if observed_pct == nil then
    actions[#actions + 1] = {
      kind = "warn_once", key = "bl-read",
      line = "backlight read failed at " .. tostring(opts.paths and opts.paths.bl_cur)
        .. "; not writing",
    }
    return actions
  end

  if tick % HEARTBEAT_TICKS == 0 then
    log(string.format("heartbeat raw=%d stab=%s last=%s observed=%s idle=%s locked=%s curve=%s",
      raw,
      session.log and string.format("%.3f", session.log) or "nil",
      session.last_written and string.format("%.1f", session.last_written) or "nil",
      observed_pct and string.format("%.1f", observed_pct) or "nil",
      tostring(session.idle), tostring(session.locked), session.cs.brightness.source))
  end

  -- A change we did not command, while awake, is the user taking over.
  -- Crucially this is skipped while idle: the 30% idle dim is authored policy,
  -- not a preference, and must never be learned as one.
  --
  -- Only the FIRST detection records an override. Re-recording on every tick
  -- would move the anchor and reset the timeout each second, so the window
  -- could never expire (docs/DESIGN.md section 5, "the expiry-reset defect").
  if not session.idle and session.last_written ~= nil and session.override == nil
     and policy.is_manual_change(session.last_written, observed_pct, cfg) then
    session.override = { raw = raw, percent = observed_pct, at = now_s }
    log(string.format("user override recorded: observed=%.1f%% raw=%d", observed_pct, raw))
    record(session, raw, observed_pct, now_s, cfg)
    actions[#actions + 1] = { kind = "record", raw = raw, percent = observed_pct, now_s = now_s }
  end

  if tick % POLL_LOCK_TICKS == 0 then
    actions[#actions + 1] = { kind = "poll_lock" }
  end
  actions[#actions + 1] = { kind = "save_profile", now_s = now_s, force = false }

  local override_active = session.override ~= nil
    and not policy.override_expired(session.override, raw, now_s, cfg)
  if session.override ~= nil and not override_active then
    session.override = nil
    -- Re-baseline from wherever the user left the panel. Without this the next
    -- tick would compare against a stale last_written and immediately detect a
    -- brand-new override, so the adapter would never resume.
    session.last_written = observed_pct
    log(string.format("override expired at raw=%d, re-baselined at %s",
      raw, observed_pct and string.format("%.1f%%", observed_pct) or "nil"))
    -- The expiry tick does ONLY this transition. Adapting on the same tick
    -- would stomp the re-baseline with a curve write (the panel jumps back to
    -- the curve value before the owner's choice has settled) and the next tick
    -- would see that write as a fresh manual change. The resume line, the first
    -- adaptation and the keyboard step all land on the next tick instead.
    return actions
  end

  -- The hardware-owned guards come from the report, which is also the single
  -- home for what a missing guard means (hardware.guard_state: an unavailable
  -- guard PASSES, or a machine without a DPMS node or lid switch would never
  -- adapt at all). The remaining guards are session state.
  local guards = observed.guards or {}
  local ok, reason = policy.guard({
    dpms = guards.dpms,
    lid_closed = guards.lid_closed,
    idle_engaged = session.idle,
    locked = session.locked,
    override_active = override_active,
  })

  if not ok then
    suspend_on_change(session, reason, "suspended: " .. reason, log)
    -- The keyboard is a second actuator with its own guards: it decides on its
    -- own timeline even while the panel is suspended (see kbd_step above).
    kbd_step()
    return actions
  end

  if session.last_reason ~= "ok" then
    session.last_reason = "ok"
    log("resumed: adapting")
  end

  -- Stabilise first, then map, then rate limit: each stage is a separate pure
  -- function so the ordering is explicit and tested.
  session.log = policy.stabilize(session.log, raw, dt_s, cfg)
  local target = policy.clamp(
    curve.eval(session.cs.brightness.built, session.log) or cfg.min_percent, cfg)
  local commanded = policy.slew(session.last_written, target, dt_s, cfg)

  if policy.should_write(session.last_written, commanded, cfg) then
    log(string.format("write: raw=%d target=%.1f commanded=%.1f (was %s) via %s",
      raw, target, commanded,
      session.last_written and string.format("%.1f", session.last_written) or "nil",
      session.cs.brightness.source))
    actions[#actions + 1] = { kind = "write", percent = commanded }
    session.last_written = commanded
  end

  -- Colour temperature rides on the same guards: it only acts when brightness
  -- would, so a dimmed, locked or overridden session is left alone too. The
  -- learned profile deliberately does not touch it -- there is no user signal
  -- to learn a temperature preference from.
  if cfg.colortemp_enabled then
    local ambient_k = observed.ambient_k
    if ambient_k ~= nil and ambient_k > 0 then
      local mapped = curve.eval(session.cs.temperature.built, ambient_k)
      local target_k = colortemp.clamp_k(mapped, colortemp.MAP_DEFAULTS)
      if target_k ~= nil and temperature.should_apply(session, target_k, now_s) then
        actions[#actions + 1] = { kind = "apply_temperature", kelvin = target_k, now_s = now_s }
      end
    end
  end

  -- Keyboard last: its actions are appended after the panel's, so the executor
  -- performs the panel's timeline before the keyboard's on every tick.
  kbd_step()
  return actions
end

return M
