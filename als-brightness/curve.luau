--!nonstrict
-- The panel curves: user-owned node lists, smoothed with PCHIP.
--
-- Phase 2 moved the mapping curve out of the code and into configuration, so the
-- owner can hand-tune it in the settings GUI instead of editing Luau. This module
-- is that curve: it parses the node strings, and interpolates between them.
--
-- Interpolation is Fritsch-Carlson monotone cubic Hermite ("PCHIP",
-- SIAM J. Numer. Anal. 17(2), 1980), not a straight line and not a naive cubic:
--
--   * A straight line leaves a derivative discontinuity at every node, so the
--     *rate* of adaptation visibly jumps each time the ambient crosses one.
--   * A naive cubic (Catmull-Rom, natural spline) overshoots. On this curve an
--     overshoot means commanding above 100% or below the floor -- the curve
--     leaves the band the owner drew, which is the one thing it must never do.
--
-- PCHIP fixes both: monotone nodes produce a monotone curve, so the output is
-- always inside [min(y), max(y)] and the max/min clamps are satisfied by
-- construction rather than by clamping. The construction is also local, so moving
-- one node cannot ripple into its neighbours.
--
-- Everything here is pure: no host API, no sysfs, no clock. It runs under a bare
-- `luau` interpreter and is exercised by tests/curve.test.luau.

local M = {}

-- The one numeric predicate. Shared with profile.luau (which imports it to
-- sanitise profile.json); this is its single home.
local is_finite = function(v)
  -- The type check is load-bearing: without it a *string* passes, because
  -- `"nonsense" ~= math.huge` is true in Lua. That let a corrupt profile.json
  -- through validation once -- exactly what profile.sanitise() exists to
  -- prevent -- so the type check stays however redundant it looks.
  if type(v) ~= "number" then return false end
  if v ~= v then return false end -- NaN
  return v ~= math.huge and v ~= -math.huge
end

M.is_finite = is_finite

-- ── the default node lists ───────────────────────────────────────────────────
-- These are also the manifest defaults in plugin.toml. run-tests.sh asserts the
-- two agree -- keys and values both -- because a silent divergence between what
-- the GUI shows and what the code uses would be a genuinely confusing bug, and
-- because the zero-padded keys are what keep the rows in numeric order.
--
-- They are written as maps, exactly as the manifest writes them, so the code
-- fallback and the settings page are the same table rather than two lists that
-- merely ought to match.
--
-- Brightness: ten log-spaced points spanning the measured 4..16653 raw range,
-- with an exact hit on the owner's one measured datum (185 raw -> 70%). They
-- reproduce the pre-Phase-2 formula
--     pct = 70 + 25 * (log10(raw + 1) - log10(186))
-- to within a fraction of a percent across the operating range. The top end is
-- deliberately *not* identical: that formula clipped to 100% at raw ~ 2947, i.e.
-- full brightness barely 3x the measured room level. Splitting it into
-- 2200 -> 96.8 and 16384 -> 100 gives the top of the range somewhere to go.
M.DEFAULT_BRIGHTNESS = {
  ["00001"] = "1:20.8",
  ["00004"] = "4:30.7",
  ["00010"] = "10:39.3",
  ["00030"] = "30:50.6",
  ["00100"] = "100:63.4",
  ["00185"] = "185:70",
  ["00400"] = "400:78.3",
  ["01000"] = "1000:88.3",
  ["02200"] = "2200:96.8",
  ["16384"] = "16384:100",
}

-- Temperature: ambient K -> panel K. Warm floor 5100 K, cool ceiling 6500 K,
-- and TEN DISTINCT outputs between them: the original midpoints (5380, 5660,
-- 5940, 6220) stay, each earlier gap is filled by its own midpoint (5240,
-- 5520, 5800, 6080). The duplicated outputs that used to carry the flat runs
-- here were read as a bug by owners, so the flats moved into with_anchors's
-- four hidden nodes: PCHIP still pins a zero tangent at both ends, every
-- visible row is unique, and the compiled curve keeps its floor/ceiling
-- character (14 nodes under the hood, 10 rows in the UI).
M.DEFAULT_TEMPERATURE = {
  ["02500"] = "2500:5100",
  ["02700"] = "2700:5240",
  ["03000"] = "3000:5380",
  ["03500"] = "3500:5520",
  ["04000"] = "4000:5660",
  ["04500"] = "4500:5800",
  ["05000"] = "5000:5940",
  ["05500"] = "5500:6080",
  ["06000"] = "6000:6220",
  ["06500"] = "6500:6500",
}

-- ── fixed outputs and default thresholds (Phase 6) ───────────────────────────
-- The threshold sliders edit WHERE a node sits, never what it puts out: node i
-- always outputs FIXED_BRIGHTNESS_Y[i] (resp. FIXED_TEMPERATURE_Y[i]) at whatever
-- ambient reading its slider was moved to. The outputs are constants here, in one
-- place, and carried in each row's en.json description (`sensor ambient temp
-- mapped -> 5940K`). Titles stay bare node ids so no value can repeat in them
-- or go stale after a slider move.
--
-- DEFAULT_*_X are the shipped slider positions -- exactly the x half of the maps
-- above, so a fresh install rebuilds the same curve node for node. Two guards
-- keep it that way: tests/print-defaults.luau emits these arrays and run-tests.sh
-- diffs them against plugin.toml's slider defaults and windows, and
-- tests/curve.test.luau asserts buildNodes(DEFAULT_*_X, FIXED_*_Y) reproduces the
-- maps above exactly.
--
-- Brightness thresholds are raw sensor counts (the slider domain); the log
-- transform happens later, in buildNodes. Temperature thresholds are ambient K.
M.FIXED_BRIGHTNESS_Y = { 20.8, 30.7, 39.3, 50.6, 63.4, 70, 78.3, 88.3, 96.8, 100 }
M.DEFAULT_BRIGHTNESS_X = { 1, 4, 10, 30, 100, 185, 400, 1000, 2200, 16384 }

M.FIXED_TEMPERATURE_Y = { 5100, 5240, 5380, 5520, 5660, 5800, 5940, 6080, 6220, 6500 }
M.DEFAULT_TEMPERATURE_X = { 2500, 2700, 3000, 3500, 4000, 4500, 5000, 5500, 6000, 6500 }

--- The min, max and step of one threshold slider, exactly as plugin.toml
--- declares it. One function for both sides: the manifest literals and the
--- learning bounds below cannot drift apart silently, because run-tests.sh diffs
--- them. `kind` is "brightness" or "temperature"; `index` is 1..10.
---
--- The windows are deliberately per-node (about a third to triple the default,
--- +/-500 K for temperature): the brightness range is 4000:1, so one shared
--- window would be unusable at one end or the other, while radical reshaping
--- stays possible in the advanced map editors.
function M.threshold_window(kind, index)
  local defaults
  if kind == "brightness" then
    defaults = M.DEFAULT_BRIGHTNESS_X
  elseif kind == "temperature" then
    defaults = M.DEFAULT_TEMPERATURE_X
  end
  local d = defaults and defaults[index]
  if d == nil then return nil end

  if kind == "brightness" then
    local lo = math.floor(d / 3)
    if lo < 0 then lo = 0 end
    local hi = d * 3
    if hi > 16384 then hi = 16384 end -- the sensor's own ceiling
    return lo, hi, 1
  end
  local lo = d - 500
  if lo < 1500 then lo = 1500 end
  local hi = d + 500
  if hi > 8000 then hi = 8000 end
  return lo, hi, 50
end

-- ── parsing ──────────────────────────────────────────────────────────────────

--- Split the raw setting into rows, each with the label the owner sees.
--
-- Two shapes arrive here and both must work:
--
--   * a `string_map` -- the shape the settings GUI can edit *in place*, keyed by
--     the reading;
--   * a `string_list` -- an array of node strings. Still accepted: the curve is a
--     plain list of numbers, and nothing about that needs enforcing.
--
-- They are told apart by the *key* type, not by `#items`: a map keyed "00185" has
-- no integer keys at all, so `#items` is 0 for a map of any size. Getting that
-- wrong would silently drop the whole curve.
local function normalise(items)
  local entries = {}
  if items == nil then return entries end
  if type(items) == "string" then items = { items } end
  if type(items) ~= "table" then return nil end

  local keyed = false
  for k in pairs(items) do
    if type(k) == "string" then
      keyed = true
      break
    end
  end

  if keyed then
    -- Sorted, matching the order the settings page renders (it sorts keys as
    -- text), so a problem message names the row where the owner will look for it.
    local keys = {}
    for k in pairs(items) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      entries[#entries + 1] = { label = tostring(k), text = items[k], key = tostring(k) }
    end
  else
    for i, v in ipairs(items) do
      entries[#entries + 1] = { label = tostring(i), text = v }
    end
  end
  return entries
end

--- Read one row into x and y, plus an optional note about a key that disagrees.
--
--   "185:70" -> x=185, y=70   the value carries the whole node
--   "70"     -> x from key    the value is just the target
--
-- The value always wins over the key. A stale key must never be able to move a
-- node the owner typed; the most it can do is sort the row somewhere unexpected,
-- and that is worth exactly one log line rather than being quietly obeyed.
local function read_node(text, key)
  local xs, ys = text:match("^([^:]+):(.*)$")
  if xs then
    local x = tonumber((xs:gsub("%s+$", "")))
    local y = tonumber((ys:gsub("^%s+", "")))
    if key and is_finite(x) then
      local keyed = tonumber(key)
      if is_finite(keyed) and keyed ~= x then
        return x, y, string.format(
          "row %q is keyed %s but its value says x=%s; using the value (the row sorts by the key)",
          key, tostring(keyed), tostring(x))
      end
    end
    return x, y, nil
  end
  -- No colon: the cell is the target alone, and the key supplies the reading.
  return key and tonumber(key), tonumber(text), nil
end

--- Parse node rows into a node list.
--
-- `opts.map_x` (optional) transforms the x domain after parsing. The brightness
-- curve passes log10(x + 1), because the measured 4000:1 range would otherwise
-- collapse everything below ~1000 raw into a single step; the temperature curve
-- passes nothing, because ambient kelvin is already linear.
--
-- Returns `nodes` (ascending by x, x unique) and `problems`, an array of
-- human-readable strings naming every row that was rejected or adjusted. This
-- never raises: a malformed row costs one node and one log line. A curve the owner
-- is midway through editing must not be able to take the service down.
function M.parse_nodes(items, opts)
  opts = opts or {}
  local map_x = opts.map_x
  local nodes, problems = {}, {}

  local entries = normalise(items)
  if entries == nil then
    problems[#problems + 1] = "curve is not a list"
    return nodes, problems
  end

  local seen = {}
  for _, entry in ipairs(entries) do
    if type(entry.text) ~= "string" then
      problems[#problems + 1] = "entry " .. entry.label .. " is not a string"
    else
      -- An optional '#' suffix comment, matching the TOML-splice discipline of
      -- never rewriting text the user owns: we tolerate annotation, we drop it.
      local text = entry.text:gsub("#.*$", "")
      text = text:gsub("^%s+", ""):gsub("%s+$", "")

      if text == "" then
        -- A blank row is how the editor renders a cell you have not filled in yet.
        -- Skipping it silently is deliberate: it is not an error.
      else
        local x, y, note = read_node(text, entry.key)
        if note then problems[#problems + 1] = note end
        if not is_finite(x) then
          problems[#problems + 1] = string.format(
            "entry %s: %q has no reading; write it as \"reading:target\"", entry.label, entry.text)
        elseif not is_finite(y) then
          problems[#problems + 1] = string.format(
            "entry %s: cannot read 'x:y' numbers from %q", entry.label, entry.text)
        elseif map_x then
          local mapped = map_x(x)
          if not is_finite(mapped) then
            problems[#problems + 1] = string.format(
              "entry %s: x=%s is outside the range this curve can use", entry.label, tostring(x))
          elseif seen[mapped] then
            problems[#problems + 1] = string.format(
              "entry %s: duplicate node at x=%s (ignored)", entry.label, tostring(x))
          else
            seen[mapped] = true
            nodes[#nodes + 1] = { x = mapped, y = y }
          end
        elseif seen[x] then
          problems[#problems + 1] = string.format(
            "entry %s: duplicate node at x=%s (ignored)", entry.label, tostring(x))
        else
          seen[x] = true
          nodes[#nodes + 1] = { x = x, y = y }
        end
      end
    end
  end

  table.sort(nodes, function(a, b) return a.x < b.x end)
  return nodes, problems
end

--- Has the owner edited a map away from the shipped default? Compared as parsed
--- nodes, not as text: a re-formatted or re-ordered map that means the same
--- curve is not an edit, and only a real edit makes the map win over the sliders
--- (Phase 6 precedence). Pure, so the precedence rule is testable offline.
function M.map_is_custom(items, defaults)
  local got = M.parse_nodes(items)
  local want = M.parse_nodes(defaults)
  if #got == 0 then
    -- Nothing parseable is not an edit worth honouring; the sliders take over.
    return false
  end
  if #got ~= #want then return true end
  for i = 1, #want do
    if got[i].x ~= want[i].x or got[i].y ~= want[i].y then return true end
  end
  return false
end

--- Build a node list from per-node slider thresholds and fixed outputs (Phase 6).
--
-- `thresholds[i]` is the ambient reading the owner slid node i to; `fixed_ys[i]`
-- is the output that node always puts out. The pairs travel together, so sliding
-- a node past its neighbour simply swaps two steps of the curve -- the shape is
-- never in question.
--
-- Crossing sliders must not be able to break the interpolation, so after sorting
-- by threshold the x values are repaired to strictly increasing
-- (`x[i] = max(x[i], x[i-1] + 1)`). A repair is rare and worth one log line.
--
-- `opts.map_x` (optional) transforms the x domain after sorting and repair --
-- the brightness curve passes log10(x + 1), exactly as parse_nodes does.
--
-- Returns `nodes` (ascending, unique x) and `problems`. Like parse_nodes this
-- never raises: an unusable slider value costs one node and one log line.
function M.buildNodes(thresholds, fixed_ys, opts)
  opts = opts or {}
  local map_x = opts.map_x
  local nodes, problems = {}, {}
  if type(thresholds) ~= "table" or type(fixed_ys) ~= "table" then
    problems[#problems + 1] = "thresholds and outputs must both be lists"
    return nodes, problems
  end

  -- Pair each output with its threshold before anything else can reorder them.
  local n = #fixed_ys
  if #thresholds ~= n then
    problems[#problems + 1] = string.format(
      "%d thresholds for %d fixed outputs (using the first %d of each)",
      #thresholds, n, math.min(#thresholds, n))
    n = math.min(#thresholds, n)
  end
  for i = 1, n do
    local x, y = thresholds[i], fixed_ys[i]
    if not is_finite(x) or not is_finite(y) then
      problems[#problems + 1] = string.format(
        "node %d: threshold %s or output %s is not a number (node dropped)",
        i, tostring(x), tostring(y))
    else
      nodes[#nodes + 1] = { x = x, y = y }
    end
  end

  table.sort(nodes, function(a, b) return a.x < b.x end)

  local repaired = 0
  for i = 2, #nodes do
    if nodes[i].x <= nodes[i - 1].x then
      nodes[i].x = nodes[i - 1].x + 1
      repaired = repaired + 1
    end
  end
  if repaired > 0 then
    problems[#problems + 1] = string.format(
      "%d threshold(s) collided when sorted; nodes re-spaced to strictly increasing", repaired)
  end

  if map_x then
    local kept = {}
    for i, node in ipairs(nodes) do
      local mapped = map_x(node.x)
      if not is_finite(mapped) then
        problems[#problems + 1] = string.format(
          "node %d: x=%s is outside the range this curve can use", i, tostring(node.x))
      else
        node.x = mapped
        kept[#kept + 1] = node
      end
    end
    nodes = kept
  end

  return nodes, problems
end

-- ── the hidden temperature anchors ─────────────────────────────────

--- The four hidden anchor nodes of the temperature curve: two below the first
--- row, two above the last, each replicating that endpoint's output. Never
--- shown -- the settings page and the map editor see the ten rows -- but
--- compile() sees fourteen, and that is what keeps floor and ceiling flat:
--- PCHIP pins a zero tangent on a replicated run, so the curve eases out of
--- 5100 K and into 6500 K exactly as the old visible duplicate triples did.
--- Offsets mirror the legacy pairs (2500/2700 below a 3000 start, 6000/6500
--- above a 5500 end). The input list is left untouched.
function M.with_anchors(nodes)
  local n = nodes and #nodes or 0
  if n == 0 then return nodes end
  local first, last = nodes[1], nodes[n]
  if not is_finite(first.x) or not is_finite(first.y)
      or not is_finite(last.x) or not is_finite(last.y) then
    return nodes
  end
  local out = {
    { x = first.x - 500, y = first.y },
    { x = first.x - 300, y = first.y },
  }
  for i = 1, n do out[#out + 1] = nodes[i] end
  out[#out + 1] = { x = last.x + 500, y = last.y }
  out[#out + 1] = { x = last.x + 1000, y = last.y }
  return out
end

-- ── interpolation ────────────────────────────────────────────────────────────

--- Precompute tangents for a node list. Returns nil for an empty list.
--
-- `nodes` must already be ascending with unique x. Duplicated or descending x
-- makes the tangent maths meaningless, so it is rejected rather than guessed at.
function M.compile(nodes)
  local n = nodes and #nodes or 0
  if n == 0 then return nil end

  local c = { n = n, x = {}, y = {}, h = {}, d = {}, m = {} }
  for i = 1, n do
    c.x[i] = nodes[i].x
    c.y[i] = nodes[i].y
    if not is_finite(c.x[i]) or not is_finite(c.y[i]) then return nil end
  end

  if n == 1 then
    c.m[1] = 0 -- a single node is a constant, not an error: the owner may be mid-edit
    return c
  end

  for i = 1, n - 1 do
    c.h[i] = c.x[i + 1] - c.x[i]
    if c.h[i] <= 0 then return nil end
    c.d[i] = (c.y[i + 1] - c.y[i]) / c.h[i]
  end

  -- One-sided differences at the ends. Together with the harmonic-mean interior
  -- tangents below, every interval satisfies the Fritsch-Carlson monotonicity
  -- region, which is what makes the no-overshoot guarantee hold rather than be
  -- hoped for.
  c.m[1] = c.d[1]
  c.m[n] = c.d[n - 1]

  for i = 2, n - 1 do
    local d0, d1 = c.d[i - 1], c.d[i]
    if d0 * d1 <= 0 then
      -- A sign change (or a flat run) is a local extremum. A zero tangent pins the
      -- curve exactly on the node there, and that is precisely what stops the
      -- interpolation from inventing a bump between two nodes.
      c.m[i] = 0
    else
      local h0, h1 = c.h[i - 1], c.h[i]
      local w1, w2 = 2 * h1 + h0, h1 + 2 * h0
      c.m[i] = (w1 + w2) / (w1 / d0 + w2 / d1)
    end
  end

  return c
end

--- Evaluate a compiled curve at x. Outside the node range this holds the end
-- value flat, so the curve is defined for every input.
function M.eval(c, x)
  if c == nil or x == nil or x ~= x then return nil end
  local n = c.n
  if n == 1 then return c.y[1] end
  if x <= c.x[1] then return c.y[1] end
  if x >= c.x[n] then return c.y[n] end

  -- n is the number of nodes the owner typed (10 by default), so a linear scan
  -- beats a binary search and keeps the function small enough to reason about.
  local i = 1
  while i < n - 1 and x > c.x[i + 1] do i = i + 1 end

  local h = c.h[i]
  local t = (x - c.x[i]) / h
  local t2 = t * t
  local t3 = t2 * t

  local h00 = 2 * t3 - 3 * t2 + 1
  local h10 = t3 - 2 * t2 + t
  local h01 = -2 * t3 + 3 * t2
  local h11 = t3 - t2

  return c.y[i] * h00 + h * c.m[i] * h10 + c.y[i + 1] * h01 + h * c.m[i + 1] * h11
end

--- Is the node list non-decreasing in y? Used only to warn once, never to edit.
--
-- If the owner's numbers make the value fall as x rises, the curve is honoured as
-- written: silently monotone-ising their numbers would be the worst possible
-- behaviour for a curve they are trying to tune. They get a log line instead.
function M.is_monotone(nodes)
  if nodes == nil then return true end
  for i = 2, #nodes do
    if nodes[i].y < nodes[i - 1].y then return false end
  end
  return true
end

return M
