--!nonstrict
-- Awwwall — headless service.
-- The bar widget's toggle fully owns the awww lifecycle:
--   ON  -> starts awww-daemon if it isn't already running, hides Noctalia's own
--          wallpaper surface per output (noctalia.setWallpaperEnabled), and
--          starts mirroring noctalia.wallpaperPath(connector) into `awww img`.
--   OFF -> restores Noctalia's own wallpaper surface on every output it had
--          hidden, and kills the awww daemon.
-- Toggled from the [[widget]] bar tile via the shared "requestToggle" state
-- channel.
--
-- Note: Noctalia plugin scripts run in an isolated sandbox without `require`.
-- All logic lives here; widget.luau only renders and requests toggles.

noctalia.setUpdateInterval(1000)

local STATE_FILE_NAME = "state.json"

local enabled = false
local available = false
local hidden = {}   -- connector -> true once we've disabled the host surface there
local lastSeen = {} -- connector -> path last sent to awww

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function cfg(key)
  return noctalia.getConfig(key)
end

local function statePath()
  local dir = noctalia.pluginDataDir()
  if not dir then return nil end
  return dir .. "/" .. STATE_FILE_NAME
end

-- ── Persistence (the on/off toggle survives a Noctalia restart) ─────────────

local function persist()
  local path = statePath()
  if not path then return end
  noctalia.writeFile(path, noctalia.json.encode({ enabled = enabled }) or "")
end

local function load()
  local path = statePath()
  if not path then return end
  local content = noctalia.readFile(path)
  if type(content) == "string" and content ~= "" then
    local decoded = noctalia.json.decode(content)
    if type(decoded) == "table" and type(decoded.enabled) == "boolean" then
      enabled = decoded.enabled
    end
  end
end

local function publish()
  noctalia.state.set("enabled", enabled)
  noctalia.state.set("available", available)
end

-- ── Reading Noctalia's own wallpaper selection ──────────────────────────────

local function currentPathFor(connector)
  local path = noctalia.wallpaperPath(connector)
  if type(path) == "string" and path ~= "" then
    return path
  end
  return nil
end

-- ── Driving awww ─────────────────────────────────────────────────────────────

local function applyToAwww(connector, path)
  local cmd = "awww img " .. shellQuote(path) ..
    " -o " .. shellQuote(connector) ..
    " --resize " .. shellQuote(cfg("resize") or "crop") ..
    " -t " .. shellQuote(cfg("transition_type") or "random") ..
    " -f " .. shellQuote(cfg("filter") or "Nearest")

  local duration = cfg("transition_duration")
  if type(duration) == "number" then
    cmd = cmd .. " --transition-duration " .. tostring(math.floor(duration))
  end

  -- Mark it optimistically so a slow `awww img` doesn't cause repeat sends on
  -- the next tick; a failure below reverts this so we retry.
  lastSeen[connector] = path

  -- Large/heavy GIFs can take a while for awww to decode and resize (worse
  -- with the Lanczos3 filter). 60000 is the host's own ceiling for runAsync;
  -- even so, a timeout only means we stopped waiting, not that awww failed —
  -- the process keeps running and usually finishes and applies on its own.
  -- Only a real non-zero exit (not a timeout) is treated as a failure.
  noctalia.runAsync(cmd, function(result)
    if result and result.exitCode == 0 then
      return
    end
    if result and result.timedOut then
      noctalia.log("Awwwall: awww img for " .. connector .. " is still running past the wait timeout, leaving it be")
      return
    end
    lastSeen[connector] = nil
    noctalia.notifyError("Awwwall", noctalia.tr("notify.apply_failed", { connector = connector }))
  end, 60000)
end

local function hideHost(connector)
  if not hidden[connector] then
    noctalia.setWallpaperEnabled(connector, false)
    hidden[connector] = true
  end
end

local function restoreAllHosts()
  for connector in pairs(hidden) do
    noctalia.setWallpaperEnabled(connector, true)
  end
  hidden = {}
  lastSeen = {}
end

local function pollOutputs()
  if not enabled or not available then return end
  for _, output in ipairs(noctalia.outputs()) do
    local connector = output.name
    hideHost(connector)
    local path = currentPathFor(connector)
    if type(path) == "string" and path ~= "" and path ~= lastSeen[connector] and noctalia.fileExists(path) then
      applyToAwww(connector, path)
    end
  end
end

function update()
  pollOutputs()
end

function onOutputsChanged()
  pollOutputs()
end

-- ── Daemon lifecycle ─────────────────────────────────────────────────────────

-- `awww query` exits 0 when a daemon answers on its socket, non-zero
-- otherwise. This is more reliable than matching process command lines
-- (noctalia.processMatches can false-positive on unrelated processes whose
-- command line happens to contain the search text, e.g. an editor with this
-- plugin's own project directory open).
local function daemonRunning(onResult)
  noctalia.runAsync("awww query", function(result)
    onResult(result ~= nil and result.exitCode == 0)
  end, 3000)
end

local function startEnabled()
  enabled = true
  persist()
  publish()
  pollOutputs()
end

local function turnOn()
  if not available then
    noctalia.notifyError("Awwwall", noctalia.tr("notify.awww_missing"))
    return
  end
  daemonRunning(function(running)
    if running then
      startEnabled()
    else
      noctalia.runAsync("exec awww-daemon >/dev/null 2>&1 &")
      -- Give the daemon a moment to open its Wayland connection before the
      -- first `awww img` call.
      noctalia.runAsync("sleep 0.5", function()
        startEnabled()
      end)
    end
  end)
end

local function turnOff()
  restoreAllHosts()
  enabled = false
  persist()
  publish()
  noctalia.runAsync("awww kill")
end

local function requestToggle()
  if enabled then
    turnOff()
  else
    turnOn()
  end
end

-- ── Toggle (requested by widget.luau) ───────────────────────────────────────

noctalia.state.watch("requestToggle", function(_)
  requestToggle()
end)

-- Lets `noctalia msg plugin 0lucasmatheus/awwwall:mirror all toggle` drive this
-- from the terminal while developing, without going through the bar widget.
function onIpc(event, _payload)
  if event == "toggle" then
    requestToggle()
  end
end

function onExit(_signal, reason)
  if reason == "reload" then
    -- The script is about to reboot in place (e.g. a .luau hot-reload while
    -- developing) — leave the running daemon and wallpaper alone.
    return
  end
  if enabled then
    -- Clean up the running process and restore Noctalia's own wallpaper
    -- surface, but deliberately do NOT persist enabled=false here: on the
    -- next Noctalia start (or re-enabling the plugin), turnOn() re-launches
    -- awww-daemon and reapplies the current wallpaper on its own, so turning
    -- the toggle on survives a reboot.
    restoreAllHosts()
    noctalia.runAsync("awww kill")
  end
end

-- ── Boot ─────────────────────────────────────────────────────────────────────

available = noctalia.commandExists("awww") and noctalia.commandExists("awww-daemon")
if not available then
  noctalia.notifyError("Awwwall", noctalia.tr("notify.awww_missing"))
end

load()
publish()
if enabled and available then
  -- Re-assert on a Noctalia restart: the daemon may or may not have survived,
  -- turnOn() handles both cases.
  turnOn()
end
