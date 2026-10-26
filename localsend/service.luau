--!nonstrict
-- Background service: owns the daemon process and mirrors its state to the
-- widget and panel through noctalia.state ("ls").

local PANEL = "mera/localsend:panel"
-- The daemon writes a private token (mode 0600) next to its certificate; every control request must carry it.
local cachedToken = nil
local function headers()
  if cachedToken == nil then
    local path = noctalia.pluginDataDir() .. "/control.token"
    cachedToken = noctalia.fileExists(path) and noctalia.readFile(path) or nil
  end
  return { "X-LocalSend-Token: " .. (cachedToken or ""), "Content-Type: application/json" }
end
local function forgetToken() cachedToken = nil end

local function ctl(path) return "http://127.0.0.1:" .. noctalia.getConfig("control_port") .. path end

local phase = "quit_old" -- quit_old -> spawning -> running
local ticks = 0
local seen = {}          -- session id -> last status we notified about

local function spawn()
  local dir = noctalia.pluginDir()
  local alias = noctalia.getConfig("alias")
  local argv = {
    "python3", dir .. "/daemon/localsendd.py",
    "--data-dir", noctalia.pluginDataDir(),
    "--save-dir", noctalia.expandPath(noctalia.getConfig("save_dir")),
    "--port", tostring(noctalia.getConfig("port")),
    "--control-port", tostring(noctalia.getConfig("control_port")),
  }
  if alias ~= nil and alias ~= "" then
    table.insert(argv, "--alias")
    table.insert(argv, alias)
  end
  -- The PIN goes through a file the daemon reads and deletes, never through the command line.
  local pinFile = noctalia.pluginDataDir() .. "/pin"
  local pin = noctalia.getConfig("pin")
  if pin ~= nil and pin ~= "" then
    noctalia.writeFile(pinFile, pin)
    table.insert(argv, "--pin-file")
    table.insert(argv, pinFile)
  end
  if noctalia.getConfig("auto_accept") then table.insert(argv, "--auto-accept") end
  noctalia.runAsync(argv)
end

local function notifyChanges(sessions)
  for _, s in ipairs(sessions) do
    local prev = seen[s.id]
    if prev ~= s.status then
      seen[s.id] = s.status
      local count = #s.files
      if s.direction == "in" and s.status == "pending" then
        noctalia.notify(noctalia.tr("notify.incoming_title"),
          noctalia.tr("panel.incoming", { name = s.peer, count = count }))
        if not noctalia.state.get("panel_open") then noctalia.togglePanel(PANEL) end
      elseif s.status == "done" and prev ~= nil then
        local key = s.direction == "in" and "notify.received" or "notify.sent"
        noctalia.notify(noctalia.tr("notify.incoming_title"),
          noctalia.tr(key, { name = s.peer, count = count }))
      elseif s.status == "failed" and s.error == "PIN required" then
        noctalia.notifyError(noctalia.tr("notify.incoming_title"),
          noctalia.tr("notify.pin_required", { name = s.peer }))
      elseif s.status == "failed" and prev ~= nil then
        noctalia.notifyError(noctalia.tr("notify.incoming_title"),
          noctalia.tr("notify.failed", { name = s.peer }))
      end
    end
  end
end

local function poll()
  noctalia.http({ url = ctl("/state"), method = "GET", headers = headers() }, function(res)
    if not res.ok or res.status ~= 200 then
      forgetToken() -- a restarted daemon has a new token
      noctalia.state.set("ls", { up = false })
      return
    end
    local data = noctalia.json.decode(res.body)
    if data == nil then return end
    data.up = true
    noctalia.state.set("ls", data)
    notifyChanges(data.sessions)
  end)
end

function update()
  ticks = ticks + 1
  if phase == "quit_old" then
    -- A daemon from a previous run may still hold stale settings: replace it.
    noctalia.http({ url = ctl("/quit"), method = "POST", headers = headers(), body = "{}" },
      function() end)
    phase = "spawning"
    ticks = 0
  elseif phase == "spawning" then
    if ticks >= 2 then
      spawn()
      phase = "running"
      ticks = 0
    end
  else
    poll()
    if ticks == 10 and not (noctalia.state.get("ls") or {}).up then
      noctalia.notifyError(noctalia.tr("notify.incoming_title"), noctalia.tr("notify.daemon_failed"))
    end
  end
end

function onIpc(event, payload)
  if event == "rescan" then
    noctalia.http({ url = ctl("/rescan"), method = "POST", headers = headers(), body = "{}" },
      function() end)
  end
end

function onExit(signal, reason)
  noctalia.http({ url = ctl("/quit"), method = "POST", headers = headers(), body = "{}" },
    function() end)
end

noctalia.setUpdateInterval(1000)
noctalia.state.set("ls", { up = false })
