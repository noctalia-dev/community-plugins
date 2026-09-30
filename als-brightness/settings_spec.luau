--!nonstrict
-- The settings surface, derived once from the code constants.
--
-- plugin.toml (the numbers the settings page shows), translations/en.json (the
-- row text) and the code constants (what the service runs on) are three copies
-- of the same facts, and a value that moves must move in all of them (commit
-- c4813ee restructured one curve across nine files by hand). This module is the
-- single derivation: it turns the constants into the exact rows those files
-- must contain. One authority per value, everything else checked against it:
--
--   node positions (ambient x)  curve.luau DEFAULT_BRIGHTNESS_X / DEFAULT_TEMPERATURE_X
--   node outputs (y)            curve.luau FIXED_BRIGHTNESS_Y / FIXED_TEMPERATURE_Y
--   slider windows              curve.luau threshold_window()
--   percent clamp defaults      policy.luau DEFAULTS.min_percent / max_percent
--   row text templates + number formatting + row shapes   THIS FILE
--
-- The constants stay where they are (curve.luau's 178-check suite pins them);
-- this module only derives. plugin.toml and translations/en.json stay the
-- runtime-visible shipped copies -- they are never generated here, they are
-- CHECKED against surface_rows() by run-tests.sh ("settings surface agrees"),
-- which flattens both files with python3 and diffs line for line. So no value
-- lives in more than one unchecked place: editing an authority turns the suite
-- red until the shipped copies follow.
--
-- Pure: no host API, no file reads, no clock. Runs under bare `luau` and is
-- exercised by tests/settings_spec.test.luau. The cross-file diff lives in
-- run-tests.sh because only python3 has TOML/JSON parsers here.

local M = {}

-- Require resolution differs between the two environments this file runs in:
-- the Noctalia host resolves "./curve.luau" (with the extension) while the
-- standalone luau resolves "./curve" (without) and rejects the extension form.
-- Try the host form first, fall back to the interpreter form. (Same shim as
-- curve_source.luau.)
local function import(name)
  local ok, mod = pcall(require, "./" .. name .. ".luau")
  if not ok then
    mod = require("./" .. name)
  end
  return mod
end

local curve = import("curve")
local policy = import("policy")

-- ── row text (the only place these strings live) ─────────────────────────────
-- Titles are bare node ids and the description states the mapping. Both rules
-- are load-bearing (docs/MEMORY.md project conventions): host labels are static
-- strings with no value interpolation, so a value in a title goes stale on the
-- first slider move. The number in the description is the node's FIXED output
-- -- derivable from curve.FIXED_*_Y, therefore checkable.

local BRIGHTNESS_LABEL = "Node %d"
local TEMPERATURE_LABEL = "Temp node %d"
local BRIGHTNESS_DESCRIPTION = "sensor lightness counts mapped -> %s%%"
local TEMPERATURE_DESCRIPTION = "sensor ambient temp mapped -> %sK"

--- How a number is spelled in row text and canonical rows: "20.8", "70",
--- "5100" -- never a trailing ".0". The drift check diffs these strings
--- against plugin.toml literals and en.json prose, so the spelling rule lives
--- here exactly once.
function M.format_number(value)
  return string.format("%g", value)
end

local function fixed_outputs(kind)
  if kind == "brightness" then
    return curve.FIXED_BRIGHTNESS_Y
  elseif kind == "temperature" then
    return curve.FIXED_TEMPERATURE_Y
  end
  return nil
end

--- The settings-row title of node `index` (1-based) of `kind` ("brightness"
--- or "temperature"): "Node 3" / "Temp node 3". Bare -- no output value.
function M.node_label(kind, index)
  assert(fixed_outputs(kind) ~= nil, "node_label: kind must be brightness or temperature")
  if kind == "brightness" then
    return string.format(BRIGHTNESS_LABEL, index)
  end
  return string.format(TEMPERATURE_LABEL, index)
end

--- The settings-row description of node `index`: the fixed output the node
--- puts out at whatever threshold its slider holds. "sensor lightness counts
--- mapped -> 39.3%" / "sensor ambient temp mapped -> 5380K".
function M.node_description(kind, index)
  local ys = fixed_outputs(kind)
  assert(ys ~= nil, "node_description: kind must be brightness or temperature")
  assert(ys[index] ~= nil, "node_description: no such node")
  local y = M.format_number(ys[index])
  if kind == "brightness" then
    return string.format(BRIGHTNESS_DESCRIPTION, y)
  end
  return string.format(TEMPERATURE_DESCRIPTION, y)
end

-- ── canonical rows ───────────────────────────────────────────────────────────
-- Four row shapes, one per value class. The python flatten in run-tests.sh
-- emits the same shapes from plugin.toml + translations/en.json; the two
-- streams are diffed line for line. Rows are sorted so both sides share one
-- canonical order regardless of table iteration order.
--
--   map   <setting key> <map key> <reading:target>   the advanced-map defaults
--   thr   <setting key> <default> <min> <max> <step>  the 20 slider windows
--   pct   <setting key> <default>                    the percent clamp defaults
--   text  <setting key> <label> <description>        the 20 node rows' text

local function map_rows(rows, setting_key, defaults)
  for key, value in pairs(defaults) do
    rows[#rows + 1] = string.format("map\t%s\t%s\t%s", setting_key, key, value)
  end
end

local function threshold_rows(rows, kind, setting_prefix, defaults)
  for i = 1, #defaults do
    local lo, hi, step = curve.threshold_window(kind, i)
    rows[#rows + 1] = string.format("thr\t%s_%02d\t%s\t%s\t%s\t%s",
      setting_prefix, i, M.format_number(defaults[i]),
      M.format_number(lo), M.format_number(hi), M.format_number(step))
  end
end

local function text_rows(rows, kind, setting_prefix, defaults)
  for i = 1, #defaults do
    rows[#rows + 1] = string.format("text\t%s_%02d\t%s\t%s",
      setting_prefix, i, M.node_label(kind, i), M.node_description(kind, i))
  end
end

--- Every shipped settings-surface row the drift check compares, sorted.
function M.surface_rows()
  local rows = {}
  map_rows(rows, "curve_brightness", curve.DEFAULT_BRIGHTNESS)
  map_rows(rows, "curve_temperature", curve.DEFAULT_TEMPERATURE)
  threshold_rows(rows, "brightness", "thr_brightness", curve.DEFAULT_BRIGHTNESS_X)
  threshold_rows(rows, "temperature", "thr_temperature", curve.DEFAULT_TEMPERATURE_X)
  rows[#rows + 1] = string.format("pct\tmin_percent\t%s",
    M.format_number(policy.DEFAULTS.min_percent))
  rows[#rows + 1] = string.format("pct\tmax_percent\t%s",
    M.format_number(policy.DEFAULTS.max_percent))
  text_rows(rows, "brightness", "thr_brightness", curve.DEFAULT_BRIGHTNESS_X)
  text_rows(rows, "temperature", "thr_temperature", curve.DEFAULT_TEMPERATURE_X)
  table.sort(rows)
  return rows
end

return M
