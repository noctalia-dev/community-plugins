--!nonstrict
-- Raw public compositor event schemas, matching Noctalia's compositor backends.
local M = {}
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k,v in pairs(a) do if not same(v,b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
local function text(value)
  return type(value) == "string" and string.gsub(value,"[%c]"," ") or ""
end
local function niriWindow(w)
  if type(w)~="table" or type(w.id)~="number" or w.id<0 or w.id%1~=0 then return nil end
  return {id=tostring(w.id),appId=text(w.app_id),title=text(w.title),workspace=tostring(w.workspace_id or ""),
    output="",focused=w.is_focused==true,minimized=false,minimizable=false,urgent=w.is_urgent==true}
end
local function replaceWindows(state, windows)
  local previous = {}
  for _, w in ipairs(state.windows) do previous[w.id] = w end
  local changed = not state.connected or #windows ~= #state.windows
  for _, w in ipairs(windows) do if not same(w, previous[w.id]) then changed = true end end
  if changed then state.windows = windows end
  state.connected = true
  return changed
end
local function replaceWorkspaces(state, workspaces)
  if same(state.workspaces,workspaces) then return false end
  state.workspaces = workspaces
  return true
end
function M.new(name)
  return { name = name, windows = {}, workspaces = {}, connected = false }
end
local function list(payload, key)
  if type(payload) ~= "table" then return nil end
  local value=payload[key]
  if value~=nil then return type(value)=="table" and value or nil end
  return payload
end
function M.event(state, event, data)
  if event == "reset" then
    local changed=state.connected or #state.windows>0 or #state.workspaces>0
    state.windows = {}; state.workspaces = {}; state.connected = false
    return changed
  end
  if event == "snapshot" then
    if type(data) ~= "table" or type(data.windows) ~= "table" or type(data.workspaces) ~= "table" then return false end
    local windows, seen = {}, {}
    for _, w in ipairs(data.windows) do
      if type(w) ~= "table" or type(w.id) ~= "string" or w.id == "" then return false end
      if not seen[w.id] then
        seen[w.id] = true
        table.insert(windows, { id=w.id, appId=text(w.appId), title=text(w.title),
          workspace=text(w.workspace), output=text(w.output), focused=w.focused==true,
          minimized=w.minimized==true, minimizable=w.minimizable==true,
          urgent=w.urgent==true, workspaces=type(w.workspaces)=="table" and w.workspaces or nil })
      end
    end
    local workspaces={}
    for i,ws in ipairs(data.workspaces) do
      if type(ws)~="table" or ws.id==nil then return false end
      table.insert(workspaces,{id=tostring(ws.id),output=text(ws.output),name=text(ws.name),
        idx=type(ws.idx)=="number" and ws.idx or i,active=ws.active==true,focused=ws.focused==true})
    end
    local changed = replaceWindows(state,windows)
    return replaceWorkspaces(state,workspaces) or changed
  end
  if state.name == "umbriel" then
    if event == "windows" and type(data) == "table" then
      local windows,seen = {},{}
      for _, w in ipairs(data) do
        if type(w)=="table" and type(w.id) == "string" and w.id ~= "" and not seen[w.id]
          and type(w.workspace) == "string" and w.workspace ~= "" then
          seen[w.id]=true
          local output = w.output or string.match(w.workspace, "^(.*):[^:]+$") or ""
          table.insert(windows, { id = w.id, appId = text(w.app_id), title = text(w.title),
            workspace = w.workspace, output = output, focused = w.active == true,
            minimized = w.minimized == true, minimizable = w.minimizable == true,
            -- Urgency is not guaranteed in Umbriel snapshots. Absent means unknown.
            urgent = w.urgent == true })
        end
      end
      return replaceWindows(state,windows)
    elseif event == "workspaces" and type(data) == "table" then
      local workspaces = {}
      for i, ws in ipairs(data) do
        if type(ws)=="table" and ws.id~=nil then
          table.insert(workspaces,{id=tostring(ws.id),output=text(ws.output),name=text(ws.name),
            idx=ws.idx or ws.index or i,active=ws.active==true,focused=ws.focused==true})
        end
      end
      return replaceWorkspaces(state,workspaces)
    end
  elseif state.name == "niri" then
    if event == "WindowsChanged" then
      local windows = list(data, "windows")
      if not windows then return false end
      if type(windows)~="table" then return false end
      local normalized,seen={},{}
      for _,w in ipairs(windows) do
        local item=niriWindow(w)
        if item and not seen[item.id] then seen[item.id]=true; table.insert(normalized,item) end
      end
      return replaceWindows(state,normalized)
    elseif event == "WindowOpenedOrChanged" then
      local w=type(data)=="table" and (data.window or data)
      local item=niriWindow(w)
      if not item then return false end
      local id=item.id
      local found, changed = nil, false
      for i, old in ipairs(state.windows) do
        if old.id == id then found=i; changed=not same(old,item) or changed
        elseif item.focused and old.focused then old.focused=false; changed=true end
      end
      if not found then table.insert(state.windows,item); return true end
      if changed then state.windows[found]=item end
      return changed
    elseif event == "WindowClosed" and type(data) == "table" then
      for i = #state.windows, 1, -1 do
        if state.windows[i].id == tostring(data.id) then table.remove(state.windows,i); return true end
      end
      return false
    elseif event == "WindowFocusChanged" and type(data) == "table" then
      local changed=false
      for _, w in ipairs(state.windows) do
        local focused=w.id==tostring(data.id)
        if w.focused~=focused then w.focused=focused; changed=true end
        if focused and w.urgent then w.urgent=false; changed=true end
      end
      return changed
    elseif event == "WindowUrgencyChanged" and type(data)=="table" then
      for _, w in ipairs(state.windows) do
        if w.id==tostring(data.id) and w.urgent~=(data.urgent==true) then
          w.urgent=data.urgent==true; return true
        end
      end
      return false
    elseif event == "WorkspacesChanged" then
      local workspaces = list(data, "workspaces")
      if not workspaces then return false end
      local nextWorkspaces = {}
      for _, ws in ipairs(workspaces) do
        if type(ws)=="table" and ws.id~=nil then
          table.insert(nextWorkspaces, { id=tostring(ws.id),output=text(ws.output),
            active=ws.is_active==true,focused=ws.is_focused==true,name=text(ws.name),idx=ws.idx })
        end
      end
      return replaceWorkspaces(state,nextWorkspaces)
    elseif event == "WorkspaceActivated" and type(data) == "table" then
      local target
      for _, ws in ipairs(state.workspaces) do if ws.id == tostring(data.id) then target = ws end end
      if not target then return false end
      local changed=false
      for _,ws in ipairs(state.workspaces) do
        local active=ws.output==target.output and ws==target or (ws.output~=target.output and ws.active)
        local focused=data.focused==true and ws==target or (data.focused~=true and ws.focused)
        if ws.active~=active or ws.focused~=focused then changed=true end
        ws.active=active; ws.focused=focused
      end
      return changed
    end
  end
  return false
end
function M.snapshot(state)
  local result, outputs = {}, {}
  for _, ws in ipairs(state.workspaces) do if ws.output and ws.output~="" then outputs[tostring(ws.id)]=ws.output end end
  for _, w in ipairs(state.windows) do
    local copy = table.clone(w)
    copy.output = outputs[copy.workspace] or copy.output
    table.insert(result,copy)
  end
  return result
end
-- Inject the host so this module can also run under the official Luau CLI tests.
function M.action(state, host, action, window, callback)
  if not window or not state.connected then return false end
  if state.name == "umbriel" then
    if action == "minimize" and (not window.minimizable or window.minimized) then return false end
    return host.umbriel.action({ action = "window-" .. action, window = window.id }, callback)
  end
  local argv
  if state.name=="niri" and (action=="focus" or action=="close") then
    if not string.match(window.id,"^%d+$") or not host.commandExists("niri") then return false end
    argv={"niri","msg","action",action.."-window","--id",window.id}
  elseif state.name=="hyprland" and (action=="focus" or action=="close") then
    if not string.match(window.id,"^0x[%da-fA-F]+$") or not host.commandExists("hyprctl") then return false end
    argv={"hyprctl","dispatch",action=="focus" and "focuswindow" or "closewindow","address:"..window.id}
  elseif state.name=="mango" then
    if not string.match(window.id,"^%d+$") or not host.commandExists("mmsg") then return false end
    local command=({focus="focusid",close="killclient",minimize="minimized"})[action]
    if not command or (action=="minimize" and (not window.minimizable or window.minimized)) then return false end
    argv={"mmsg","dispatch",command,"client,"..window.id}
  elseif state.name=="sway" and (action=="focus" or action=="close") then
    if not string.match(window.id,"^%d+$") or not host.commandExists("swaymsg") then return false end
    argv={"swaymsg","[con_id="..window.id.."]",action=="focus" and "focus" or "kill"}
  end
  if argv then
    return host.runAsync(argv,function(result)
      local ok=result.exitCode==0
      if ok and state.name=="mango" then
        local reply=host.json.decode(result.stdout or "")
        ok=type(reply)=="table" and reply.success==true
      elseif ok and state.name=="sway" then
        local replies=host.json.decode(result.stdout or "")
        ok=type(replies)=="table" and #replies>0
        if ok then for _,reply in ipairs(replies) do if reply.success~=true then ok=false end end end
      end
      if callback then callback(ok,ok and nil or result.stderr) end
    end,5000)
  end
  return false
end
return M
