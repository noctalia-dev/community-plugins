--!nonstrict
-- Raw public compositor event schemas, matching Noctalia's compositor backends.
local M = {}
function M.new(name)
  return { name = name, windows = {}, workspaces = {}, connected = false }
end
local function list(payload, key)
  if type(payload) ~= "table" then return nil end
  return payload[key] or payload
end
function M.event(state, event, data)
  if event == "reset" then
    state.windows = {}; state.workspaces = {}; state.connected = false
    return true
  end
  if state.name == "umbriel" then
    if event == "windows" and type(data) == "table" then
      local windows = {}
      for _, w in ipairs(data) do
        if type(w.id) == "string" and w.id ~= "" and type(w.workspace) == "string" and w.workspace ~= "" then
          local output = w.output or string.match(w.workspace, "^(.*):[^:]+$") or ""
          table.insert(windows, { id = w.id, appId = w.app_id or "", title = w.title or "",
            workspace = w.workspace, output = output, focused = w.active == true,
            minimized = w.minimized == true, minimizable = w.minimizable == true,
            -- Urgency is not guaranteed in Umbriel snapshots. Absent means unknown.
            urgent = w.urgent == true })
        end
      end
      state.windows = windows; state.connected = true; return true
    elseif event == "workspaces" and type(data) == "table" then
      state.workspaces = data; return true
    end
  elseif state.name == "niri" then
    if event == "WindowsChanged" then
      local windows = list(data, "windows")
      if not windows then return false end
      state.windows = {}
      for _, w in ipairs(windows) do
        M.event(state, "WindowOpenedOrChanged", { window = w })
      end
      state.connected = true; return true
    elseif event == "WindowOpenedOrChanged" then
      local w = type(data) == "table" and (data.window or data)
      if not w or w.id == nil then return false end
      local id = tostring(w.id)
      for i = #state.windows, 1, -1 do
        if state.windows[i].id == id then table.remove(state.windows, i) end
      end
      if w.is_focused then for _, old in ipairs(state.windows) do old.focused = false end end
      table.insert(state.windows, { id = id, appId = w.app_id or "", title = w.title or "",
        workspace = tostring(w.workspace_id or ""), output = "", focused = w.is_focused == true,
        minimized = false, minimizable = false, urgent = w.is_urgent == true })
      return true
    elseif event == "WindowClosed" and type(data) == "table" then
      for i = #state.windows, 1, -1 do
        if state.windows[i].id == tostring(data.id) then table.remove(state.windows, i) end
      end
      return true
    elseif event == "WindowFocusChanged" and type(data) == "table" then
      for _, w in ipairs(state.windows) do w.focused = w.id == tostring(data.id) end
      return true
    elseif event == "WorkspacesChanged" then
      local workspaces = list(data, "workspaces")
      if not workspaces then return false end
      state.workspaces = {}
      for _, ws in ipairs(workspaces) do
        table.insert(state.workspaces, { id = tostring(ws.id), output = ws.output,
          active = ws.is_active, focused = ws.is_focused, name = ws.name, idx = ws.idx })
      end
      return true
    elseif event == "WorkspaceActivated" and type(data) == "table" then
      local target
      for _, ws in ipairs(state.workspaces) do if ws.id == tostring(data.id) then target = ws end end
      if target then
        for _, ws in ipairs(state.workspaces) do
          if ws.output == target.output then ws.active = ws == target end
          if data.focused then ws.focused = ws == target end
        end
      end
      return true
    end
  end
  return false
end
function M.snapshot(state)
  local result = {}
  for _, w in ipairs(state.windows) do
    local copy = table.clone(w)
    for _, ws in ipairs(state.workspaces) do
      if tostring(ws.id) == copy.workspace then copy.output = ws.output or copy.output; break end
    end
    table.insert(result, copy)
  end
  return result
end
-- Inject the host so this module can also run under the official Luau CLI tests.
function M.action(state, host, action, window, callback)
  if not window or not state.connected then return false end
  if state.name == "umbriel" then
    if action == "minimize" and (not window.minimizable or window.minimized) then return false end
    return host.umbriel.action({ action = "window-" .. action, window = window.id }, callback)
  elseif state.name == "niri" and (action == "focus" or action == "close") then
    if not string.match(window.id, "^%d+$") or not host.commandExists("niri") then return false end
    return host.runAsync({ "niri", "msg", "action", action .. "-window", "--id", window.id }, function(result)
      if callback then callback(result.exitCode == 0, result.stderr) end
    end)
  end
  return false
end
return M
