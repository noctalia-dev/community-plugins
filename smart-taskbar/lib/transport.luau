--!nonstrict
-- Native events where available; bounded host-owned fallbacks on older shells.
local Compositor = require("./compositor.luau")
local M = {}
-- Constant shell programs: no settings, paths or window IDs are interpolated.
-- Noctalia cancels the process group on widget reload/disable.
M.umbrielCommand = [[
while :; do
  printf '%s\n' '{"event":"reset"}'
  umbriel subscribe windows workspaces
  printf '%s\n' '{"event":"reset"}'
  sleep 2
done
]]
M.niriCommand = [[
while :; do
  printf '%s\n' '{"event":"reset"}'
  niri msg --json event-stream
  printf '%s\n' '{"event":"reset"}'
  sleep 2
done
]]
local function nonempty(value)
  return type(value)=="string" and value~=""
end
local function detect(host, native)
  if native and type(native.name)=="function" then
    local name=string.lower(native.name())
    if name=="mangowc" then name="mango" end
    if name~="unknown" then return name end
  end
  local variables={{"UMBRIEL_SOCKET","umbriel"},{"NIRI_SOCKET","niri"},
    {"HYPRLAND_INSTANCE_SIGNATURE","hyprland"},{"MANGO_INSTANCE_SIGNATURE","mango"},{"SWAYSOCK","sway"}}
  for _,pair in ipairs(variables) do if nonempty(host.getenv(pair[1])) then return pair[2] end end
  local desktop=string.lower((host.getenv("XDG_CURRENT_DESKTOP") or "")..":"..(host.getenv("XDG_SESSION_DESKTOP") or ""))
  for _,name in ipairs({"umbriel","niri","hyprland","mango","sway"}) do
    if string.find(desktop,name,1,true) then return name end
  end
  return "unknown"
end
local function quote(value)
  return "'"..string.gsub(value,"'","'\\''").."'"
end
function M.new(host)
  local native=type(host.compositor)=="table" and host.compositor or nil
  local name=detect(host,native)
  local useNative=native and type(native.subscribe)=="function" and type(native.unsubscribe)=="function"
    and (name=="umbriel" or name=="niri") or false
  local receiver,running=nil,false
  local cache,partial={},nil
  local niriState=Compositor.new("niri")
  local transport={name=name,native=useNative,problem=nil}
  local function reset()
    cache={}; partial=nil; niriState=Compositor.new("niri")
    if receiver then receiver("reset",nil) end
  end
  local function receive(line)
    local message=host.json.decode(line)
    if type(message)~="table" then return end
    local event=message.event
    if event=="reset" then reset(); return end
    if event=="error" then if receiver then receiver(event,message.data) end; return end
    if event=="snapshot-part" then
      local part=message.data
      if type(part)~="table" or type(part.token)~="number" or type(part.index)~="number"
        or type(part.windows)~="table" or type(part.workspaces)~="table" then reset(); return end
      if part.index==1 then partial={token=part.token,index=0,windows={},workspaces={}} end
      if not partial or partial.token~=part.token or part.index~=partial.index+1 then reset(); return end
      for _,family in ipairs({"windows","workspaces"}) do
        for _,item in ipairs(part[family]) do table.insert(partial[family],item) end
        if #partial[family]>8192 then reset(); return end
      end
      partial.index=part.index
      if part.last==true then
        local snapshot={windows=partial.windows,workspaces=partial.workspaces}
        partial=nil; cache.snapshot=snapshot
        if receiver then receiver("snapshot",snapshot) end
      end
      return
    end
    if name=="niri" then
      -- The public CLI emits single-key {EventName: payload} objects. Keep a
      -- normalized cache so pausing/resuming never loses intervening deltas.
      for key,data in pairs(message) do
        if Compositor.event(niriState,key,data) then
          cache.snapshot={windows=Compositor.snapshot(niriState),workspaces=niriState.workspaces}
          if receiver then receiver("snapshot",cache.snapshot) end
        end
      end
    elseif event=="windows" or event=="workspaces" then
      if type(message.data)~="table" then return end
      cache[event]=message.data
      if receiver then receiver(event,message.data) end
    end
  end
  function transport.subscribe(options,callback)
    transport.problem=nil
    if useNative then return native.subscribe(options,callback) end
    local command
    if name=="umbriel" or name=="niri" then
      for _,dependency in ipairs({name,"sleep"}) do
        if not host.commandExists(dependency) then transport.problem=dependency; return nil end
      end
      command=name=="umbriel" and M.umbrielCommand or M.niriCommand
    elseif name=="hyprland" or name=="mango" or name=="sway" then
      if not host.commandExists("python3") then transport.problem="python3"; return nil end
      local directory=host.pluginDir()
      if not nonempty(directory) then transport.problem="plugin directory"; return nil end
      command="exec python3 -B -u "..quote(directory.."/lib/bridge.py").." "..name
    else
      transport.problem="unsupported compositor"; return nil
    end
    receiver=callback
    if running then
      if cache.snapshot then callback("snapshot",cache.snapshot)
      else
        if cache.workspaces then callback("workspaces",cache.workspaces) end
        if cache.windows then callback("windows",cache.windows) end
      end
      return "compositor-stream"
    end
    running=host.runStream(command,receive)
    if not running then receiver=nil; transport.problem="event stream startup"; return nil end
    return "compositor-stream"
  end
  function transport.unsubscribe(id)
    if useNative then return native.unsubscribe(id) end
    receiver=nil
    -- runStream has no individual stop API. Reuse one connection while paused;
    -- VM teardown owns cancellation of the process group.
    return id=="compositor-stream"
  end
  return transport
end
return M
