-- providers/hyprland.luau — compositor provider for Hyprland.
--
-- Contract consumed by the service (keeps the rest of the plugin
-- compositor-agnostic):
--   provider.activeWindow(cb)  -> cb({ appId, appName, title?, workspace? } | nil)
--   provider.start(onEvent)    -> onEvent("idle" | "active" | "lock" | "unlock" | "suspend" | "resume")
--   provider.stop()
--
-- Security notes:
--   * hyprctl runs through the argument-array form of runAsync (API 24); no
--     value is ever shell-interpreted and no user data enters a command line.
--   * The only string-form commands are constant dbus-monitor match rules and
--     a hypridle invocation with our own generated config path.
--
-- Event sources:
--   * idle: a private hypridle instance with a generated config whose only
--     actions echo markers on stdout. This coexists with a user's own
--     hypridle (a different config file is an independent client) and binds
--     no screen-blanking behavior.
--   * lock/unlock + suspend/resume: dbus-monitor on the system bus watching
--     org.freedesktop.login1 (same approach as the eyecare plugin).

local M = {}

-- Shell exclusion: What Did I Do runs inside Noctalia, so Noctalia itself is
-- never user activity. The check lives in lib/exclusion.luau; the provider
-- applies it first (before the service sees anything), and the tracker gates
-- again independently — two layers, no display-side filtering.
local exclusion
local okExclusion, exclusionMod = pcall(function()
  return require("../lib/exclusion.luau")
end)
if okExclusion and type(exclusionMod) == "table" and type(exclusionMod.isExcludedApplication) == "function" then
  exclusion = exclusionMod
else
  exclusion = { isExcludedApplication = function() return false end }
end

-- JSON decoding: prefer our error-returning codec. NOTE: require must run
-- inside a closure — pcall(require, ...) breaks the host's lexical path
-- resolution (it resolves from the calling file).
local json
do
  local ok, mod = pcall(function()
    return require("../lib/json.luau")
  end)
  if ok and mod and type(mod.decode) == "function" then
    json = mod
  else
    json = {
      decode = function(s)
        local okDecoded, value = pcall(noctalia.json.decode, s)
        if okDecoded then
          return true, value
        end
        return false, value
      end,
    }
  end
end

function M.newProvider(opts)
  opts = opts or {}

  local self = {
    name = "hyprland",
    available = false,
    idleAfterSeconds = opts.idleAfterSeconds or 120,
    _idleStreamStarted = false,
    _loginStreamStarted = false,
  }

  local function log(msg)
    if opts.log then
      opts.log(msg)
    else
      noctalia.log("what-did-i-do/hyprland: " .. msg)
    end
  end

  local function shellQuote(s)
    return "'" .. string.gsub(tostring(s), "'", "'\\''") .. "'"
  end

  -- ── activeWindow ─────────────────────────────────────────────────────────

  local function parseActiveWindow(raw)
    if type(raw) ~= "string" or raw == "" then
      return nil
    end
    -- `hyprctl -j activewindow` prints "Invalid" (plain text) when no window
    -- has focus; JSON parse failure covers that and any other non-JSON body.
    local ok, data = json.decode(raw)
    if not ok or type(data) ~= "table" then
      return nil
    end
    if data.mapped == false or data.hidden == true then
      return nil
    end
    local class = data.class
    if type(class) ~= "string" or class == "" then
      return nil
    end
    local workspace = nil
    if type(data.workspace) == "table" and type(data.workspace.name) == "string" then
      workspace = data.workspace.name
    end
    local title = nil
    if type(data.title) == "string" and data.title ~= "" then
      title = data.title
    end
    return {
      appId = class,
      appName = class,
      initialClass = type(data.initialClass) == "string" and data.initialClass or nil,
      title = title,
      workspace = workspace,
    }
  end

  local pollInFlight = false

  function self.activeWindow(cb)
    if pollInFlight then
      return
    end
    pollInFlight = true
    local accepted = noctalia.runAsync({ "hyprctl", "-j", "activewindow" }, function(result)
      pollInFlight = false
      if type(result) ~= "table" or result.timedOut or result.exitCode ~= 0 then
        self.available = false
        cb(nil)
        return
      end
      self.available = true
      local app = parseActiveWindow(result.stdout)
      if app and exclusion.isExcludedApplication(app) then
        -- Shell window (Noctalia itself): report "no trackable application"
        -- so no session can ever be created for it downstream.
        cb(nil)
        return
      end
      cb(app)
    end, 4000)
    if not accepted then
      pollInFlight = false
      cb(nil)
    end
  end

  -- ── idle / lock / suspend event streams ──────────────────────────────────

  local IDLE_MARKER = "WDID_IDLE"
  local ACTIVE_MARKER = "WDID_ACTIVE"

  -- The host does not kill a stream's child process when the owning runtime
  -- goes away (observed live: every reload left an orphaned private hypridle
  -- and two dbus-monitors behind). Each of our streams therefore carries a
  -- unique identity — the generated hypridle config path for idle, and a
  -- dedicated argv0 marker for the dbus monitors — and a fresh runtime sweeps
  -- stale instances of those identities BEFORE starting its own streams.
  local IDLE_CFG_NAME = "hypridle-wdid.conf"
  local MONITOR_ARG0 = "wdid-login1-monitor"

  local function killLeakedStreams(done)
    if not noctalia.commandExists("pkill") then
      done()
      return
    end
    local pending = 2
    local function step()
      pending = pending - 1
      if pending == 0 then
        done()
      end
    end
    -- Patterns match only processes this plugin spawned (its own config file
    -- name / argv0 marker); a user's own hypridle or dbus-monitor never
    -- carries them.
    local accepted1 = noctalia.runAsync({ "pkill", "-f", IDLE_CFG_NAME }, step, 3000)
    local accepted2 = noctalia.runAsync({ "pkill", "-f", MONITOR_ARG0 }, step, 3000)
    if not accepted1 or not accepted2 then
      pending = 0
      done()
    end
  end

  local function startIdleStream(onEvent)
    if self._idleStreamStarted then
      return
    end
    if not noctalia.commandExists("hypridle") then
      log("hypridle not found; idle detection disabled (time is undercounted)")
      return
    end
    local dir = noctalia.pluginDataDir()
    if not dir then
      log("no plugin data dir; idle detection disabled")
      return
    end
    local cfgPath = dir .. "/" .. IDLE_CFG_NAME
    local cfg = string.format(
      "listener {\n  timeout = %d\n  on-timeout = echo %s\n  on-resume = echo %s\n}\n",
      math.max(5, math.floor(self.idleAfterSeconds or 120)),
      IDLE_MARKER,
      ACTIVE_MARKER
    )
    noctalia.writeFile(cfgPath, cfg)
    self._idleStreamStarted = true
    -- The command string is built only from our own data-dir path.
    noctalia.runStream("hypridle -c " .. shellQuote(cfgPath), function(line)
      if line == IDLE_MARKER then
        onEvent("idle")
      elseif line == ACTIVE_MARKER then
        onEvent("active")
      end
    end)
    log("idle stream started (timeout " .. tostring(self.idleAfterSeconds or 120) .. "s)")
  end

  -- dbus-monitor emits member lines followed by typed argument lines, so the
  -- parser is stateful: remember the member of the previous signal block.
  local function startLoginStreams(onEvent)
    if self._loginStreamStarted then
      return
    end
    if not noctalia.commandExists("dbus-monitor") then
      log("dbus-monitor not found; lock/suspend detection disabled (time is undercounted)")
      return
    end
    self._loginStreamStarted = true

    local pendingMember = nil
    -- Constant match rules, no interpolation. The bash `exec -a` gives the
    -- process a unique argv0 (MONITOR_ARG0) so a fresh runtime can sweep
    -- stale instances without touching anyone else's dbus-monitor.
    noctalia.runStream(
      "bash -c \"exec -a "
        .. MONITOR_ARG0
        .. " dbus-monitor --system \\\"type='signal',interface='org.freedesktop.login1.Manager'\\\"\"",
      function(line)
        if string.find(line, "member=PrepareForSleep", 1, true) then
          pendingMember = "sleep"
        elseif pendingMember == "sleep" and string.find(line, "boolean true", 1, true) then
          onEvent("suspend")
          pendingMember = nil
        elseif pendingMember == "sleep" and string.find(line, "boolean false", 1, true) then
          onEvent("resume")
          pendingMember = nil
        end
      end
    )

    noctalia.runStream(
      "bash -c \"exec -a "
        .. MONITOR_ARG0
        .. " dbus-monitor --system \\\"type='signal',interface='org.freedesktop.login1.Session'\\\"\"",
      function(line)
        if string.find(line, "member=Lock", 1, true) then
          onEvent("lock")
        elseif string.find(line, "member=Unlock", 1, true) then
          onEvent("unlock")
        end
      end
    )
    log("login1 monitor started (lock/suspend)")
  end

  function self.start(onEvent)
    self.available = true
    -- Sweep orphans from previous runtime generations first, then start.
    killLeakedStreams(function()
      startIdleStream(onEvent)
      startLoginStreams(onEvent)
    end)
  end

  function self.stop()
    -- runStream lifetimes are host-owned (terminated on entry teardown), so
    -- stop() only detaches the callback routing.
    self._idleStreamStarted = false
    self._loginStreamStarted = false
  end

  return self
end

return M
