--!nonstrict
-- The learned profile: observations recorded from the owner's overrides, fitted
-- as THRESHOLD nudges (Phase 6).
--
-- Why this exists: before Phase 2 an override was lost on every plugin restart
-- (docs/DESIGN.md section 7 recorded that as a limitation). The profile gives the
-- learning somewhere to live. The head-of-page `learning_profile` toggle decides
-- whether the learned thresholds are *applied*; it never decides whether
-- observations are *recorded*, so switching it on always reveals a profile that
-- has been growing rather than an empty file.
--
-- Learning never touches an output: the outputs are fixed constants
-- (curve.luau FIXED_*_Y) and the sliders own the thresholds. A manual change to
-- output y at ambient a targets the node whose fixed output is nearest y, and
-- that node's learned threshold EMA-drifts toward a, seeded from the slider
-- position -- so learning slides the nodes the owner can see, instead of
-- inventing curve shape behind their back.
--
-- The plugin cannot write its own configuration (upstream: "plugins read config
-- but cannot write it"), so promoting a learned threshold into its slider is a
-- manual copy by the owner. fit_thresholds clamps learned values into the slider
-- windows (curve.threshold_window), so that copy can never be clipped by the
-- slider's own min/max.
--
-- Everything here is pure: no host API, no sysfs, no clock, no file IO. The
-- service owns reading and writing profile.json; this module owns the arithmetic.
-- Exercised by tests/profile.test.luau.

local M = {}

M.DEFAULTS = {
  -- A node needs at least this many observations before its learned threshold is
  -- trusted. One stray sample from a hand shadowing the sensor must not move a
  -- node, so a sparse profile degrades to the slider positions rather than into
  -- noise.
  min_observations = 2,

  -- Observations are a rolling window, newest kept. Bounded so profile.json
  -- cannot grow without limit on a machine that is left running for months.
  max_observations = 512,

  -- EMA weight of a single observation when drifting a node's threshold. A held
  -- brightness key fires many events, so one correction burst carries a node most
  -- of the way to where the owner was; a lone sample is diluted -- and with
  -- min_observations above, is never applied alone anyway.
  learn_alpha = 0.15,
}

-- The numeric predicate has ONE home: curve.luau exports it (M.is_finite), and
-- this file is the second consumer (a corrupt profile.json once passed
-- validation here, which is exactly what sanitise() exists to prevent).
-- Require resolution differs between the two environments this file runs in:
-- the Noctalia host resolves "./curve.luau" (with the extension) while the
-- standalone luau resolves "./curve" (without) and rejects the extension form.
-- Try the host form first, fall back to the interpreter form (same as
-- adaptation.luau).
local is_finite
do
  local ok, mod = pcall(require, "./curve.luau")
  if not ok then
    mod = require("./curve")
  end
  is_finite = mod.is_finite
end

--- A fresh, empty profile.
function M.new()
  return { version = 1, observations = {}, nodes = {}, updated_at = nil }
end

--- Which node a manual change belongs to: the one whose fixed output is nearest
--- what the owner chose. Ties go to the lower node, which is the conservative
--- pick when neighbours share an output (the three 5100 K temperature nodes, or
--- two brightness nodes the owner slid close together).
function M.target_node(fixed_ys, y)
  if type(fixed_ys) ~= "table" or not is_finite(y) then return nil end
  local best, best_dist = nil, nil
  for i = 1, #fixed_ys do
    local d = math.abs(fixed_ys[i] - y)
    if is_finite(d) and (best_dist == nil or d < best_dist) then
      best, best_dist = i, d
    end
  end
  return best
end

--- Record one observation, in place. `obs` is `{ x = <curve domain>, y = <value>,
--- raw = <optional, the ambient learning drifts toward>, at = <optional, seconds> }`.
--
-- Returns the profile, for chaining in tests.
function M.add(profile, obs, cfg)
  cfg = cfg or M.DEFAULTS
  if profile == nil or obs == nil then return profile end
  if not is_finite(obs.x) or not is_finite(obs.y) then return profile end
  profile.observations = profile.observations or {}
  profile.observations[#profile.observations + 1] = obs
  local cap = cfg.max_observations or M.DEFAULTS.max_observations
  -- Drop from the front: the newest samples describe the current room, and the
  -- curve is meant to track the owner, not to average their whole history.
  while #profile.observations > cap do
    table.remove(profile.observations, 1)
  end
  return profile
end

--- Fit the observations as threshold nudges on top of the slider positions
--- (Phase 6).
--
-- Each observation targets the node whose fixed output is nearest what the owner
-- chose (`target_node`), and that node's threshold EMA-drifts toward the ambient
-- the owner was in (`obs.raw`, the same domain as the sliders). The EMA is seeded
-- from the slider value, so a node with no history sits exactly where the owner
-- slid it, and "learned" always means "nudged from there".
--
-- Returns `xs` (one threshold per node) and `counts` (observations per node, so
-- the service can log how much of the profile is actually learned). Nodes with
-- fewer than `min_observations` keep their slider position. `cfg.lo` / `cfg.hi`
-- (optional per-node arrays, curve.threshold_window) clamp the result into the
-- slider's own window so a learned threshold can always be copied back into the
-- GUI without being clipped.
function M.fit_thresholds(profile, fixed_ys, seed_xs, cfg)
  cfg = cfg or M.DEFAULTS
  local n = fixed_ys and #fixed_ys or 0
  local xs, counts = {}, {}
  if n == 0 then return xs, counts end

  local alpha = cfg.learn_alpha or M.DEFAULTS.learn_alpha
  local min_obs = cfg.min_observations or M.DEFAULTS.min_observations
  local acc = {}
  for i = 1, n do
    acc[i] = seed_xs and is_finite(seed_xs[i]) and seed_xs[i] or nil
    counts[i] = 0
  end

  for _, obs in ipairs((profile and profile.observations) or {}) do
    -- `raw` is the ambient in the slider domain (raw sensor counts). An
    -- observation without it cannot say where the node should sit, so it is
    -- skipped rather than guessed at: obs.x is a different domain (log10).
    local a = obs.raw
    local node = M.target_node(fixed_ys, obs.y)
    if node ~= nil and is_finite(a) and acc[node] ~= nil then
      acc[node] = acc[node] + alpha * (a - acc[node])
      counts[node] = counts[node] + 1
    end
  end

  for i = 1, n do
    local base = seed_xs and seed_xs[i] or nil
    if counts[i] >= min_obs and acc[i] ~= nil then
      local v = acc[i]
      if cfg.lo and is_finite(cfg.lo[i]) and v < cfg.lo[i] then v = cfg.lo[i] end
      if cfg.hi and is_finite(cfg.hi[i]) and v > cfg.hi[i] then v = cfg.hi[i] end
      xs[i] = v
    else
      xs[i] = base
    end
  end

  return xs, counts
end

--- How many nodes the profile can actually speak for. Used for logging, and for
--- deciding how much of the curve is learned rather than slider-positioned.
function M.learned_nodes(counts, cfg)
  cfg = cfg or M.DEFAULTS
  local min_obs = cfg.min_observations or M.DEFAULTS.min_observations
  local learned = 0
  for i = 1, (counts and #counts or 0) do
    if counts[i] >= min_obs then learned = learned + 1 end
  end
  return learned
end

--- Defensively clean a decoded profile.
--
-- profile.json is a file the owner can open, edit, and corrupt, and it is read at
-- plugin start. A malformed file must cost the learned data, never the service,
-- so every field is validated and anything unusable is dropped rather than
-- trusted. Returns a well-formed profile.
function M.sanitise(value)
  local clean = M.new()
  if type(value) ~= "table" then return clean end

  if type(value.version) == "number" then clean.version = value.version end
  if is_finite(value.updated_at) then clean.updated_at = value.updated_at end

  if type(value.observations) == "table" then
    for _, obs in ipairs(value.observations) do
      if type(obs) == "table" and is_finite(obs.x) and is_finite(obs.y) then
        clean.observations[#clean.observations + 1] = {
          x = obs.x,
          y = obs.y,
          raw = is_finite(obs.raw) and obs.raw or nil,
          at = is_finite(obs.at) and obs.at or nil,
        }
      end
    end
  end

  if type(value.nodes) == "table" then
    for _, node in ipairs(value.nodes) do
      if type(node) == "table" and is_finite(node.x) and is_finite(node.y) then
        clean.nodes[#clean.nodes + 1] = { x = node.x, y = node.y }
      end
    end
  end

  return clean
end

return M
