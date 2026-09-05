-- scroll_ipc.luau — shared scrollmsg helpers (mirrors ScrollIpc in gtkshell/scroll.cpp).

local M = {}

function M.shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function M.socketPath()
  local override = noctalia.getConfig("socket_path")
  if override ~= nil and override ~= "" then
    return override
  end
  local env = noctalia.getenv("SCROLLSOCK")
  if env == nil or env == "" then
    env = noctalia.getenv("SWAYSOCK")
  end
  return env
end

function M.scrollmsgBase()
  local sock = M.socketPath()
  if sock ~= nil and sock ~= "" then
    return "scrollmsg -s " .. M.shellQuote(sock)
  end
  return "scrollmsg"
end

function M.isAvailable()
  if not noctalia.commandExists("scrollmsg") then
    return false
  end
  local sock = M.socketPath()
  return sock ~= nil and sock ~= ""
end

-- Long-lived subscribe stream; blocks in scrollmsg until events arrive (gtkshell
-- ScrollIpc::working_thread + recv). Returns false if the process failed to start.
function M.subscribe(eventsJson, onLine)
  local cmd = M.scrollmsgBase() .. " -t subscribe -m -r " .. M.shellQuote(eventsJson)
  return noctalia.runStream(cmd, onLine)
end

function M.fetch(ipcType, onEnvelope)
  noctalia.runAsync(M.scrollmsgBase() .. " -t " .. ipcType .. " -r", function(result)
    if result.exitCode ~= 0 or result.stdout == nil or result.stdout == "" then
      return
    end
    onEnvelope(noctalia.json.decode(result.stdout))
  end)
end

return M
