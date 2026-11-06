--!nonstrict
-- Umbriel IPC through the `umbriel` CLI (docs/user/ipc.md of the Umbriel sources).
--
-- `umbriel subscribe` sends the current state of each family on connect, then a full
-- snapshot of the family on every change: {"event":"workspaces"|"windows","data":[...]}.
-- The decoder turns those into niri's WorkspacesChanged / WindowsChanged, so lib/model.luau
-- stays niri's reducer and every display mode works unchanged.

local M = {}

M.COMMAND = "umbriel"
M.SUBSCRIBE = "umbriel subscribe workspaces,windows"
M.SNAPSHOT = {
  workspaces = { "umbriel", "workspaces", "--json" },
  windows = { "umbriel", "windows", "--json" },
}

local function run(argv, what)
  local ok = noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      noctalia.log(string.format("niri-workspace-stack: %s failed (exit %d): %s", what, result.exitCode, noctalia.string.trim(result.stderr)))
    end
  end, 2000)
  if not ok then
    noctalia.log("niri-workspace-stack: could not start " .. what)
  end
end

local function nonEmpty(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

-- Umbriel's workspace `focused` is the active workspace of the output under the pointer,
-- and a window's `focused` is only the workspace-local remembered focus; the seat's
-- focused window is the one with `active` (xdg activated).
local function workspaceFrom(raw)
  return {
    id = raw.id,
    idx = raw.index,
    name = raw.named == true and nonEmpty(raw.name) or nil, -- the display name of an unnamed one is its index
    output = nonEmpty(raw.output),
    is_active = raw.active == true,
    is_focused = raw.focused == true,
    is_urgent = raw.urgent == true,
    active_window_id = nonEmpty(raw.focused_window),
  }
end

local function windowFrom(raw)
  local column, row = tonumber(raw.column), tonumber(raw.row)
  local scrolling = column ~= nil and row ~= nil and column >= 0 and row >= 0
  return {
    id = raw.id,
    title = raw.title,
    app_id = raw.app_id,
    workspace_id = nonEmpty(raw.workspace),
    is_floating = raw.floating == true,
    is_urgent = raw.urgent == true,
    is_focused = raw.active == true,
    layout = { pos_in_scrolling_layout = scrolling and { column + 1, row + 1 } or nil },
  }
end

local function workspaceKey(ws)
  return table.concat({ ws.id, tostring(ws.idx), ws.name or "", ws.output or "", tostring(ws.is_active),
    tostring(ws.is_focused), tostring(ws.is_urgent), ws.active_window_id or "" }, "\31")
end

local function windowKey(w)
  local pos = w.layout.pos_in_scrolling_layout
  return table.concat({ w.id, w.title or "", w.app_id or "", w.workspace_id or "", tostring(w.is_floating),
    tostring(w.is_urgent), tostring(w.is_focused), pos and (pos[1] .. "," .. pos[2]) or "" }, "\31")
end

local FAMILIES = {
  workspaces = { from = workspaceFrom, key = workspaceKey, event = "WorkspacesChanged", field = "workspaces" },
  windows = { from = windowFrom, key = windowKey, event = "WindowsChanged", field = "windows" },
}

-- Each snapshot carries geometry too, so a resize or a scroll of the strip resends the
-- whole window list. A snapshot whose rendered fields equal the last applied one is
-- dropped instead of re-rendering every bar.
function M.decoder()
  local lastKey = {}
  return function(event)
    local family = type(event) == "table" and FAMILIES[event.event] or nil
    if family == nil or type(event.data) ~= "table" then
      return {}
    end
    local list, keys = {}, {}
    for _, raw in ipairs(event.data) do
      if type(raw) == "table" and nonEmpty(raw.id) ~= nil then
        local entry = family.from(raw)
        list[#list + 1] = entry
        keys[#keys + 1] = family.key(entry)
      end
    end
    local key = table.concat(keys, "\30")
    if lastKey[event.event] == key then
      return {}
    end
    lastKey[event.event] = key
    return { { [family.event] = { [family.field] = list } } }
  end
end

-- A resync reply in the stream's own wire format, so it goes through the same decoder.
function M.snapshotEvent(kind, list)
  return { event = kind, data = list }
end

-- `workspace-switch` takes a 1-based position (bare digits) restricted to `--output`, so a
-- numeric workspace name never shadows the position. Umbriel warps the pointer to the
-- target output only when the pointer is elsewhere; clicks come from that output's bar.
function M.focusWorkspace(ws)
  if ws == nil or ws.idx == nil or ws.output == nil then
    return
  end
  run({ "umbriel", "msg", "workspace-switch", tostring(ws.idx), "--output", ws.output }, "workspace-switch")
end

-- `window-focus` moves the pointer only with input.cursor.follows_focus (window-focus-warp
-- always does, so it is not used).
function M.focusWindow(id)
  if id == nil then
    return
  end
  run({ "umbriel", "msg", "window-focus", id }, "window-focus")
end

return M
