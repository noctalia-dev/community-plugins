--!nonstrict
-- The panel's unsaved draft: same shape as the saved state (lib/writer.luau).
-- An option is "managed" (written to the file) once it has an entry in
-- draft.options; untouched options keep whatever Hyprland has.
-- `monitors` (lib/monitors.luau) is passed in, as with writer.

local M = {}

function M.copy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = M.copy(x) end
  return t
end

function M.equal(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    if type(a) == "number" and type(b) == "number" then return math.abs(a - b) < 1e-9 end
    return a == b
  end
  for k, v in pairs(a) do
    if not M.equal(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

-- What a control shows: the draft value, else the live value.
function M.value(draft, live, path)
  local entry = draft.options and draft.options[path]
  if entry ~= nil then return entry.value end
  return live.values and live.values[path]
end

function M.setOption(draft, path, value)
  draft.options = draft.options or {}
  local entry = draft.options[path] or {}
  entry.value = value
  draft.options[path] = entry
end

function M.setWhy(draft, path, why)
  local entry = draft.options and draft.options[path]
  if entry ~= nil then entry.why = why ~= "" and why or nil end
end

-- Undo this row's unsaved change: back to what is saved (or unmanaged).
function M.revertOption(draft, saved, path)
  draft.options = draft.options or {}
  draft.options[path] = M.copy(saved.options and saved.options[path])
end

-- Back to "not written by this plugin".
function M.unmanage(draft, path)
  if draft.options then draft.options[path] = nil end
end

-- Slider values arrive as text; snap them to the option's step.
function M.snap(option, text)
  local v = tonumber(text)
  if v == nil then return nil end
  local step = option.step or 1
  v = math.round(v / step) * step
  v = math.clamp(v, option.min or v, option.max or v)
  return tonumber(string.format("%.4f", v))
end

-- ---------------------------------------------------------------- monitors

-- The rule Hyprland is effectively using for a connected monitor right now.
function M.ruleFromLive(monitors, monitor, connected)
  local mode = nil
  for _, available in ipairs(monitor.availableModes or {}) do
    local w, h, hz = monitors.parseMode(available)
    if w == monitor.width and h == monitor.height and math.abs(hz - monitor.refreshRate) < 0.5 then
      mode = monitors.ruleMode(available)
    end
  end
  return {
    output = monitors.ruleOutput(monitor, connected),
    mode = mode or "preferred",
    position = string.format("%dx%d", monitor.x, monitor.y),
    scale = monitor.scale,
    transform = monitor.transform ~= 0 and monitor.transform or nil,
    disabled = monitor.disabled or nil,
  }
end

-- One entry per connected monitor: { monitor, rule (a copy), managed }.
-- Enabled ones first, left to right; disabled ones after.
function M.monitorRows(monitors, draft, live)
  local rows = {}
  for _, monitor in ipairs(live.monitors or {}) do
    local rule = monitors.ruleFor(draft.monitors or {}, monitor)
    table.insert(rows, {
      monitor = monitor,
      rule = M.copy(rule or M.ruleFromLive(monitors, monitor, live.monitors)),
      managed = rule ~= nil,
    })
  end
  local function x(row)
    return tonumber(row.rule.position:match("^(%-?%d+)x")) or row.monitor.x
  end
  table.sort(rows, function(a, b)
    if (a.rule.disabled or false) ~= (b.rule.disabled or false) then return not a.rule.disabled end
    if x(a) ~= x(b) then return x(a) < x(b) end
    return a.monitor.name < b.monitor.name
  end)
  return rows
end

-- Rules for saved screens that are not plugged in (kept, shown, removable).
function M.offlineRules(monitors, draft, live)
  local list = {}
  for index, rule in ipairs(draft.monitors or {}) do
    local connected = false
    for _, monitor in ipairs(live.monitors or {}) do
      if monitors.matches(rule.output, monitor) then connected = true end
    end
    if not connected then table.insert(list, { index = index, rule = rule }) end
  end
  return list
end

function M.removeRule(draft, index)
  table.remove(draft.monitors, index)
end

-- Is every enabled screen at y=0 in one row? Otherwise the panel warns
-- that the first change lays them out as a row.
function M.isRow(rows)
  for _, row in ipairs(rows) do
    if not row.rule.disabled and not row.rule.position:match("^%-?%d+x0$") then return false end
  end
  return true
end

-- Changes one connected monitor (patch = fields of its rule, or
-- { move = -1|1 }) and lays all enabled ones out as a row again. Every
-- connected monitor then has a rule in the draft. Returns true or nil, err.
function M.changeMonitor(monitors, draft, live, name, patch)
  local rows = M.monitorRows(monitors, draft, live)
  local index = nil
  for i, row in ipairs(rows) do
    if row.monitor.name == name then index = i end
  end
  if index == nil then return nil, "no monitor " .. tostring(name) end
  local rule = rows[index].rule
  for k, v in pairs(patch) do
    if k ~= "move" then rule[k] = v end
  end
  if rule.transform == 0 then rule.transform = nil end
  if rule.disabled == false then rule.disabled = nil end
  if patch.move then
    local other = index + patch.move
    if rows[other] == nil or rows[other].rule.disabled or rule.disabled then return nil, "cannot move" end
    rows[index], rows[other] = rows[other], rows[index]
  end

  local order = {}
  for _, row in ipairs(rows) do
    if not row.rule.disabled then
      table.insert(order, { mode = row.rule.mode, scale = row.rule.scale, transform = row.rule.transform, monitor = row.monitor })
    end
  end
  local positions, err = monitors.layout(order)
  if positions == nil then return nil, err end
  local n = 0
  for _, row in ipairs(rows) do
    if not row.rule.disabled then
      n += 1
      row.rule.position = positions[n]
    end
  end

  draft.monitors = draft.monitors or {}
  for _, row in ipairs(rows) do
    local existing = nil
    for i, r in ipairs(draft.monitors) do
      if monitors.matches(r.output, row.monitor) then existing = i end
    end
    if existing then draft.monitors[existing] = row.rule else table.insert(draft.monitors, row.rule) end
  end
  return true
end

-- Scales from 0.5 to 3 that give whole pixels for a mode, plus the current one.
function M.scales(monitors, mode, current)
  local list = {}
  for i = 10, 60 do
    local s = i * 0.05
    s = tonumber(string.format("%.2f", s))
    if monitors.logicalSize(mode, s, 0) then table.insert(list, s) end
  end
  if current and not table.find(list, current) then table.insert(list, current); table.sort(list) end
  return list
end

return M
