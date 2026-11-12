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

-- A freshly launched awww-daemon needs a moment before it answers on its
-- socket; how long that takes varies by machine. turnOn() polls `awww query`
-- every DAEMON_POLL_SECONDS, up to DAEMON_POLL_ATTEMPTS times (~5 s in total),
-- and continues as soon as the daemon answers.
local DAEMON_POLL_ATTEMPTS = 50
local DAEMON_POLL_SECONDS = "0.1"

local enabled = false
local available = false
local starting = false -- true while turnOn() waits for awww-daemon to come up
local hidden = {}   -- connector -> true once we've disabled the host surface there
local lastSeen = {} -- connector -> path last sent to awww
local failures = {} -- connector -> consecutive `awww img` failures

-- Right after awww-daemon starts (especially at login), a single `awww img`
-- can still fail while the daemon finishes setting up its outputs; the next
-- tick then succeeds. Only notify once failures persist for this many ticks.
local MAX_SILENT_FAILURES = 3

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

-- Returns the persisted toggle state. It deliberately does not set `enabled`:
-- that only flips once awww-daemon is ready (startEnabled), otherwise the 1 s
-- update() tick would send `awww img` before the daemon exists.
local function loadPersistedEnabled()
  local path = statePath()
  if not path then return false end
  local content = noctalia.readFile(path)
  if type(content) == "string" and content ~= "" then
    local decoded = noctalia.json.decode(content)
    if type(decoded) == "table" and decoded.enabled == true then
      return true
    end
  end
  return false
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
      failures[connector] = nil
      return
    end
    if result and result.timedOut then
      noctalia.log("Awwwall: awww img for " .. connector .. " is still running past the wait timeout, leaving it be")
      return
    end
    -- Clearing lastSeen makes the next tick retry.
    lastSeen[connector] = nil
    local count = (failures[connector] or 0) + 1
    failures[connector] = count
    local stderr = result and result.stderr or ""
    noctalia.log("Awwwall: awww img failed for " .. connector .. " (attempt " .. count .. "): " .. stderr)
    if count == MAX_SILENT_FAILURES then
      noctalia.notifyError("Awwwall", noctalia.tr("notify.apply_failed", { connector = connector }))
    end
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
  failures = {}
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

-- Polls `awww query` until the daemon answers or the attempts run out, then
-- reports whether it is ready.
local function waitForDaemon(onResult)
  local cmd = "i=0; while [ \"$i\" -lt " .. DAEMON_POLL_ATTEMPTS .. " ]; do " ..
    -- Ready means the daemon answers AND already lists at least one output.
    "out=$(awww query 2>/dev/null) && [ -n \"$out\" ] && exit 0; " ..
    "i=$((i + 1)); sleep " .. DAEMON_POLL_SECONDS .. "; " ..
    "done; exit 1"
  noctalia.runAsync(cmd, function(result)
    onResult(result ~= nil and result.exitCode == 0)
  end, 10000)
end

local function startEnabled()
  enabled = true
  persist()
  publish()
  pollOutputs()
end

local function turnOn()
  if starting then
    -- Already waiting for the daemon; a second click must not launch another.
    return
  end
  if not available then
    noctalia.notifyError("Awwwall", noctalia.tr("notify.awww_missing"))
    return
  end
  starting = true
  daemonRunning(function(running)
    if running then
      starting = false
      startEnabled()
      return
    end
    noctalia.runAsync("exec awww-daemon >/dev/null 2>&1 &")
    -- Only send the first `awww img` once the daemon actually answers;
    -- sending it earlier fails and shows a spurious error notification.
    waitForDaemon(function(ready)
      starting = false
      if ready then
        startEnabled()
      else
        -- Leave the persisted state alone so the next Noctalia start retries.
        noctalia.notifyError("Awwwall", noctalia.tr("notify.daemon_failed"))
      end
    end)
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
  if enabled or starting then
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

local wasEnabled = loadPersistedEnabled()
publish()
if wasEnabled and available then
  -- Re-assert on a Noctalia restart: the daemon may or may not have survived,
  -- turnOn() handles both cases.
  turnOn()
end
