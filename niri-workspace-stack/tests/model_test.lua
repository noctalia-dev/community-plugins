-- Unit + property tests for lib/model.luau, lib/view.luau and lib/niri.luau's resync,
-- under plain Lua 5.4 (the plugin sources stay in the common Lua/Luau subset).
-- Run from anywhere:  lua5.4 tests/model_test.lua

local root = (arg and arg[0] and arg[0]:match("^(.*)/tests/[^/]*$")) or "."

-- Minimal stand-in for Noctalia's relative require(): resolves against the requiring file.
local cache = {}
local function load(path)
  if cache[path] == nil then
    local dir = path:match("^(.*)/[^/]*$")
    local chunk = assert(loadfile(path, "t", setmetatable({
      require = function(rel)
        local target = dir .. "/" .. rel:gsub("^%./", "")
        return load(target)
      end,
    }, { __index = _G })))
    cache[path] = chunk()
  end
  return cache[path]
end

local Model = load(root .. "/lib/model.luau")
local View = load(root .. "/lib/view.luau")

local failures, total = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. "\n     " .. tostring(err))
  end
end
local function eq(actual, expected, what)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
  end
end
local function ids(list)
  local out = {}
  for i, item in ipairs(list) do
    out[i] = tostring(item.id)
  end
  return table.concat(out, ",")
end
local function countStates(list, field, value)
  local n = 0
  for _, item in ipairs(list) do
    if item[field] == value then n = n + 1 end
  end
  return n
end
local function noViolations(m, what)
  local v = m:violations()
  if #v > 0 then
    error((what or "invariants") .. ": " .. table.concat(v, "; "), 2)
  end
end

-- ── Fixture: the real two-monitor layout seen on DP-3 / DP-1 ────────────────

local function ws(id, idx, output, active, focused, name, activeWindow)
  return {
    id = id, idx = idx, output = output, is_active = active, is_focused = focused,
    name = name, active_window_id = activeWindow,
  }
end
local function win(id, wsId, col, tile, focused, appId)
  return {
    id = id,
    app_id = appId or ("app" .. id),
    title = "t" .. id,
    workspace_id = wsId,
    is_focused = focused or false,
    is_floating = col == nil,
    layout = { pos_in_scrolling_layout = col and { col, tile } or nil },
  }
end

local function fixture()
  local m = Model.new()
  m:apply({ WorkspacesChanged = { workspaces = {
    ws(1, 1, "DP-3", true, true, nil, 11), ws(3, 2, "DP-3", false, false), ws(4, 3, "DP-3", false, false),
    ws(38, 4, "DP-3", false, false), ws(2, 1, "DP-1", true, false, nil, 20), ws(35, 2, "DP-1", false, false),
  } } })
  m:apply({ WindowsChanged = { windows = {
    win(10, 1, 2, 1), win(11, 1, 1, 1, true), win(12, 1, nil, nil), win(13, 1, 1, 2),
    win(20, 2, 1, 1), win(21, 2, 2, 1), win(30, 3, 1, 1),
  } } })
  return m
end

local OPTS = { visibleWorkspaces = 3, maxWindows = 0, showEmpty = true }

-- ── Regression tests for the bugs seen live ─────────────────────────────────

test("BUG#1 a nil output selects nothing instead of every output", function()
  local m = fixture()
  eq(#m:workspacesOn(nil), 0, "workspacesOn(nil)")
  eq(m:activeWorkspaceOn(nil), nil, "activeWorkspaceOn(nil)")
  local v = View.build(m, nil, OPTS)
  eq(#v.workspaces, 0, "view workspaces")
  eq(#v.windows, 0, "view windows")
end)

test("BUG#1 each output's view shows only its own workspaces and windows", function()
  local m = fixture()
  local a, b = View.build(m, "DP-3", OPTS), View.build(m, "DP-1", OPTS)
  eq(ids(a.workspaces), "1,3,4", "DP-3 stack (first 3 by idx)")
  eq(a.hiddenBelow, 1, "DP-3 hidden below")
  eq(ids(a.windows), "11,13,10,12", "DP-3 windows")
  eq(ids(b.workspaces), "2,35", "DP-1 stack")
  eq(ids(b.windows), "20,21", "DP-1 windows")
end)

test("BUG#1 exactly one active indicator per view", function()
  local m = fixture()
  for _, out in ipairs({ "DP-3", "DP-1" }) do
    local n = 0
    for _, w in ipairs(View.build(m, out, OPTS).workspaces) do
      if w.active then n = n + 1 end
    end
    eq(n, 1, out .. " active count")
  end
end)

test("BUG#2 focus is a single id: switching never leaves two focused windows", function()
  local m = fixture()
  for _, target in ipairs({ 10, 13, 20, 11, 12 }) do
    m:apply({ WindowFocusChanged = { id = target } })
    local focused = 0
    for _, out in ipairs({ "DP-3", "DP-1" }) do
      for _, w in ipairs(View.build(m, out, OPTS).windows) do
        if w.state == "focused" then focused = focused + 1 end
      end
    end
    eq(focused, 1, "focused icons after focusing " .. target)
  end
end)

test("focused highlight only on the focused output; others mark their current window", function()
  local m = fixture()
  local a, b = View.build(m, "DP-3", OPTS), View.build(m, "DP-1", OPTS)
  eq(a.isFocusedOutput, true, "DP-3 focused")
  eq(b.isFocusedOutput, false, "DP-1 not focused")
  for _, w in ipairs(b.windows) do
    eq(w.state ~= "focused", true, "DP-1 window " .. w.id .. " focused")
  end
  eq(b.windows[1].state, "current", "DP-1 current window 20")
end)

-- ── Event semantics (niri-ipc/src/state.rs) ─────────────────────────────────

test("switching the focused output", function()
  local m = fixture()
  m:apply({ WorkspaceActivated = { id = 2, focused = true } })
  m:apply({ WindowFocusChanged = { id = 20 } })
  eq(m:focusedOutput(), "DP-1", "focused output")
  eq(m:activeWorkspaceOn("DP-3").id, 1, "DP-3 keeps its active workspace")
  eq(View.build(m, "DP-3", OPTS).isFocusedOutput, false, "DP-3 view")
  noViolations(m)
end)

test("WorkspaceActivated focused=false changes only that output", function()
  local m = fixture()
  m:apply({ WorkspaceActivated = { id = 35, focused = false } })
  eq(m:activeWorkspaceOn("DP-1").id, 35, "DP-1 active")
  eq(m:focusedOutput(), "DP-3", "focus stays")
  noViolations(m)
end)

test("moving a window to another workspace on another output", function()
  local m = fixture()
  m:apply({ WindowOpenedOrChanged = { window = win(10, 2, 3, 1, false) } })
  eq(ids(View.build(m, "DP-3", OPTS).windows), "11,13,12", "DP-3 lost it")
  eq(ids(View.build(m, "DP-1", OPTS).windows), "20,21,10", "DP-1 gained it")
  eq(m.focusedWindowId, 11, "focus untouched")
end)

test("WindowOpenedOrChanged of the focused window with is_focused=false drops focus", function()
  local m = fixture()
  m:apply({ WindowOpenedOrChanged = { window = win(11, 3, 1, 1, false) } })
  eq(m.focusedWindowId, nil, "focus dropped")
  m:apply({ WindowOpenedOrChanged = { window = win(40, 1, 5, 1, true) } })
  eq(m.focusedWindowId, 40, "new window focused")
end)

test("moving a workspace between outputs re-indexes both (WorkspacesChanged)", function()
  local m = fixture()
  -- ws 3 moves DP-3 -> DP-1: niri re-sends the full list with new idx/output
  m:apply({ WorkspacesChanged = { workspaces = {
    ws(1, 1, "DP-3", true, true, nil, 11), ws(4, 2, "DP-3", false, false), ws(38, 3, "DP-3", false, false),
    ws(2, 1, "DP-1", true, false, nil, 20), ws(3, 2, "DP-1", false, false), ws(35, 3, "DP-1", false, false),
  } } })
  eq(ids(m:workspacesOn("DP-3")), "1,4,38", "DP-3")
  eq(ids(m:workspacesOn("DP-1")), "2,3,35", "DP-1")
  eq(m.workspaces[3].idx, 2, "idx updated")
  noViolations(m)
end)

test("removal of an empty workspace leaves no ghost slot", function()
  local m = fixture()
  m:apply({ WorkspacesChanged = { workspaces = {
    ws(1, 1, "DP-3", true, true, nil, 11), ws(3, 2, "DP-3", false, false), ws(38, 3, "DP-3", false, false),
    ws(2, 1, "DP-1", true, false, nil, 20), ws(35, 2, "DP-1", false, false),
  } } })
  eq(m.workspaces[4], nil, "removed")
  eq(ids(m:workspacesOn("DP-3")), "1,3,38", "order")
  noViolations(m)
end)

test("reconnect: the new full state replaces, nothing is duplicated or kept", function()
  local m = fixture()
  -- stream ends; niri restarts with fresh ids
  m:apply({ NwsStreamEnd = {} })
  m:apply({ NwsStreamStart = {} })
  m:apply({ WorkspacesChanged = { workspaces = { ws(100, 1, "DP-3", true, true), ws(101, 1, "DP-1", true, false) } } })
  m:apply({ WindowsChanged = { windows = { win(200, 100, 1, 1, true) } } })
  local count = 0
  for _ in pairs(m.workspaces) do count = count + 1 end
  eq(count, 2, "workspaces")
  eq(ids(View.build(m, "DP-3", OPTS).windows), "200", "DP-3 windows")
  eq(#View.build(m, "DP-1", OPTS).windows, 0, "DP-1 windows")
  noViolations(m)
end)

test("floating windows are listed after tiled ones and keep their workspace", function()
  local m = fixture()
  eq(ids(m:windowsOf(1)), "11,13,10,12", "order")
  m:apply({ WindowLayoutsChanged = { changes = { { 10, { pos_in_scrolling_layout = { 0, 1 } } } } } })
  eq(ids(m:windowsOf(1)), "10,11,13,12", "after layout change")
end)

test("WindowFocusChanged null and WindowClosed", function()
  local m = fixture()
  eq(m:apply({ WindowFocusChanged = {} }), true, "null focus")
  eq(m.focusedWindowId, nil, "none")
  m:apply({ WindowFocusChanged = { id = 13 } })
  m:apply({ WindowClosed = { id = 13 } })
  eq(m.focusedWindowId, nil, "closed focused")
  eq(m:apply({ WindowClosed = { id = 999 } }), false, "unknown")
end)

test("WorkspaceActiveWindowChanged updates the current-window marker", function()
  local m = fixture()
  eq(m:apply({ WorkspaceActiveWindowChanged = { workspace_id = 2, active_window_id = 21 } }), true, "changed")
  local b = View.build(m, "DP-1", OPTS)
  eq(b.windows[1].state, "normal", "20")
  eq(b.windows[2].state, "current", "21")
end)

test("named workspaces use their name as label", function()
  local m = Model.new()
  m:apply({ WorkspacesChanged = { workspaces = { ws(5, 1, "DP-3", true, true, "web") } } })
  m:apply({ WindowsChanged = { windows = {} } })
  eq(View.build(m, "DP-3", OPTS).workspaces[1].label, "web", "label")
end)

test("visibleRange centers on active and never shows empty slots", function()
  local function r(c, a, v)
    local f, l = Model.visibleRange(c, a, v)
    return f .. "-" .. l
  end
  eq(r(5, 1, 3), "1-3", "top")
  eq(r(5, 3, 3), "2-4", "middle")
  eq(r(5, 5, 3), "3-5", "bottom")
  eq(r(2, 2, 3), "1-2", "fewer")
  eq(r(0, 1, 3), "1-0", "empty")
end)

-- ── Property test: a simulated niri emits events exactly like src/ipc/server.rs ──

local function simulate(seed, steps)
  math.randomseed(seed)
  local outputs = { "DP-3", "DP-1" }
  -- world truth
  local W = { mons = {}, windows = {}, focusedMon = 1, nextWs = 1, nextWin = 1 }
  for i, out in ipairs(outputs) do
    W.mons[i] = { name = out, ws = {}, active = 1 }
  end
  local function newWs(mon)
    local id = W.nextWs; W.nextWs = W.nextWs + 1
    table.insert(mon.ws, { id = id, activeWin = nil })
  end
  for _, mon in ipairs(W.mons) do newWs(mon); newWs(mon) end

  local function wsById(id)
    for mi, mon in ipairs(W.mons) do
      for i, w in ipairs(mon.ws) do
        if w.id == id then return mon, i, w, mi end
      end
    end
  end
  local function focusedWindow()
    local mon = W.mons[W.focusedMon]
    return mon.ws[mon.active].activeWin
  end
  -- niri keeps exactly one empty workspace at the end of every monitor and removes other
  -- empty, inactive ones
  local function normalize()
    for _, mon in ipairs(W.mons) do
      local i = 1
      while i <= #mon.ws do
        local w = mon.ws[i]
        local empty = true
        for _, x in pairs(W.windows) do if x.ws == w.id then empty = false end end
        if empty and i ~= mon.active and i ~= #mon.ws then
          table.remove(mon.ws, i)
          if mon.active > i then mon.active = mon.active - 1 end
        else
          i = i + 1
        end
      end
      local last = mon.ws[#mon.ws]
      local lastEmpty = true
      for _, x in pairs(W.windows) do if x.ws == last.id then lastEmpty = false end end
      if not lastEmpty then newWs(mon) end
      for _, w in ipairs(mon.ws) do
        if w.activeWin ~= nil and (W.windows[w.activeWin] == nil or W.windows[w.activeWin].ws ~= w.id) then
          w.activeWin = nil
          for id, x in pairs(W.windows) do if x.ws == w.id then w.activeWin = id end end
        end
      end
    end
  end

  -- ipc copies, as niri's server keeps them
  local ipcWs, ipcWin = {}, {}
  local events = {}
  local function emit(e) events[#events + 1] = e end

  local function refresh()
    normalize()
    -- workspaces (server.rs ipc_refresh_workspaces)
    local focusedWsId = W.mons[W.focusedMon].ws[W.mons[W.focusedMon].active].id
    local wsEvents, need, seen = {}, false, {}
    for _, mon in ipairs(W.mons) do
      for i, w in ipairs(mon.ws) do
        seen[w.id] = true
        local ipc = ipcWs[w.id]
        if ipc == nil or ipc.idx ~= i or ipc.output ~= mon.name then need = true end
        if not need then
          if ipc.active_window_id ~= w.activeWin then
            wsEvents[#wsEvents + 1] = { WorkspaceActiveWindowChanged = { workspace_id = w.id, active_window_id = w.activeWin } }
          end
          local isFocused = w.id == focusedWsId
          if isFocused and not ipc.is_focused then
            wsEvents[#wsEvents + 1] = { WorkspaceActivated = { id = w.id, focused = true } }
          elseif (mon.active == i) and not ipc.is_active then
            wsEvents[#wsEvents + 1] = { WorkspaceActivated = { id = w.id, focused = false } }
          end
        end
      end
    end
    for id in pairs(ipcWs) do if not seen[id] then need = true end end
    local snapshot = {}
    for _, mon in ipairs(W.mons) do
      for i, w in ipairs(mon.ws) do
        snapshot[#snapshot + 1] = ws(w.id, i, mon.name, mon.active == i, w.id == focusedWsId, nil, w.activeWin)
      end
    end
    if need then wsEvents = { { WorkspacesChanged = { workspaces = snapshot } } } end
    for _, e in ipairs(wsEvents) do emit(e) end
    ipcWs = {}
    for _, s in ipairs(snapshot) do ipcWs[s.id] = s end

    -- windows (server.rs ipc_refresh_windows)
    local fw = focusedWindow()
    local winSeen = {}
    -- as in server.rs, "had focus" is judged on the ipc copy *before* this refresh
    local hadFocus = false
    for _, ipc in pairs(ipcWin) do
      if ipc.is_focused then hadFocus = true end
    end
    for id, x in pairs(W.windows) do
      winSeen[id] = true
      local ipc = ipcWin[id]
      local record = win(id, x.ws, x.col, 1, id == fw)
      if ipc == nil or ipc.workspace_id ~= x.ws then
        emit({ WindowOpenedOrChanged = { window = record } })
      else
        if ipc.layout.pos_in_scrolling_layout and ipc.layout.pos_in_scrolling_layout[1] ~= x.col then
          emit({ WindowLayoutsChanged = { changes = { { id, record.layout } } } })
        end
        if id == fw and not ipc.is_focused then emit({ WindowFocusChanged = { id = id } }) end
      end
      ipcWin[id] = record
    end
    for id in pairs(ipcWin) do
      if not winSeen[id] then emit({ WindowClosed = { id = id } }); ipcWin[id] = nil end
    end
    if fw == nil and hadFocus then emit({ WindowFocusChanged = {} }) end
  end

  -- initial full state, as a new event-stream connection sees it
  normalize()
  refresh()
  events = {}
  local snapW, snapWin = {}, {}
  for _, s in pairs(ipcWs) do snapW[#snapW + 1] = s end
  for _, s in pairs(ipcWin) do snapWin[#snapWin + 1] = s end
  local m = Model.new()
  m:apply({ WorkspacesChanged = { workspaces = snapW } })
  m:apply({ WindowsChanged = { windows = snapWin } })

  local actions = {
    function() -- open a window on the focused workspace, focus it
      local mon = W.mons[W.focusedMon]
      local w = mon.ws[mon.active]
      local id = 1000 + W.nextWin; W.nextWin = W.nextWin + 1
      W.windows[id] = { ws = w.id, col = math.random(1, 4) }
      w.activeWin = id
    end,
    function() -- close the focused window
      local id = focusedWindow()
      if id then W.windows[id] = nil end
    end,
    function() -- focus another output
      W.focusedMon = 3 - W.focusedMon
    end,
    function() -- switch workspace on the focused output
      local mon = W.mons[W.focusedMon]
      mon.active = math.random(1, #mon.ws)
    end,
    function() -- move the focused window to a random workspace (any output)
      local id = focusedWindow()
      if not id then return end
      local mon = W.mons[math.random(1, 2)]
      local target = mon.ws[math.random(1, #mon.ws)]
      local _, _, from = wsById(W.windows[id].ws)
      if from then from.activeWin = nil end
      W.windows[id].ws = target.id
      target.activeWin = id
    end,
    function() -- focus a random window on the focused workspace
      local mon = W.mons[W.focusedMon]
      local w = mon.ws[mon.active]
      local cands = {}
      for id, x in pairs(W.windows) do if x.ws == w.id then cands[#cands + 1] = id end end
      if #cands > 0 then w.activeWin = cands[math.random(1, #cands)] end
    end,
    function() -- move the active workspace of the focused output to the other output
      local mon, other = W.mons[W.focusedMon], W.mons[3 - W.focusedMon]
      if #mon.ws < 2 or mon.active == #mon.ws then return end
      local moved = table.remove(mon.ws, mon.active)
      mon.active = math.min(mon.active, #mon.ws)
      table.insert(other.ws, #other.ws, moved)
      other.active = #other.ws - 1
      W.focusedMon = 3 - W.focusedMon
    end,
    function() -- column reorder
      for _, x in pairs(W.windows) do if math.random() < 0.3 then x.col = math.random(1, 4) end end
    end,
  }

  for step = 1, steps do
    actions[math.random(1, #actions)]()
    events = {}
    refresh()
    for _, e in ipairs(events) do m:apply(e) end

    -- model == world, per output
    local fw = focusedWindow()
    eq(m.focusedWindowId, fw, "seed " .. seed .. " step " .. step .. " focused window")
    eq(m:focusedOutput(), W.mons[W.focusedMon].name, "seed " .. seed .. " step " .. step .. " focused output")
    for _, mon in ipairs(W.mons) do
      local want = {}
      for _, w in ipairs(mon.ws) do want[#want + 1] = tostring(w.id) end
      eq(ids(m:workspacesOn(mon.name)), table.concat(want, ","), "seed " .. seed .. " step " .. step .. " " .. mon.name .. " order")
      eq(m:activeWorkspaceOn(mon.name).id, mon.ws[mon.active].id, "seed " .. seed .. " step " .. step .. " " .. mon.name .. " active")
      local view = View.build(m, mon.name, { visibleWorkspaces = 3, maxWindows = 0 })
      for _, vw in ipairs(view.windows) do
        eq(W.windows[vw.id].ws, mon.ws[mon.active].id, "seed " .. seed .. " step " .. step .. " window " .. vw.id .. " workspace")
      end
    end
    local focusedIcons, focusedDots = 0, 0
    for _, mon in ipairs(W.mons) do
      local view = View.build(m, mon.name, { visibleWorkspaces = 3, maxWindows = 0, showEmpty = true })
      eq(countStates(view.workspaces, "state", "active_focused") + countStates(view.workspaces, "state", "active") <= 1, true,
        "seed " .. seed .. " step " .. step .. " one active slot")
      eq(view.all[view.position].id, mon.ws[mon.active].id, "seed " .. seed .. " step " .. step .. " navigator position")
      focusedIcons = focusedIcons + countStates(view.windows, "state", "focused")
      for _, row in ipairs(View.miniMap(view, 4)) do
        focusedDots = focusedDots + countStates(row.dots, "state", "focused")
      end
    end
    local expected = (focusedWindow() ~= nil) and 1 or 0
    eq(focusedIcons, expected, "seed " .. seed .. " step " .. step .. " focused icons")
    eq(focusedDots <= expected, true, "seed " .. seed .. " step " .. step .. " focused dots")
    noViolations(m, "seed " .. seed .. " step " .. step)
  end
end

test("property: 200 seeds x 150 steps of simulated niri events keep model == world", function()
  for seed = 1, 200 do
    simulate(seed, 150)
  end
end)

-- ── resync: snapshot applied only if the stream stayed quiet ────────────────

test("resync retries when events arrive during the snapshot, applies when quiet", function()
  local pending = {}
  _G.noctalia = {
    log = function() end,
    runAsync = function(argv, cb) pending[#pending + 1] = { kind = argv[4], cb = cb }; return true end,
    json = { decode = function(s) return s end }, -- tests pass tables through
    string = { trim = function(s) return s end },
  }
  cache[root .. "/lib/niri.luau"] = nil
  local niri = load(root .. "/lib/niri.luau")
  local m = fixture()
  local applied = {}
  local function apply(e) applied[#applied + 1] = e; m:apply(e) end
  local function reply(kind, payload)
    for i, p in ipairs(pending) do
      if p.kind == kind then table.remove(pending, i); p.cb({ exitCode = 0, stdout = payload }); return end
    end
    error("no pending " .. kind)
  end
  niri.resync(m, apply)
  eq(#pending, 2, "two commands")
  m:apply({ WindowFocusChanged = { id = 10 } }) -- event lands mid-snapshot
  reply("workspaces", { ws(1, 1, "DP-3", true, true) })
  reply("windows", { win(11, 1, 1, 1, true) })
  eq(#applied, 0, "stale snapshot discarded")
  eq(#pending, 2, "retaken")
  reply("workspaces", { ws(1, 1, "DP-3", true, true) })
  reply("windows", { win(10, 1, 1, 1, true) })
  eq(#applied, 2, "quiet snapshot applied")
  eq(m.focusedWindowId, 10, "focus from snapshot")
  _G.noctalia = nil
end)

-- ── Derived data per display mode ───────────────────────────────────────────

test("rail/mini map: states distinguish active on focused vs unfocused output", function()
  local m = fixture()
  local a, b = View.build(m, "DP-3", OPTS), View.build(m, "DP-1", OPTS)
  eq(a.workspaces[1].state, "active_focused", "DP-3 ws1")
  eq(b.workspaces[1].state, "active", "DP-1 ws2 (unfocused output)")
  eq(a.workspaces[2].state, "occupied", "DP-3 ws3")
  eq(b.workspaces[2].state, "empty", "DP-1 ws35")
  m:apply({ WorkspaceActivated = { id = 2, focused = true } })
  a, b = View.build(m, "DP-3", OPTS), View.build(m, "DP-1", OPTS)
  eq(a.workspaces[1].state, "active", "DP-3 after focus moved")
  eq(b.workspaces[1].state, "active_focused", "DP-1 after focus moved")
end)

test("rail/mini map: hidden markers at top and bottom follow the active workspace", function()
  local m = fixture()
  local v = View.build(m, "DP-3", OPTS)
  eq(v.hiddenAbove, 0, "above at top")
  eq(v.hiddenBelow, 1, "below at top")
  m:apply({ WorkspaceActivated = { id = 38, focused = true } }) -- bottom workspace
  v = View.build(m, "DP-3", OPTS)
  eq(ids(v.workspaces), "3,4,38", "slice at bottom")
  eq(v.hiddenAbove, 1, "above at bottom")
  eq(v.hiddenBelow, 0, "below at bottom")
end)

test("mini map: dots per window, exactly one focused dot in the whole session", function()
  local m = fixture()
  local focusedDots = 0
  for _, out in ipairs({ "DP-3", "DP-1" }) do
    for _, row in ipairs(View.miniMap(View.build(m, out, OPTS), 4)) do
      focusedDots = focusedDots + countStates(row.dots, "state", "focused")
      if row.workspace.id == 1 then
        eq(#row.dots, 4, "ws1 dots capped")
        eq(row.more, false, "ws1 has exactly 4")
      end
      if row.workspace.id == 35 then
        eq(#row.dots, 0, "empty ws has no dots")
      end
    end
  end
  eq(focusedDots, 1, "focused dots")
  m:apply({ WindowOpenedOrChanged = { window = win(14, 1, 9, 1, false) } })
  local rows = View.miniMap(View.build(m, "DP-3", OPTS), 4)
  eq(rows[1].more, true, "5 windows -> more marker")
end)

test("mini map: the unfocused output marks only its current window, never 'focused'", function()
  local m = fixture()
  local rows = View.miniMap(View.build(m, "DP-1", OPTS), 4)
  eq(countStates(rows[1].dots, "state", "focused"), 0, "no focused dot on DP-1")
  eq(countStates(rows[1].dots, "state", "current"), 1, "one current dot on DP-1")
end)

test("a workspace never shows 'current' next to a 'focused' window (transient active_window_id)", function()
  local m = fixture()
  m:apply({ WindowFocusChanged = { id = 10 } }) -- ws1 active_window_id still says 11
  local states = {}
  for _, w in ipairs(View.build(m, "DP-3", OPTS).windows) do states[#states + 1] = w.state end
  eq(table.concat(states, ","), "normal,normal,focused,normal", "ws1 states")
end)

test("navigator: label, position and up/down availability", function()
  local m = fixture()
  local nav = View.navigator(View.build(m, "DP-3", OPTS))
  eq(nav.label, "1", "label")
  eq(nav.position .. "/" .. nav.total, "1/4", "position")
  eq(nav.hasAbove, false, "above")
  eq(nav.hasBelow, true, "below")
  m:apply({ WorkspaceActivated = { id = 4, focused = true } })
  nav = View.navigator(View.build(m, "DP-3", OPTS))
  eq(nav.position .. "/" .. nav.total, "3/4", "after switch")
  eq(nav.hasAbove and nav.hasBelow, true, "both")
end)

test("navigator list: every workspace of the output with windows, in niri order", function()
  local m = fixture()
  local v = View.build(m, "DP-3", { visibleWorkspaces = 99, maxWindows = 0, showEmpty = true })
  eq(ids(v.all), "1,3,4,38", "all")
  eq(ids(v.all[1].windows), "11,13,10,12", "ws1 windows")
  eq(table.concat(v.all[1].apps, ","), "app11,app13,app10,app12", "apps")
end)

test("show_empty=false drops empty inactive workspaces but never the active one", function()
  local m = fixture()
  local v = View.build(m, "DP-3", { visibleWorkspaces = 5, maxWindows = 0, showEmpty = false })
  eq(ids(v.all), "1,3", "DP-3 without empties") -- ws4 has no windows in the fixture, ws38 is niri's tail
  m:apply({ WorkspaceActivated = { id = 38, focused = true } })
  v = View.build(m, "DP-3", { visibleWorkspaces = 5, maxWindows = 0, showEmpty = false })
  eq(ids(v.all), "1,3,38", "active empty stays")
end)

test("wheel/navigator step targets the neighbour on this output, clamped", function()
  local m = fixture()
  local v = View.build(m, "DP-3", OPTS)
  eq(View.neighbor(v, -1), nil, "nothing above the top")
  eq(View.neighbor(v, 1).id, 3, "next down")
  m:apply({ WorkspaceActivated = { id = 38, focused = true } })
  eq(View.neighbor(View.build(m, "DP-3", OPTS), 1), nil, "nothing below the bottom")
end)

test("appName shortens reverse-DNS app ids", function()
  eq(View.appName("org.telegram.desktop"), "telegram", "telegram")
  eq(View.appName("firefox"), "firefox", "firefox")
  eq(View.appName("org.mozilla.firefox.webapp-6099"), "webapp-6099", "webapp")
  eq(View.appName(""), "?", "empty")
end)

-- ── Actions: commands for an unfocused output go through focus-monitor ───────

local function withNoctalia(fn)
  local calls = {}
  _G.noctalia = {
    log = function() end,
    runAsync = function(argv, cb) calls[#calls + 1] = table.concat(argv, " "); return true end,
    json = { decode = function(x) return x end },
    string = { trim = function(x) return x end },
  }
  cache[root .. "/lib/niri.luau"] = nil
  cache[root .. "/lib/actions.luau"] = nil
  local ok, err = pcall(fn, calls)
  _G.noctalia = nil
  if not ok then error(err, 0) end
end

test("actions: a click on the unfocused output's workspace focuses that monitor first", function()
  withNoctalia(function(calls)
    local Actions = load(root .. "/lib/actions.luau")
    local m = fixture()
    Actions.focusWorkspace(m, 35) -- DP-1, idx 2; focused output is DP-3
    eq(#calls, 1, "one command")
    eq(calls[1]:find("focus-monitor \"$1\"", 1, true) ~= nil and calls[1]:find("DP-1 2", 1, true) ~= nil, true, calls[1])
    Actions.focusWorkspace(m, 3) -- same output: plain index
    eq(calls[2], "niri msg action focus-workspace 2", "same output")
    eq(Actions.focusWorkspace(m, 1), false, "already focused: no command")
    Actions.step(m, View.build(m, "DP-1", OPTS), 1) -- wheel on DP-1's bar
    eq(calls[3]:find("DP-1 2", 1, true) ~= nil, true, "wheel targets DP-1: " .. calls[3])
    Actions.focusWindow(m, 20)
    eq(calls[4], "niri msg action focus-window --id 20", "window by id")
  end)
end)

-- ── Render smoke test with a fake ui.* ──────────────────────────────────────

local function fakeUi()
  local u = {}
  for _, kind in ipairs({ "row", "column", "scroll", "box", "label", "glyph", "image" }) do
    u[kind] = function(props, children)
      return { type = kind, props = props or {}, children = children or {} }
    end
  end
  return u
end

local function walk(node, fn, path)
  path = (path or "") .. "/" .. node.type .. ":" .. tostring(node.props.key)
  fn(node, path)
  for _, child in ipairs(node.children) do
    walk(child, fn, path)
  end
end

local function geometry(tree)
  local out = {}
  walk(tree, function(node, path)
    local p = node.props
    out[#out + 1] = path .. "=" .. tostring(p.width) .. "x" .. tostring(p.height) .. "/" .. tostring(p.padding or p.paddingH)
  end)
  return table.concat(out, "\n")
end

local function highlighted(tree)
  local n = 0
  walk(tree, function(node)
    if node.props.key and tostring(node.props.key):match("^win%-") and node.props.border == "primary" then n = n + 1 end
  end)
  return n
end

local function renderAll(m, Render, out)
  local ctx = {
    size = 1, iconSize = 18, gap = 3, compact = false, showWindows = true,
    iconFor = function() return nil end, onWorkspace = function() end, onWindow = function() end,
  }
  local v = View.build(m, out, OPTS)
  local strip = Render.windowStrip(ctx, v, false)
  return {
    numbered_rail = { type = "row", props = {}, children = { Render.numberBlock(ctx, v), Render.rail(ctx, v), strip } },
    mini_map = { type = "row", props = {}, children = { Render.numberBlock(ctx, v), Render.miniMap(ctx, v), strip } },
    navigator = { type = "row", props = {}, children = { Render.navigatorBadge(ctx, v), strip } },
    panel = Render.panelList(ctx, View.build(m, out, { visibleWorkspaces = 99, maxWindows = 0, showEmpty = true }), function() end),
  }
end

test("render: every mode sets fill/border explicitly, one focus highlight, stable geometry", function()
  _G.ui = fakeUi()
  _G.noctalia = {
    tr = function(key) return key end,
    trp = function(key) return key end,
  }
  cache[root .. "/lib/render.luau"] = nil
  local Render = load(root .. "/lib/render.luau")
  local m = fixture()
  local before = { ["DP-3"] = renderAll(m, Render, "DP-3"), ["DP-1"] = renderAll(m, Render, "DP-1") }

  for out, trees in pairs(before) do
    for mode, tree in pairs(trees) do
      walk(tree, function(node, path)
        local p = node.props
        if (node.type == "row" or node.type == "column") and p.onClick ~= nil then
          eq(p.fill ~= nil and p.border ~= nil and p.borderWidth ~= nil and p.opacity ~= nil, true, out .. " " .. mode .. " explicit style " .. path)
          eq(p.tooltip ~= nil and p.tooltip ~= "", true, out .. " " .. mode .. " tooltip " .. path)
        end
        -- labels whose width depends on content must always pass it (stale width otherwise)
        if node.type == "label" and p.key == "label" then
          eq(p.width ~= nil, true, out .. " " .. mode .. " label width explicit " .. path)
        end
      end)
    end
  end
  local total = 0
  for _, out in ipairs({ "DP-3", "DP-1" }) do total = total + highlighted(before[out].numbered_rail) end
  eq(total, 1, "one focused icon across both bars")

  -- focus moves inside DP-3, then to the other monitor: geometry must not change
  m:apply({ WindowFocusChanged = { id = 10 } })
  m:apply({ WorkspaceActivated = { id = 2, focused = true } })
  m:apply({ WindowFocusChanged = { id = 21 } })
  local after = { ["DP-3"] = renderAll(m, Render, "DP-3"), ["DP-1"] = renderAll(m, Render, "DP-1") }
  for out, trees in pairs(before) do
    for mode, tree in pairs(trees) do
      if mode ~= "panel" then
        eq(geometry(after[out][mode]), geometry(tree), out .. " " .. mode .. " geometry after focus change")
      end
    end
  end
  total = 0
  for _, out in ipairs({ "DP-3", "DP-1" }) do total = total + highlighted(after[out].mini_map) end
  eq(total, 1, "one focused icon after focus moved")
  _G.ui, _G.noctalia = nil, nil
end)

-- ── Named workspaces ────────────────────────────────────────────────────────

-- The fixture's workspaces with names (by id); niri reports a rename / unset as a full
-- WorkspacesChanged with the same ids.
local function namedWorkspaces(names)
  local list = {
    ws(1, 1, "DP-3", true, true, nil, 11), ws(3, 2, "DP-3", false, false), ws(4, 3, "DP-3", false, false),
    ws(38, 4, "DP-3", false, false), ws(2, 1, "DP-1", true, false, nil, 20), ws(35, 2, "DP-1", false, false),
  }
  for _, w in ipairs(list) do
    w.name = names[w.id]
  end
  return { WorkspacesChanged = { workspaces = list } }
end

test("shorten: ascii, cyrillic (UTF-8), exact length, nil", function()
  eq(View.shorten("web", 10), "web", "short stays")
  eq(View.shorten("0123456789", 10), "0123456789", "exactly max stays")
  eq(View.shorten("0123456789A", 10), "012345678…", "cut to max with ellipsis")
  eq(View.shorten("Разработка проекта", 10), "Разработк…", "cyrillic counted in characters")
  eq(utf8.len(View.shorten("Разработка проекта", 10)), 10, "cyrillic length")
  eq(View.shorten(nil, 10), nil, "nil")
  eq(View.shorten("", 10), "", "empty")
end)

test("navigator: a named workspace shows its name, an unnamed one its number", function()
  local m = fixture()
  m:apply(namedWorkspaces({ [1] = "web", [2] = "chat" }))
  local nav = View.navigator(View.build(m, "DP-3", OPTS))
  eq(nav.label, "web", "named label")
  eq(nav.named, true, "named")
  eq(nav.truncated, false, "not truncated")
  eq(View.navigator(View.build(m, "DP-1", OPTS)).label, "chat", "other output's own name")
  m:apply({ WorkspaceActivated = { id = 3, focused = true } }) -- DP-3 idx 2, unnamed
  nav = View.navigator(View.build(m, "DP-3", OPTS))
  eq(nav.label, "2", "unnamed shows idx")
  eq(nav.named, false, "unnamed")
end)

test("navigator: a long name is shortened for the badge, full name kept", function()
  local m = fixture()
  local long = "Очень длинное имя рабочего стола"
  m:apply(namedWorkspaces({ [1] = long }))
  local view = View.build(m, "DP-3", OPTS)
  local nav = View.navigator(view)
  eq(utf8.len(nav.label), View.BADGE_MAX_CHARS, "badge label length")
  eq(nav.label:sub(-#"…"), "…", "ellipsis")
  eq(nav.fullLabel, long, "full label")
  eq(nav.truncated, true, "truncated")
  eq(view.activeWorkspace.name, long, "view keeps the full name")
end)

test("names follow niri events: set, rename, unset (same ids, no stale label)", function()
  local m = fixture()
  m:apply(namedWorkspaces({ [1] = "web" }))
  eq(View.navigator(View.build(m, "DP-3", OPTS)).label, "web", "set")
  m:apply(namedWorkspaces({ [1] = "mail" }))
  eq(View.navigator(View.build(m, "DP-3", OPTS)).label, "mail", "renamed")
  m:apply(namedWorkspaces({}))
  local view = View.build(m, "DP-3", OPTS)
  eq(View.navigator(view).label, "1", "unset falls back to the number")
  eq(view.activeWorkspace.name, nil, "no stale name")
  eq(view.activeWorkspace.id, 1, "same workspace id")
  noViolations(m)
end)

test("an empty name string counts as unnamed", function()
  local m = fixture()
  m:apply(namedWorkspaces({ [1] = "" }))
  local view = View.build(m, "DP-3", OPTS)
  eq(View.navigator(view).label, "1", "label")
  eq(view.activeWorkspace.named, false, "named")
end)

test("actions: a named workspace is addressed by name, an unnamed one by index", function()
  withNoctalia(function(calls)
    local Actions = load(root .. "/lib/actions.luau")
    local m = fixture()
    m:apply(namedWorkspaces({ [35] = "mail box", [3] = "7" }))
    Actions.focusWorkspace(m, 35) -- other output, named: niri resolves the output itself
    eq(calls[1], "niri msg action focus-workspace mail box", "by name (argv, no shell quoting)")
    Actions.focusWorkspace(m, 3) -- name looks like an index: must not be used as a name
    eq(calls[2], "niri msg action focus-workspace 2", "index-like name falls back to idx")
  end)
end)

test("render: names in badge, panel and tooltips; bounded badge width", function()
  _G.ui = fakeUi()
  _G.noctalia = {
    tr = function(key) return key end,
    trp = function(key) return key end,
  }
  cache[root .. "/lib/render.luau"] = nil
  local Render = load(root .. "/lib/render.luau")
  local m = fixture()
  local long = "Очень длинное имя рабочего стола"
  m:apply(namedWorkspaces({ [1] = long, [3] = "web" }))
  local trees = renderAll(m, Render, "DP-3")

  local badgeLabel, badgeTip
  walk(trees.navigator, function(node)
    if node.props.key == "badge" then badgeTip = node.props.tooltip end
    if node.props.key == "label" then badgeLabel = node.props end
  end)
  eq(utf8.len(badgeLabel.text), View.BADGE_MAX_CHARS, "badge text shortened")
  eq(badgeLabel.width <= 72 and badgeLabel.maxWidth <= 72, true, "badge width bounded")
  eq(badgeTip:find(long, 1, true) ~= nil, true, "full name in the badge tooltip")

  local rows = {}
  walk(trees.panel, function(node)
    if tostring(node.props.key):match("^row%-") then
      local idx, name
      for _, c in ipairs(node.children) do
        if c.props.key == "idx" then idx = c.props.text end
        if c.props.key == "name" then name = c.props.text end
      end
      rows[#rows + 1] = idx .. "|" .. name
      eq(node.props.tooltip ~= nil, true, "row tooltip")
    end
  end)
  eq(rows[1], "1|" .. View.shorten(long, View.PANEL_MAX_CHARS), "panel: number and shortened name")
  eq(rows[2], "2|web", "panel: short name")
  eq(rows[3], "3|", "panel: unnamed shows only the number")

  -- unnamed numbers keep the fixed width (no jumps between 1-2 digit workspaces)
  eq(Render.labelWidth("1", 1), Render.labelWidth("12", 1), "fixed number width")
  eq(Render.labelWidth(string.rep("x", 40), 1), 72, "width cap")
  _G.ui, _G.noctalia = nil, nil
end)

test("window tooltip: full title, app name and id, floating", function()
  _G.noctalia = { tr = function(key) return key end, trp = function(key) return key end }
  cache[root .. "/lib/render.luau"] = nil
  local Render = load(root .. "/lib/render.luau")
  local title = string.rep("Very long document title ", 6)
  local tip = Render.windowTooltip({ id = 1, appId = "org.telegram.desktop", title = title, state = "normal", floating = true })
  eq(tip, title .. "\ntelegram (org.telegram.desktop)\ntooltip.window_floating\ntooltip.window_normal", "tooltip")
  tip = Render.windowTooltip({ id = 2, appId = "firefox", title = "", state = "focused" })
  eq(tip, "firefox\ntooltip.window_focused", "no title, short app id: not repeated")
  _G.noctalia = nil
end)

test("navigator is the default mode for new installs (manifest and widget fallback)", function()
  local manifest = assert(io.open(root .. "/plugin.toml")):read("a")
  local block = manifest:match('key%s*=%s*"displayMode".-default%s*=%s*"([%w_]+)"')
  eq(block, "navigator", "plugin.toml default")
  local widget = assert(io.open(root .. "/widget.luau")):read("a")
  eq(widget:find('configuredMode or "navigator"', 1, true) ~= nil, true, "widget fallback")
end)

test("wheel is left to onScroll; only the left click is bound in the manifest", function()
  local manifest = assert(io.open(root .. "/plugin.toml")):read("a")
  local actions = manifest:match("%[widget%.actions%](.-)\n%s*\n")
  eq(actions ~= nil, true, "[widget.actions] block")
  eq(actions:match("scroll_up") == nil and actions:match("scroll_down") == nil, true, "no scroll bindings")
  eq(actions:match('left%s*=%s*"([^"]+)"'), "panel-toggle johnnyp0t/niri-workspace-stack:navigator", "left")
  local widget = assert(io.open(root .. "/widget.luau")):read("a")
  eq(widget:find("function onScroll", 1, true) ~= nil, true, "widget handles the wheel")
end)

print(string.format("\n%d/%d passed", total - failures, total))
os.exit(failures == 0 and 0 or 1)
