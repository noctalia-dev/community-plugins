-- Declarative bar-widget smoke tests with a minimal Noctalia host.

local state = {}
local watchers = {}
local rendered = nil
local tooltip = nil
local toggledPanel = nil

local function node(kind, props, children)
  return { kind = kind, props = props or {}, children = children or {} }
end

ui = setmetatable({}, {
  __index = function(_table, kind)
    return function(props, children) return node(kind, props, children) end
  end,
})

barWidget = {
  render = function(tree) rendered = tree end,
  setTooltip = function(value) tooltip = value end,
  isVertical = function() return false end,
}

noctalia = {
  getConfig = function(key)
    local values = { warning_temperature = 65, critical_temperature = 50 }
    return values[key]
  end,
  tr = function(key, substitutions)
    local value = key
    for name, replacement in pairs(substitutions or {}) do
      value = value:gsub("{" .. name .. "}", tostring(replacement))
    end
    return value
  end,
  togglePanel = function(id) toggledPanel = id end,
  state = {
    get = function(key) return state[key] end,
    watch = function(key, callback) watchers[key] = callback end,
  },
}

state.snapshot = {
  summary = {
    disk_count = 3,
    ssd_count = 2,
    hdd_count = 1,
    hottest_drive_temperature_c = 60,
    hottest_ssd_temperature_c = 60,
    worst_ssd_remaining_life_percent = 90,
    ssd_smart_unavailable_count = 0,
    ssd_unhealthy_count = 0,
    smart_unavailable_count = 0,
    unhealthy_count = 0,
    active_alert_count = 0,
    critical_alert_count = 0,
  },
  issues = {},
}

local handle = assert(io.open("widget.luau", "rb"))
local source = handle:read("*a")
handle:close()
source = source:gsub("([%a_][%w_]*) %.%.= ([^\n]+)", "%1 = %1 .. %2")
assert(load(source, "@widget.luau"))()

local function findNodeWithProp(value, kind, property, expected)
  if type(value) ~= "table" then return nil end
  if value.kind == kind and type(value.props) == "table" and value.props[property] == expected then
    return value
  end
  for _, child in pairs(value.children or {}) do
    local found = findNodeWithProp(child, kind, property, expected)
    if found ~= nil then return found end
  end
  return nil
end

update()
assert(rendered ~= nil and tooltip:find("widget.no_alerts", 1, true), "healthy widget did not render")
assert(findNodeWithProp(rendered, "glyph", "name", "server-2") ~= nil,
  "healthy widget did not use the physical-storage icon")
assert(findNodeWithProp(rendered, "glyph", "color", "primary") ~= nil,
  "invalid cross-setting temperature thresholds produced a false critical state")

state.snapshot.summary.hottest_drive_temperature_c = 70
watchers.snapshot(state.snapshot)
assert(findNodeWithProp(rendered, "glyph", "color", "error") ~= nil,
  "HDD temperature was excluded from the mixed-drive widget state")
state.snapshot.summary.hottest_drive_temperature_c = 60
state.snapshot.summary.unhealthy_count = 1
watchers.snapshot(state.snapshot)
assert(findNodeWithProp(rendered, "glyph", "color", "error") ~= nil,
  "unhealthy HDD was excluded from the mixed-drive widget state")
state.snapshot.summary.unhealthy_count = 0

state.snapshot.summary.active_alert_count = 1
state.snapshot.summary.critical_alert_count = 1
state.snapshot.issues = { { message = "Fixture failure", severity = "critical" } }
watchers.snapshot(state.snapshot)
assert(findNodeWithProp(rendered, "glyph", "color", "error") ~= nil,
  "critical widget alert did not render")
assert(tooltip:find("Fixture failure", 1, true), "widget tooltip omitted active alert details")

onClick()
assert(toggledPanel == "gustav0ar/drive-health:drives", "widget click did not toggle its panel")

print("widget rendering tests passed")
