-- Uses the actual widget code with mocked host APIs, no live state or actions.
-- Run from the project root: lua tests/test_widget.lua.
dofile("tests/test_runtime.lua")
local config, watcher, tree, tooltip, shown, vertical = {}, nil, nil, nil, nil, false
local renders = 0
local openedPanel
ui = setmetatable({}, {
  __index = function(_, kind)
    return function(props, children)
      return { kind = kind, props = props, children = children or {} }
    end
  end,
})
barWidget = {
  render = function(n)
    renders = renders + 1
    tree = n
  end,
  setVisible = function(v)
    shown = v
  end,
  setTooltip = function(rows)
    tooltip = rows
  end,
  isVertical = function()
    return vertical
  end,
}
local data =
  { devices = { { name = "Phone", online = true, battery = { level = 67, charging = true } } } }
noctalia = {
  togglePanel = function(id)
    openedPanel = id
  end,
  getConfig = function(k)
    return config[k]
  end,
  setUpdateInterval = function() end,
  json = {
    decode = function(v)
      return v
    end,
  },
  state = {
    get = function()
      return data
    end,
    watch = function(_, cb)
      watcher = cb
    end,
  },
}
dofile("widget.luau")
update()
assert(shown and #tree.children == 3)
local before = renders
watcher(data)
update()
assert(renders == before)
data.page = { items = { { title = "Unrelated message" } } }
watcher(data)
assert(renders == before)
local battery = data.devices[1].battery
assert(#tooltip == 2 and tooltip[2].value == "Charging", "old API has no estimate")
battery.fullInMinutes = 35
watcher(data)
assert(renders == before + 1 and #tree.children == 3)
assert(tooltip[3].key == "Time to full" and tooltip[3].value == "≈ 35 min")
battery.charging = false
watcher(data)
assert(#tooltip == 2 and tooltip[2].value == "On battery")
battery.charging, battery.fullInMinutes = true, "35"
watcher(data)
assert(#tooltip == 2, "malformed estimates must not be shown")
battery.fullInMinutes = 60
watcher(data)
assert(tooltip[3].value == "≈ 1 h")
data.devices[1].online = false
watcher(data)
assert(#tooltip == 1, "an offline phone must not display a stale estimate")
data.devices[1].online = true
watcher(data)
config.show_percentage = false
config.show_charging = false
onConfigChanged()
assert(#tree.children == 1)
config.show_name = true
onConfigChanged()
assert(#tree.children == 2)
assert(tree.children[2].props.text == "Phone")
vertical = true
onConfigChanged()
assert(#tree.children == 1)
config.hide_offline = true
watcher({ devices = {} })
assert(not shown)
config.hide_offline = false
onConfigChanged()
assert(shown)
onClick()
assert(openedPanel == "vladikchi/nectarlink:controls")
openedPanel = nil
onRightClick()
assert(openedPanel == "vladikchi/nectarlink:controls")
print("PASS: widget percentage, charging, name, vertical layout, offline visibility, live settings")
