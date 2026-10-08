--!nonstrict
-- Which curve is live, and why.
--
-- Before this module the decision spanned five places in service.luau: the
-- `setting_nodes`/`setting_thresholds` readers, the map-vs-sliders precedence
-- check in reload(), the learned-nudge layering in rebuild_active(), and the
-- log lines that explained all of it. Both historical defects in that glue --
-- the string_map emptiness trap (docs/DESIGN.md section 10.5: `#value` is 0 for
-- a map of any size) and the host-side row-masking bug (section 12.1: one row
-- edit makes the whole map look custom) -- lived there, and no test could load
-- service.luau to catch either. This module is the single place that decides
-- which curve the tick evaluates, in the shape hardware.discover() already
-- uses: settings in, one report out.
--
-- `resolve(settings, opts)` absorbs:
--   * the config readers for the curve keys (tolerant, hand-edit-proof),
--   * precedence: an edited map wins outright, else the sliders, with learned
--     threshold nudges layered on top while learning is on (never on a custom
--     map -- two writers over one curve is how a profile goes bad),
--   * curve building for both paths (map parse, slider build, anchors),
--   * every log line reload() used to emit about curves -- returned verbatim in
--     report.log so the caller decides WHEN to log (the per-observation
--     rebuild must stay silent).
--
-- `settings` is a plain key -> raw-config-value table (the service snapshots
-- noctalia.getConfig over M.setting_keys(); tests hand it tables directly).
-- `opts.profile` is the learned profile table (profile.new()/sanitise() shape).
-- Both are data, so this module stays pure: no host API, no sysfs, no clock.
-- It runs under a bare `luau` and is exercised by tests/curve_source.test.luau.

local M = {}

-- Require resolution differs between the two environments this file runs in:
-- the Noctalia host resolves "./curve.luau" (with the extension) while the
-- standalone luau resolves "./curve" (without) and rejects the extension form.
-- Try the host form first, fall back to the interpreter form.
local function import(name)
  local ok, mod = pcall(require, "./" .. name .. ".luau")
  if not ok then
    mod = require("./" .. name)
  end
  return mod
end

local curve = import("curve")
local profile = import("profile")

-- ── config readers ───────────────────────────────────────────────────────────
-- Every reader tolerates the wrong type rather than trusting the stored config,
-- because a settings file is a file the owner can edit by hand. They mirror the
-- generic readers in service.luau, for the keys this module owns.

--- The curves arrive as a `string_map` (the in-place-editable shape) or as a
--- `string_list`. A bare string is accepted as a one-row list, so a hand-edited
--- config cannot silently disable a whole curve.
---
--- The emptiness test is `next()`, not `#value`: a map keyed "00185" has no
--- integer keys, so `#value` is 0 for a map of any size and an `#value > 0`
--- guard would throw away every curve the GUI produced (DESIGN.md section 10.5).
local function read_nodes(value, fallback)
  if type(value) == "table" then
    if next(value) ~= nil then return value end
    return fallback
  end
  if type(value) == "string" and value ~= "" then return { value } end
  return fallback
end

local function read_number(value, fallback)
  if type(value) == "number" then return value end
  if type(value) == "string" then return tonumber(value) or fallback end
  return fallback
end

local function read_bool(value, fallback)
  if type(value) == "boolean" then return value end
  return fallback
end

--- The 20 threshold sliders ("thr_brightness_01".."thr_temperature_10"). Each
--- commits to its own config path, so a GUI edit of one slider never masks its
--- siblings -- which is exactly what the string_map editors do (the host marks
--- the whole map overridden on the first row edit, DESIGN.md section 12.1), and
--- why the maps are demoted to advanced fallbacks. Out-of-window values from a
--- hand-edited config are honoured as written; buildNodes repairs whatever
--- would break the interpolation and returns it as a problem line.
local function read_thresholds(settings, prefix, defaults)
  local out = {}
  for i = 1, #defaults do
    out[i] = read_number(settings[string.format("%s_%02d", prefix, i)], defaults[i])
  end
  return out
end

--- Every config key this module reads, so the service can snapshot them in one
--- pass and rebuild later without touching the host again. `resolve` never
--- reads any other key.
function M.setting_keys()
  local keys = {
    "curve_brightness", "curve_temperature", "learning_profile",
  }
  local prefixes = {
    { prefix = "thr_brightness", n = #curve.DEFAULT_BRIGHTNESS_X },
    { prefix = "thr_temperature", n = #curve.DEFAULT_TEMPERATURE_X },
  }
  for _, spec in ipairs(prefixes) do
    for i = 1, spec.n do
      keys[#keys + 1] = string.format("%s_%02d", spec.prefix, i)
    end
  end
  return keys
end

-- ── the brightness domain ────────────────────────────────────────────────────

--- The brightness curve is interpolated in log10(raw + 1). Not cosmetic: the
--- measured range is ~4000:1 (4 .. 16653 raw), so a linear axis would collapse
--- everything below ~1000 raw into a single step. The profile records
--- observations in this domain too, so the fit lays them straight onto the
--- authored x positions.
local function map_brightness_x(x)
  return math.log10(x + 1)
end

M.map_brightness_x = map_brightness_x

--- Learning clamps its nudges into each slider's own window
--- (curve.threshold_window), so a learned threshold can always be copied back
--- into the GUI without being clipped by the slider's own min/max.
local function fit_bounds(kind)
  local lo, hi = {}, {}
  for i = 1, #curve.FIXED_BRIGHTNESS_Y do
    local w_lo, w_hi = curve.threshold_window(kind, i)
    lo[i], hi[i] = w_lo, w_hi
  end
  return { lo = lo, hi = hi }
end

-- ── building one curve ───────────────────────────────────────────────────────
-- Both builders return (compiled, visible_count, log_lines). The lines are the
-- exact strings service.luau used to write, so the log is unchanged; keeping
-- them as data is what lets resolve() run silently on every observation.

--- The map path: the owner's rows, parsed exactly as written. Used only when the
--- map was edited away from the shipped default.
local function load_curve(settings, key, fallback, map_x, anchor)
  local items = read_nodes(settings[key], fallback)
  local nodes, problems = curve.parse_nodes(items, { map_x = map_x })
  local lines = {}
  for _, problem in ipairs(problems) do
    lines[#lines + 1] = "curve " .. key .. ": " .. problem
  end
  if #nodes == 0 then
    lines[#lines + 1] = "curve " .. key .. ": no usable nodes, falling back to the shipped default"
    nodes = curve.parse_nodes(fallback, { map_x = map_x })
  end
  if not curve.is_monotone(nodes) then
    -- Honoured, never rewritten: silently monotone-ising the owner's numbers
    -- would be the worst possible behaviour for a curve they are tuning. It
    -- stays safe because PCHIP cannot overshoot past a node value.
    lines[#lines + 1] = "curve " .. key .. ": values are not monotone; using them as written"
  end
  local compiled = anchor and curve.with_anchors(nodes) or nodes
  return curve.compile(compiled), #nodes, lines
end

--- The slider path: outputs are the fixed constants in curve.luau and the
--- sliders choose each node's threshold. Build problems (crossing sliders,
--- unusable values) are returned as lines, never raised.
local function load_slider_curve(settings, key, thresholds, fixed_ys, map_x, anchor)
  local nodes, problems = curve.buildNodes(thresholds, fixed_ys, { map_x = map_x })
  local lines = {}
  for _, problem in ipairs(problems) do
    lines[#lines + 1] = "curve " .. key .. ": " .. problem
  end
  local compiled = anchor and curve.with_anchors(nodes) or nodes
  return curve.compile(compiled), #nodes, lines
end

-- ── the active brightness curve ──────────────────────────────────────────────

--- What the tick evaluates: the slider-built curve, with learned threshold
--- nudges layered on when learning is on. Outputs never move (they are the
--- fixed constants in curve.luau); only where each node sits does.
---
--- Pure and silent: slider build problems were already reported by
--- load_slider_curve, and this runs on every observation.
local function rebuild_active(custom_map, base, thresholds, learning, prof)
  if custom_map then
    -- A custom map is the power-user override and wins outright. Learning is
    -- suspended on purpose (decision locked): nudging thresholds would silently
    -- fight the curve the owner wrote by hand.
    return base, "map (custom, learning suspended)", 0, thresholds
  end

  local xs = thresholds
  local learned = 0
  if learning then
    local fitted, counts = profile.fit_thresholds(
      prof, curve.FIXED_BRIGHTNESS_Y, thresholds, fit_bounds("brightness"))
    xs = fitted
    learned = profile.learned_nodes(counts)
  end

  local nodes = curve.buildNodes(xs, curve.FIXED_BRIGHTNESS_Y, { map_x = map_brightness_x })
  local built = curve.compile(nodes)
  if built == nil then
    -- Nothing usable: behave exactly as if the toggle were off, so an unusable
    -- profile can never leave the panel unmanaged.
    return base, "sliders (profile not usable yet)", learned, xs
  end

  local source
  if learning then
    source = string.format("sliders+learned (%d/%d nodes)", learned, #thresholds)
  else
    source = "sliders"
  end
  return built, source, learned, xs
end

-- ── the report ───────────────────────────────────────────────────────────────

--- Decide which curves are live. Returns one report:
---
---   log           ordered, verbatim, the lines reload() used to write about
---                 curves (problems first, then the learning-suspension note,
---                 then the anchor count, then the config summary). The caller
---                 decides when to emit them: the per-observation rebuild must
---                 stay silent.
---   brightness    built        what the tick evaluates (slider base + learned)
---                 base         the slider/map curve before learned nudges
---                 fitted       the thresholds the active curve was built from
---                 thresholds   the slider positions in force (learning seeds)
---                 source       the exact old CURVE_SOURCE strings
---                 learned_count  nodes the profile actually speaks for
---                 visible      nodes in the base curve (the "N nodes" in logs)
---                 custom_map   the map won precedence
---                 learning     the learning_profile flag in force
---   temperature   built        compiled curve WITH the hidden anchors
---                 origin       "map" | "sliders"
---                 fitted/thresholds/visible/custom_map as above
---                 hidden       anchor nodes appended to the visible rows
---
--- Precedence is decided HERE and nowhere else: map unedited => sliders (+ any
--- learned nudges) are the curve; map edited (as parsed nodes, so re-ordering
--- rows or reformatting is not an edit) => the map is the curve and learning is
--- suspended. A map the host masked down to one row (section 12.1) still counts
--- as edited -- that is exactly why the maps were demoted to advanced fallbacks
--- and the sliders own the live curve.
function M.resolve(settings, opts)
  opts = opts or {}
  settings = type(settings) == "table" and settings or {}
  local prof = opts.profile or profile.new()
  local learning = read_bool(settings.learning_profile, false)

  local thr_br = read_thresholds(settings, "thr_brightness", curve.DEFAULT_BRIGHTNESS_X)
  local thr_temp = read_thresholds(settings, "thr_temperature", curve.DEFAULT_TEMPERATURE_X)

  -- Precedence (Phase 6): the sliders run the curve; the advanced map editors
  -- win only when the owner actually edited them away from the shipped default.
  local br_custom = curve.map_is_custom(
    read_nodes(settings.curve_brightness, curve.DEFAULT_BRIGHTNESS), curve.DEFAULT_BRIGHTNESS)
  local temp_custom = curve.map_is_custom(
    read_nodes(settings.curve_temperature, curve.DEFAULT_TEMPERATURE), curve.DEFAULT_TEMPERATURE)

  local log = {}
  local br_base, br_count, lines
  if br_custom then
    br_base, br_count, lines = load_curve(
      settings, "curve_brightness", curve.DEFAULT_BRIGHTNESS, map_brightness_x, false)
  else
    br_base, br_count, lines = load_slider_curve(
      settings, "curve_brightness", thr_br, curve.FIXED_BRIGHTNESS_Y, map_brightness_x, false)
  end
  for _, line in ipairs(lines) do log[#log + 1] = line end

  local temp_built, temp_count
  if temp_custom then
    temp_built, temp_count, lines = load_curve(
      settings, "curve_temperature", curve.DEFAULT_TEMPERATURE, nil, true)
  else
    temp_built, temp_count, lines = load_slider_curve(
      settings, "curve_temperature", thr_temp, curve.FIXED_TEMPERATURE_Y, nil, true)
  end
  for _, line in ipairs(lines) do log[#log + 1] = line end

  if br_custom and learning then
    log[#log + 1] = "learning suspended: curve_brightness is a custom map (the map wins outright)"
  end

  if temp_built then
    log[#log + 1] = string.format("temperature curve: %d visible + %d hidden anchor nodes",
      temp_count, temp_built.n - temp_count)
  end

  local br_built, source, learned, fitted = rebuild_active(
    br_custom, br_base, thr_br, learning, prof)

  log[#log + 1] = string.format(
    "config: brightness=%d nodes via %s, temperature=%d nodes via %s, learning=%s source=%s",
    br_count, br_custom and "map" or "sliders",
    temp_count, temp_custom and "map" or "sliders",
    tostring(learning), source)

  return {
    log = log,
    brightness = {
      built = br_built,
      base = br_base,
      fitted = fitted,
      thresholds = thr_br,
      source = source,
      learned_count = learned,
      visible = br_count,
      custom_map = br_custom,
      learning = learning,
    },
    temperature = {
      built = temp_built,
      origin = temp_custom and "map" or "sliders",
      fitted = thr_temp,
      thresholds = thr_temp,
      visible = temp_count,
      hidden = temp_built and (temp_built.n - temp_count) or 0,
      custom_map = temp_custom,
    },
  }
end

return M
