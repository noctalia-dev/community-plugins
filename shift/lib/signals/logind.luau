--!nonstrict
-- Session lock and system sleep from logind (spec §6.3.2, C3, spike S2).
--
-- Noctalia sets the session's `LockedHint` when it locks. `gdbus monitor` on the system
-- bus reports its changes and `PrepareForSleep(true/false)` around a suspend:
--
--   <session path>: org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.login1.Session', {'LockedHint': <true>}, @as [])
--   /org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)
--
-- The session path comes from `GetSession($XDG_SESSION_ID)`, or `GetSession("auto")`.
-- Without gdbus, `loginctl` is polled every 15 s for the lock state only; sleep is then
-- left to the service's clock-gap detector.

local Stream = require("./stream.luau")
local Types = require("../types.luau")

type BackendHealth = Types.BackendHealth
type Host = Types.Host

export type LogindSignal = "lock" | "unlock" | "sleep" | "resume"

export type LogindMonitor = {
  health: () -> BackendHealth,
  tick: () -> (),
  stop: () -> (),
}

local Logind = {}

local POLL_MS = 15 * 1000
local CALL_TIMEOUT_MS = 5000
local MONITOR = "gdbus monitor --system --dest org.freedesktop.login1"
local MANAGER_SLEEP = "/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep ("

local function managerCall(method: string, arg: string): { string }
  return {
    "gdbus",
    "call",
    "--system",
    "--dest",
    "org.freedesktop.login1",
    "--object-path",
    "/org/freedesktop/login1",
    "--method",
    "org.freedesktop.login1.Manager." .. method,
    arg,
  }
end

-- Parses one monitor line for `sessionPath`; returns a signal or nil.
function Logind.parse(line: string, sessionPath: string?): LogindSignal?
  if string.sub(line, 1, #MANAGER_SLEEP) == MANAGER_SLEEP then
    local value = string.match(line, "^%((%a+),%)", #MANAGER_SLEEP)
    if value == "true" then
      return "sleep"
    elseif value == "false" then
      return "resume"
    end
    return nil
  end
  local prefix = sessionPath and sessionPath .. ": org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.login1.Session',"
  if prefix and string.sub(line, 1, #prefix) == prefix then
    -- Other properties may share the dictionary.
    local value = string.match(line, "'LockedHint': <(%a+)>", #prefix)
    if value == "true" then
      return "lock"
    elseif value == "false" then
      return "unlock"
    end
  end
  return nil
end

function Logind.start(host: Host, onSignal: (signal: LogindSignal, atS: number) -> ()): LogindMonitor
  local monitor = {} :: LogindMonitor
  local health: BackendHealth = "unavailable"
  local stream: Stream.Stream? = nil
  local sessionPath: string? = nil
  local locked: boolean? = nil
  local pollAtMs: number? = nil
  local stopped = false
  local sessionId = host.getenv("XDG_SESSION_ID")
  if sessionId and not string.match(sessionId, "^[%w_]+$") then
    sessionId = nil
  end

  -- Reports lock changes only: logind repeats LockedHint in unrelated updates.
  local function setLocked(value: boolean)
    if stopped or value == locked then
      return
    end
    local first = locked == nil
    locked = value
    if value or not first then
      local signal: LogindSignal = if value then "lock" else "unlock"
      onSignal(signal, host.nowMs() // 1000)
    end
  end

  local function poll()
    pollAtMs = host.nowMs() + POLL_MS
    host.runAsync({ "loginctl", "show-session", sessionId :: string, "-p", "LockedHint" }, function(result)
      local value = result.exitCode == 0 and string.match(result.stdout, "LockedHint=(%a+)")
      if value then
        setLocked(value == "yes")
      end
    end, CALL_TIMEOUT_MS)
  end

  local function startPolling(): boolean
    if sessionId and host.commandExists("loginctl") then
      health = "poll"
      poll()
      return true
    end
    health = "unavailable"
    return false
  end

  local function startMonitor()
    stream = Stream.start(host, "logind", MONITOR, function(line)
      local signal = Logind.parse(line, sessionPath)
      if signal == "lock" or signal == "unlock" then
        setLocked(signal == "lock")
      elseif signal then
        onSignal(signal, host.nowMs() // 1000)
      end
    end, function(state)
      if state == "failed" and not stopped then
        -- gdbus keeps failing: fall back to polling the lock state.
        (stream :: Stream.Stream).stop()
        stream = nil
        if not startPolling() then
          health = "error"
        end
      end
    end)
    health = "ok"
    -- The monitor reports changes only: read the current lock state once.
    host.runAsync({
      "gdbus",
      "call",
      "--system",
      "--dest",
      "org.freedesktop.login1",
      "--object-path",
      sessionPath :: string,
      "--method",
      "org.freedesktop.DBus.Properties.Get",
      "org.freedesktop.login1.Session",
      "LockedHint",
    }, function(result)
      local value = result.exitCode == 0 and string.match(result.stdout, "<(%a+)>")
      if value then
        setLocked(value == "true")
      end
    end, CALL_TIMEOUT_MS)
  end

  local function resolve(ids: { string })
    local id = table.remove(ids, 1)
    if not id then
      host.log("signals: logind session not found")
      if not startPolling() then
        health = "error"
      end
      return
    end
    host.runAsync(managerCall("GetSession", id), function(result)
      if stopped then
        return
      end
      local path = result.exitCode == 0 and string.match(result.stdout, "'(/org/freedesktop/login1/session/[%w_]+)'")
      if path then
        sessionPath = path
        startMonitor()
      else
        resolve(ids)
      end
    end, CALL_TIMEOUT_MS)
  end

  if host.commandExists("gdbus") then
    health = "ok"
    resolve(sessionId and { sessionId, "auto" } or { "auto" })
  else
    startPolling()
  end

  function monitor.health(): BackendHealth
    if stream and stream.state() == "restarting" then
      return "ok"
    end
    return health
  end

  function monitor.tick()
    if stream then
      stream.tick()
    elseif pollAtMs and host.nowMs() >= pollAtMs then
      poll()
    end
  end

  function monitor.stop()
    stopped = true
    pollAtMs = nil
    if stream then
      stream.stop()
      stream = nil
    end
    health = "off"
  end

  return monitor
end

return Logind
