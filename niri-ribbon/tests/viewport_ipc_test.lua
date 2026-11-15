-- Run from the repository root: lua niri-ribbon/tests/viewport_ipc_test.lua
-- Exercises the real service and widget entries with mocked IPC and shared state.
local function near(a, b) assert(math.abs(a - b) < 1e-9, tostring(a) .. ' ~= ' .. tostring(b)) end
local now, event, watch, tree, state = 0, nil, nil, nil, {}
local queries, publishes = 0, 0
local data = {
  outputs = { DP = { logical = { width = 200 } } },
  workspaces = { {id = 1, output = 'DP', is_active = true, is_focused = true, active_window_id = 3} },
  windows = {},
}
for i = 1, 4 do
  data.windows[i] = {id = i, workspace_id = 1, layout = {
    pos_in_scrolling_layout = {i, 1}, tile_size = {100, 100},
  }}
end
-- Only the second column reports a visible position: canvas x 110 - view x 0 = 110.
data.windows[2].layout.tile_pos_in_workspace_view = {0, 12}
local service = setmetatable({noctalia = {
  commandExists = function() return true end,
  nowMs = function() return now end,
  setUpdateInterval = function() end,
  json = {decode = function(value) return value end},
  runStream = function(_, callback) event = callback; return true end,
  runAsync = function(cmd, callback)
    queries = queries + 1
    callback({exitCode = 0, stdout = data[cmd:match('(%w+)$')]})
    return true
  end,
  state = {set = function(key, value)
    state[key] = value
    if key == 'output:DP' then publishes = publishes + 1; if watch then watch(value) end end
  end},
}}, {__index = _G})
assert(loadfile('niri-ribbon/service.luau', 't', service))()
local function flush() now = now + 33; service.update() end
flush()
assert(queries == 3)
assert(state['output:DP'].windows[2].layout.tile_pos_in_workspace_view[1] == 0)
assert(state['output:DP'].windows[2].layout.tile_pos_in_workspace_view[2] == nil)
local widget = setmetatable({noctalia = {
  getConfig = function(key)
    return ({animation_speed = 0, show_active_window = true, gaps = 10, viewport_model = 'center'})[key]
  end,
  setUpdateInterval = function() end,
  state = {get = function(key) return state[key] end, watch = function(_, callback) watch = callback end},
}, ui = {
  box = function(props) return props end,
  row = function(props, children) props.children = children; return props end,
}, barWidget = {
  outputName = function() return 'DP' end,
  render = function(value)
    tree = value
    local function check(node)
      assert(node.width >= -1e-9)
      if node.children then
        local total = 0
        for _, child in ipairs(node.children) do total = total + child.width; check(child) end
        near(total, node.width)
      end
    end
    check(tree)
  end,
}}, {__index = _G})
assert(loadfile('niri-ribbon/ribbon.luau', 't', widget))()
local function expect(offset)
  near(tree.children[1].width, 80 * offset / 430)
  near(tree.children[2].width, 80 * 200 / 430)
end
expect(110) -- reported position overrides center model's 170
near(tree.children[2].children[2].width, 80 * 90 / 430) -- active tile clipped to viewport
local function position(x, y)
  event({WindowLayoutsChanged = {changes = {{2, {
    pos_in_scrolling_layout = {2, 1}, tile_size = {100, 100},
    tile_pos_in_workspace_view = x ~= nil and {x, y or 0} or nil,
  }}}}})
  flush()
end
local before = publishes
position(0, 99)
assert(publishes == before) -- vertical-only movement stays filtered
position(-20); expect(130) -- scrolling without any focus/size change
assert(queries == 3) -- no added query/polling costs
-- A floating active window must not prevent another visible tile anchoring the view.
event({WorkspaceActiveWindowChanged = {workspace_id = 1, active_window_id = 99}})
flush(); expect(130)
position(-40); expect(150)
near(tree.children[2].children[2].width, 0)
-- Missing/null positions invalidate the old x; center fallback is used again.
event({WorkspaceActiveWindowChanged = {workspace_id = 1, active_window_id = 3}})
position(nil); expect(170)
assert(state['output:DP'].windows[2].layout.tile_pos_in_workspace_view == nil)
-- Malformed/nonfinite values are treated as unavailable.
for _, value in ipairs({'bad', math.huge, -math.huge, 0/0}) do position(value); expect(170) end
position(500); expect(0) -- padded left edge stays inside the ribbon
position(-500); expect(230) -- right edge also stays bounded
-- Full snapshots and window updates preserve the field as well as layout events.
local win = data.windows[2]
win.layout.tile_pos_in_workspace_view = {30, 0}
event({WindowOpenedOrChanged = {window = win}}); flush(); expect(80)
event({WindowsChanged = {windows = data.windows}}); flush(); expect(80)
-- Old niri snapshots have no position: both legacy estimation models still work.
for _, w in ipairs(data.windows) do w.layout.tile_pos_in_workspace_view = nil end
event({WindowsChanged = {windows = data.windows}}); flush(); expect(170)
widget.noctalia.getConfig = function(key)
  return ({animation_speed = 0, gaps = 10, viewport_model = 'fit'})[key]
end
assert(loadfile('niri-ribbon/ribbon.luau', 't', widget))()
expect(130)
print('PASS: position IPC snapshots/events, zero/negative x, off-screen fallback, floating focus, clipping, legacy models, no extra queries')
