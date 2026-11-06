--!nonstrict
-- A long-lived command whose stdout lines feed a signal source (swayidle, gdbus monitor).
--
-- `runStream` only reports lines: it says nothing when the process exits, and it stops
-- processes only when the plugin reloads (spike S1). The command is therefore wrapped as
--
--   echo "<marker> pid $$"; <command>; echo "<marker> exit $?"
--
-- so this module learns the process group to stop (the host makes the shell a group
-- leader) and notices when the command ends. A command that ends is restarted after
-- 1, 2, 4, 8 then 16 s; after 5 restarts within a minute the stream is marked failed and
-- tried again every 5 minutes. Lines of a stopped or replaced run are ignored.

local Types = require("../types.luau")

type Host = Types.Host

export type StreamState = "running" | "restarting" | "failed" | "stopped"

export type Stream = {
  state: () -> StreamState,
  -- Call regularly (the service tick): launches scheduled restarts.
  tick: () -> (),
  stop: () -> (),
}

local Stream = {}

local MAX_RESTARTS = 5
local RESTART_WINDOW_MS = 60 * 1000
local FAILED_RETRY_MS = 5 * 60 * 1000

-- `command` must be a constant or built from validated integers: it runs through the
-- shell (spec §13). `onState(state)` reports transitions.
function Stream.start(host: Host, name: string, command: string, onLine: (line: string) -> (), onState: ((state: StreamState) -> ())?): Stream
  local state: StreamState = "stopped"
  local marker: string? = nil -- of the current run
  local pids: { [string]: number } = {} -- process group of each run, once reported
  local stopping: { [string]: boolean } = {} -- runs to kill as soon as their pid is known
  local restarts: { number } = {} -- launch times of recent restarts
  local nextLaunchMs: number? = nil

  local function setState(next: StreamState)
    if next ~= state then
      state = next
      if onState then
        onState(next)
      end
    end
  end

  local function kill(run: string)
    local pid = pids[run]
    if pid then
      -- The integer comes from our own wrapper's output.
      host.runAsync({ "/bin/sh", "-c", string.format("kill -TERM -- -%d", pid) })
      pids[run] = nil
    else
      stopping[run] = true
    end
  end

  local scheduleRestart

  local function launch()
    nextLaunchMs = nil
    local run = string.format("shift-%s-%x%06x", name, host.nowMs(), math.random(0, 0xffffff))
    marker = run
    local wrapped = string.format('echo "%s pid $$"; %s; echo "%s exit $?"', run, command, run)
    local prefix = run .. " "
    local ok = host.runStream(wrapped, function(line)
      local word, value
      if string.sub(line, 1, #prefix) == prefix then
        word, value = string.match(string.sub(line, #prefix + 1), "^(%a+) (%d+)$")
      end
      if word == "pid" then
        pids[run] = tonumber(value) :: number
        if stopping[run] then
          stopping[run] = nil
          kill(run)
        end
        return
      elseif word == "exit" then
        pids[run] = nil
        if marker == run then
          host.log(string.format("signals: %s exited with status %s", name, tostring(value)))
          marker = nil
          scheduleRestart()
        end
        return
      end
      if marker == run then
        onLine(line)
      end
    end)
    if ok then
      setState("running")
    else
      host.log(string.format("signals: cannot start %s", name))
      marker = nil
      scheduleRestart()
    end
  end

  function scheduleRestart()
    local now = host.nowMs()
    local recent = {}
    for _, at in restarts do
      if now - at < RESTART_WINDOW_MS then
        table.insert(recent, at)
      end
    end
    restarts = recent
    if #restarts >= MAX_RESTARTS then
      restarts = {}
      nextLaunchMs = now + FAILED_RETRY_MS
      setState("failed")
      return
    end
    nextLaunchMs = now + 1000 * 2 ^ #restarts
    table.insert(restarts, now)
    setState("restarting")
  end

  local stream = {} :: Stream

  function stream.state(): StreamState
    return state
  end

  function stream.tick()
    if nextLaunchMs and host.nowMs() >= nextLaunchMs then
      launch()
    end
  end

  function stream.stop()
    nextLaunchMs = nil
    if marker then
      kill(marker)
      marker = nil
    end
    setState("stopped")
  end

  launch()
  return stream
end

return Stream
