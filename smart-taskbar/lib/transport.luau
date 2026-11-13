--!nonstrict
-- Native subscriptions on API 54; one host-owned CLI stream on API 52/53.
local M = {}
-- Constant shell program: no settings, paths, IDs, or other dynamic values are interpolated.
-- Noctalia runStream owns the process group and cancels shell/CLI/sleep on VM teardown.
M.umbrielCommand = [[
while :; do
  printf '%s\n' '{"event":"reset"}'
  umbriel subscribe windows workspaces
  printf '%s\n' '{"event":"reset"}'
  sleep 2
done
]]
function M.new(host)
  local native = host.compositor
  local hasNative = type(native) == "table" and type(native.subscribe) == "function"
    and type(native.name) == "function" and type(native.unsubscribe) == "function"
  local name = "unknown"
  if hasNative then name = native.name()
  else
    local desktop = string.lower(host.getenv("XDG_CURRENT_DESKTOP") or "")
    local socket = host.getenv("UMBRIEL_SOCKET")
    if (socket and socket ~= "") or string.find(desktop, "umbriel", 1, true) then name = "umbriel"
    elseif host.getenv("NIRI_SOCKET") then name = "niri" end
  end
  local receiver, running = nil, false
  local cache = {}
  local transport = { name = name, native = hasNative }
  function transport.subscribe(options, callback)
    if hasNative then return native.subscribe(options, callback) end
    if name ~= "umbriel" or not host.commandExists("umbriel") or not host.commandExists("sleep") then return nil end
    receiver = callback
    if running then
      -- A compatibility setting may temporarily unsubscribe. Keep only full snapshots
      -- while paused, then replay them without opening another process or connection.
      if cache.workspaces then callback("workspaces", cache.workspaces) end
      if cache.windows then callback("windows", cache.windows) end
      return "umbriel-stream"
    end
    running = host.runStream(M.umbrielCommand, function(line)
      local message = host.json.decode(line)
      if type(message) ~= "table" then return end
      local event = message.event
      if event == "reset" then cache = {}
      elseif event == "windows" or event == "workspaces" then
        if type(message.data) ~= "table" then return end
        cache[event] = message.data
      else return end
      if receiver then receiver(event, message.data) end
    end)
    if not running then receiver = nil; return nil end
    return "umbriel-stream"
  end
  function transport.unsubscribe(id)
    if hasNative then return native.unsubscribe(id) end
    receiver = nil
    -- runStream has no individual cancellation API. The single idle stream stays
    -- owned by this widget until reload/disable, when the host kills its process group.
    return id == "umbriel-stream"
  end
  return transport
end
return M
