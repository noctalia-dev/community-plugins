--!nonstrict
-- Pure state and layout calculations. No host APIs or filesystem access.
local M = {}
function M.appId(value)
  return (string.lower(tostring(value or "")):gsub("%.desktop$", ""))
end
function M.identity(value)
  value = tostring(value)
  return tostring(#value) .. ":" .. value
end
function M.new()
  return { windows = {}, serial = 0, clock = 0, manual = {}, lastFocus = nil }
end
function M.reconcile(state, snapshot)
  local nextWindows = {}
  for _, source in ipairs(snapshot) do
    local id = tostring(source.id)
    if id ~= "" and not nextWindows[id] then
      local old = state.windows[id]
      local w = table.clone(source)
      if not old then state.serial += 1 end
      w.order = old and old.order or state.serial
      w.recent = old and old.recent or 0
      w.id = id
      if w.focused and state.lastFocus ~= id then
        state.clock += 1
        w.recent = state.clock
      end
      nextWindows[id] = w
    end
  end
  state.lastFocus = nil
  for id, w in pairs(nextWindows) do
    if w.focused then state.lastFocus = id; break end
  end
  state.windows = nextWindows
end
local function canonical(c, app)
  local id = M.appId(app)
  return M.appId(c.app_aliases[id] or id)
end
function M.groups(state, c, output, workspaces, previous)
  local groups, byKey, excluded, pinnedSet = {}, {}, {}, {}
  for _, app in ipairs(c.pinned_apps) do pinnedSet[canonical(c, app)] = true end
  for _, app in ipairs(c.exclusions) do excluded[canonical(c, app)] = true end
  local function add(w, pinned)
    local app = canonical(c, w.appId)
    if excluded[app] then return end
    -- Unknown app IDs never merge unrelated windows.
    local appKey = app ~= "" and app or ("window:" .. w.id)
    local key = "app:" .. M.identity(appKey)
    if c.grouping == "workspace" then key = "ws:" .. M.identity(w.workspace or "")
    elseif c.grouping == "app_workspace" then key ..= ":ws:" .. M.identity(w.workspace or "")
    elseif c.grouping == "windows" then key = "win:" .. M.identity(w.id) end
    if pinned then
      -- Pins join an existing application group, even with workspace/window grouping.
      for _, g in ipairs(groups) do
        if g.appId == app then g.pinned = true; g.launchId = w.appId; return end
      end
      key = "pin:" .. M.identity(app)
    end
    local g = byKey[key]
    if not g then
      g = { key = key, appId = app, iconId = w.appId, title = w.title or app,
        windows = {}, order = w.order or math.huge, recent = 0, focused = false,
        minimized = true, urgent = false, workspace = w.workspace or "", pinned = pinned == true, launchId = pinned and w.appId or nil }
      byKey[key] = g; table.insert(groups, g)
    end
    if not pinned then
      table.insert(g.windows, w)
      g.order = math.min(g.order, w.order)
      g.recent = math.max(g.recent, w.recent)
      g.focused = g.focused or w.focused
      g.minimized = g.minimized and w.minimized == true
      g.urgent = g.urgent or w.urgent == true
      if w.focused then g.title = w.title end
    end
  end
  local activeWorkspace, workspaceRank = {}, {}
  local focusedApp
  for _, w in pairs(state.windows) do if w.focused then focusedApp = canonical(c, w.appId) end end
  for i, ws in ipairs(workspaces) do
    workspaceRank[tostring(ws.id)] = ws.idx or i
    if ws.active or ws.focused then activeWorkspace[tostring(ws.id)] = true end
  end
  for _, w in pairs(state.windows) do
    local ws = tostring(w.workspace or "")
    local onOutput = c.output_filter ~= "current" or w.output == output
    local onWorkspace = c.workspace_filter ~= "active" or activeWorkspace[ws] == true
    local mode = c.display_mode
    if mode == "workspace" then onWorkspace = activeWorkspace[ws] == true end
    if mode == "monitor" then onOutput = w.output == output end
    if (mode ~= "pinned" or pinnedSet[canonical(c, w.appId)]) and onOutput and onWorkspace and (c.show_minimized or not w.minimized)
      and (mode ~= "active" or (focusedApp ~= nil and canonical(c, w.appId) == focusedApp)) then add(w, false) end
  end
  if c.display_mode == "running_pinned" or c.display_mode == "pinned" then
    for _, app in ipairs(c.pinned_apps) do
      if app ~= "" then add({ id = "pin:" .. app, appId = app, title = app }, true) end
    end
  end
  local rank = {}
  for i, key in ipairs(state.manual) do rank[key] = i end
  -- Freeze ranks under the pointer, but update membership, badges and focus.
  if previous then for i, key in ipairs(previous) do rank[key] = i end end
  table.sort(groups, function(a, b)
    if previous or c.sorting == "manual" then
      local ar, br = rank[a.key] or math.huge, rank[b.key] or math.huge
      if ar ~= br then return ar < br end
    elseif c.sorting == "mru" and a.recent ~= b.recent then return a.recent > b.recent
    elseif c.sorting == "alphabetical" and a.appId ~= b.appId then return a.appId < b.appId
    elseif c.sorting == "workspace" and a.workspace ~= b.workspace then
      local ar, br = workspaceRank[a.workspace] or math.huge, workspaceRank[b.workspace] or math.huge
      if ar ~= br then return ar < br end
      return a.workspace < b.workspace
    end
    if a.order ~= b.order then return a.order < b.order end
    return a.key < b.key
  end)
  for _, g in ipairs(groups) do
    table.sort(g.windows, function(a, b) return a.order < b.order end)
  end
  return groups
end
function M.cycle(group, cursor)
  if #group.windows == 0 then return nil end
  local index = cursor or 0
  if cursor == nil then
    for i, w in ipairs(group.windows) do if w.focused then index = i; break end end
  end
  index = index % #group.windows + 1
  return group.windows[index], index
end
function M.layout(c, count)
  local maxWidth = math.max(48, c.max_width)
  local collapsed = math.clamp(c.collapsed_width, 32, maxWidth)
  local cell = c.icon_size + 24 -- fixed count lane, including three-digit counts
  local gap = c.icon_spacing
  local available = maxWidth - 16 -- plugin's own capsule padding
  local capacity = math.max(1, math.floor((available + gap) / (cell + gap)))
  local indicators = c.show_scroll_indicators and count > capacity and maxWidth >= 16 + 32 + cell
  if indicators then
    available -= 32
    capacity = math.max(1, math.floor((available + gap) / (cell + gap)))
  end
  -- A single cell is clipped for exceptionally small budgets; never enlarge the root.
  local visible = math.min(count, capacity)
  local wanted = 16 + visible * cell + math.max(0, visible - 1) * gap + (indicators and 32 or 0)
  local width = math.clamp(wanted, math.min(c.min_width, maxWidth), maxWidth)
  return { width = width, collapsed = collapsed, capacity = capacity, cell = cell,
    indicators = indicators, viewport = math.max(1, width - 16 - (indicators and 32 or 0)) }
end
function M.reveal(offset, capacity, count, focused)
  offset = math.clamp(offset, 0, math.max(0, count - capacity))
  if focused then
    if focused <= offset then offset = focused - 1
    elseif focused > offset + capacity then offset = focused - capacity end
  end
  return math.clamp(offset, 0, math.max(0, count - capacity))
end
function M.move(state, groups, source, target)
  local keys = {}
  for _, g in ipairs(groups) do if g.key ~= source then table.insert(keys, g.key) end end
  for i, key in ipairs(keys) do
    if key == target then table.insert(keys, i, source); state.manual = keys; return end
  end
end
return M
