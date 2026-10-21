--!nonstrict
-- Pure model of niri's workspace/window state, fed by `niri msg --json event-stream`.
--
-- Mirrors niri-ipc's own reducer (niri-ipc/src/state.rs, EventStreamStatePart::apply),
-- which is what niri's IPC server applies to its copy of the state before sending each
-- event. No noctalia.* calls here, so the module also runs under plain Lua 5.4 for the
-- unit tests in tests/.
--
-- Invariants (checked by M:violations()):
--   I1 every window has exactly one workspace id (or none while unplaced); never an index
--   I2 consumers select by output; the model never filters implicitly
--   I3 at most one active workspace per output
--   I4 at most one globally focused window   (single source: self.focusedWindowId)
--   I5 at most one globally focused workspace, hence at most one focused output
--   I6 workspaces and windows are keyed by niri's stable ids; idx is display data only
--   I7 full-state events replace, never merge, so removed/moved workspaces cannot linger

local M = {}
M.__index = M

function M.new()
  return setmetatable({
    workspaces = {}, -- id -> workspace
    windows = {}, -- id -> window
    focusedWindowId = nil, -- the only record of window focus (I4)
    haveWorkspaces = false,
    haveWindows = false,
    eventCount = 0,
    lastEvent = nil,
  }, M)
end

local function workspaceFrom(raw)
  return {
    id = raw.id,
    idx = raw.idx,
    name = raw.name,
    output = raw.output, -- nil when the workspace has no monitor
    isActive = raw.is_active == true,
    isFocused = raw.is_focused == true,
    isUrgent = raw.is_urgent == true,
    activeWindowId = raw.active_window_id,
  }
end

local function applyLayout(window, layout)
  local pos = type(layout) == "table" and layout.pos_in_scrolling_layout or nil
  if type(pos) == "table" then
    window.column, window.tile = pos[1], pos[2]
  else
    window.column, window.tile = nil, nil -- floating, or layout unknown
  end
end

local function windowFrom(raw)
  local window = {
    id = raw.id,
    title = raw.title or "",
    appId = raw.app_id or "",
    workspaceId = raw.workspace_id,
    isFloating = raw.is_floating == true,
    isUrgent = raw.is_urgent == true,
  }
  applyLayout(window, raw.layout)
  return window
end

-- The event's single top-level key, for diagnostics.
local function eventName(event)
  for key in pairs(event) do
    return key
  end
  return "?"
end

-- Applies one decoded event. Returns true when anything the widget renders may have changed.
function M:apply(event)
  if type(event) ~= "table" then
    return false
  end
  self.eventCount = self.eventCount + 1
  self.lastEvent = eventName(event)

  local e = event.WorkspacesChanged
  if e ~= nil then
    local next = {}
    for _, raw in ipairs(e.workspaces or {}) do
      if type(raw) == "table" and raw.id ~= nil then
        next[raw.id] = workspaceFrom(raw)
      end
    end
    self.workspaces = next
    self.haveWorkspaces = true
    return true
  end

  e = event.WorkspaceActivated
  if e ~= nil then
    local target = self.workspaces[e.id]
    if target == nil then
      return false -- niri guarantees it exists; a missing one means we are mid-resync
    end
    for _, ws in pairs(self.workspaces) do
      if ws.output == target.output then
        ws.isActive = ws.id == e.id
      end
      if e.focused == true then
        ws.isFocused = ws.id == e.id
      end
    end
    return true
  end

  e = event.WorkspaceActiveWindowChanged
  if e ~= nil then
    local ws = self.workspaces[e.workspace_id]
    if ws == nil or ws.activeWindowId == e.active_window_id then
      return false
    end
    ws.activeWindowId = e.active_window_id
    return true
  end

  e = event.WorkspaceUrgencyChanged
  if e ~= nil then
    local ws = self.workspaces[e.id]
    if ws == nil then
      return false
    end
    ws.isUrgent = e.urgent == true
    return true
  end

  e = event.WindowsChanged
  if e ~= nil then
    local next = {}
    local focused = nil
    for _, raw in ipairs(e.windows or {}) do
      if type(raw) == "table" and raw.id ~= nil then
        next[raw.id] = windowFrom(raw)
        if raw.is_focused == true then
          focused = raw.id
        end
      end
    end
    self.windows = next
    self.focusedWindowId = focused
    self.haveWindows = true
    return true
  end

  e = event.WindowOpenedOrChanged
  if e ~= nil then
    local raw = e.window
    if type(raw) ~= "table" or raw.id == nil then
      return false
    end
    self.windows[raw.id] = windowFrom(raw)
    -- niri: a focused window unfocuses all others; an unfocused record of the focused
    -- window means focus left it.
    if raw.is_focused == true then
      self.focusedWindowId = raw.id
    elseif self.focusedWindowId == raw.id then
      self.focusedWindowId = nil
    end
    return true
  end

  e = event.WindowClosed
  if e ~= nil then
    if self.windows[e.id] == nil then
      return false
    end
    self.windows[e.id] = nil
    if self.focusedWindowId == e.id then
      self.focusedWindowId = nil
    end
    return true
  end

  e = event.WindowFocusChanged
  if e ~= nil then
    -- `id` is null (nil after decoding) when nothing is focused, e.g. an empty workspace.
    if self.focusedWindowId == e.id then
      return false
    end
    self.focusedWindowId = e.id
    return true
  end

  e = event.WindowUrgencyChanged
  if e ~= nil then
    local window = self.windows[e.id]
    if window == nil or window.isUrgent == (e.urgent == true) then
      return false
    end
    window.isUrgent = e.urgent == true
    return true
  end

  e = event.WindowLayoutsChanged
  if e ~= nil then
    local changed = false
    for _, change in ipairs(e.changes or {}) do
      local window = type(change) == "table" and self.windows[change[1]] or nil
      if window ~= nil then
        local column, tile = window.column, window.tile
        applyLayout(window, change[2])
        changed = changed or column ~= window.column or tile ~= window.tile
      end
    end
    return changed
  end

  return false
end

-- ── Selectors ───────────────────────────────────────────────────────────────

function M:ready()
  return self.haveWorkspaces and self.haveWindows
end

function M:isWindowFocused(id)
  return id ~= nil and id == self.focusedWindowId
end

function M:focusedWorkspace()
  for _, ws in pairs(self.workspaces) do
    if ws.isFocused then
      return ws
    end
  end
  return nil
end

function M:focusedOutput()
  local ws = self:focusedWorkspace()
  return ws and ws.output or nil
end

-- Workspaces of exactly one output, in niri's display order (idx), never id order.
-- `output` must be a connector name: nil selects nothing (I2).
function M:workspacesOn(output)
  local list = {}
  if output == nil then
    return list
  end
  for _, ws in pairs(self.workspaces) do
    if ws.output == output then
      list[#list + 1] = ws
    end
  end
  table.sort(list, function(a, b)
    if a.idx ~= b.idx then
      return (a.idx or 0) < (b.idx or 0)
    end
    return a.id < b.id
  end)
  return list
end

function M:activeWorkspaceOn(output)
  if output == nil then
    return nil
  end
  for _, ws in pairs(self.workspaces) do
    if ws.isActive and ws.output == output then
      return ws
    end
  end
  return nil
end

function M:windowCount(workspaceId)
  local count = 0
  for _, window in pairs(self.windows) do
    if window.workspaceId == workspaceId then
      count = count + 1
    end
  end
  return count
end

-- Windows of a workspace in on-screen order: tiled by (column, tile), then floating by id.
function M:windowsOf(workspaceId)
  local list = {}
  if workspaceId == nil then
    return list
  end
  for _, window in pairs(self.windows) do
    if window.workspaceId == workspaceId then
      list[#list + 1] = window
    end
  end
  table.sort(list, function(a, b)
    local af, bf = a.column == nil, b.column == nil
    if af ~= bf then
      return bf -- tiled first
    end
    if not af then
      if a.column ~= b.column then
        return a.column < b.column
      end
      if a.tile ~= b.tile then
        return a.tile < b.tile
      end
    end
    return a.id < b.id
  end)
  return list
end

-- Index window [first, last] of `count` items, `visible` wide, centered on `active` and
-- clamped so it never shows empty leading/trailing slots.
function M.visibleRange(count, active, visible)
  if count <= 0 then
    return 1, 0
  end
  visible = math.max(1, math.min(visible, count))
  active = math.max(1, math.min(active or 1, count))
  local first = active - math.floor((visible - 1) / 2)
  first = math.max(1, math.min(first, count - visible + 1))
  return first, first + visible - 1
end

-- Invariant check for tests and the diagnostic dump. Returns a list of strings.
function M:violations()
  local out = {}
  local activePerOutput, focusedCount, idxSeen = {}, 0, {}
  for id, ws in pairs(self.workspaces) do
    if ws.id ~= id then
      out[#out + 1] = string.format("I6 workspace key %s holds id %s", tostring(id), tostring(ws.id))
    end
    if ws.isActive and ws.output ~= nil then
      activePerOutput[ws.output] = (activePerOutput[ws.output] or 0) + 1
    end
    if ws.isFocused then
      focusedCount = focusedCount + 1
      if not ws.isActive then
        out[#out + 1] = "I5 focused workspace " .. tostring(id) .. " is not active"
      end
    end
    if ws.output ~= nil and ws.idx ~= nil then
      local key = ws.output .. "#" .. tostring(ws.idx)
      if idxSeen[key] then
        out[#out + 1] = "I7 duplicate idx " .. key
      end
      idxSeen[key] = true
    end
  end
  for output, n in pairs(activePerOutput) do
    if n > 1 then
      out[#out + 1] = string.format("I3 %d active workspaces on %s", n, output)
    end
  end
  if focusedCount > 1 then
    out[#out + 1] = string.format("I5 %d focused workspaces", focusedCount)
  end
  for id, window in pairs(self.windows) do
    if window.id ~= id then
      out[#out + 1] = string.format("I6 window key %s holds id %s", tostring(id), tostring(window.id))
    end
  end
  if self.focusedWindowId ~= nil and self.haveWindows and self.windows[self.focusedWindowId] == nil then
    out[#out + 1] = "I4 focused window " .. tostring(self.focusedWindowId) .. " is unknown"
  end
  table.sort(out)
  return out
end

return M
