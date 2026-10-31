--!nonstrict
-- Runs the screensaver (shell.qml, drawn by Quickshell) while the plugin is enabled.
-- There is no onConfigChanged on purpose: a settings change restarts this service,
-- which ends the old stream (and its qs), and the top level below starts a new one.

local shell = noctalia.pluginDir() .. "/shell.qml"
local lastStart = 0

local function quote(s: string): string
  return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function start()
  lastStart = noctalia.nowMs()
  local cmd = "BOUNCE_TIMEOUT=" .. tostring(noctalia.getConfig("timeout"))
  local logo = noctalia.getConfig("logo")
  if logo ~= nil and logo ~= "" then
    cmd ..= " BOUNCE_LOGO=" .. quote(noctalia.expandPath(logo))
  end
  -- exec, so the stream's process is qs itself and ends with the stream.
  cmd ..= " exec qs -p " .. quote(shell)
  if not noctalia.runStream(cmd, function(_line) end) then
    noctalia.log("bounce-saver: could not start qs")
  end
end

if noctalia.commandExists("qs") then
  start()
else
  noctalia.notifyError("Bounce Saver", "Quickshell (qs) is not installed, so the screensaver cannot run.")
end

-- Restart qs if it died (crash, killed by hand). Checked every 30 s.
noctalia.setUpdateInterval(30000)

function update()
  if noctalia.nowMs() - lastStart < 20000 or not noctalia.commandExists("qs") then
    return
  end
  noctalia.processMatches(function(running)
    if not running then
      noctalia.log("bounce-saver: qs was not running, restarting it")
      start()
    end
  end, "qs", shell)
end
