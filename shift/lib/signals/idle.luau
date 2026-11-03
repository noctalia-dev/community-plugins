--!nonstrict
-- Idle detection (spec §6.3.2, C1, spike S1) with swayidle, a standalone
-- `ext-idle-notify-v1` client:
--
--   swayidle -w timeout <T> 'echo idle' resume 'echo active'
--
-- `idle` arrives once the user has been inactive for T; the reducer dates the absence
-- back by T. An `active` is held for 2 s and dropped, together with the next `idle`, when
-- that idle arrives within those 2 s: such flaps happen while typing on the lock screen,
-- and the absence keeps its earlier start (spike S1).
--
-- Backends (`idle_backend`): `auto` uses swayidle when installed and otherwise shows a
-- hint; `external` waits for `signal idle|active` over IPC; `off` disables idle detection.

local Stream = require("./stream.luau")
local Types = require("../types.luau")

type BackendHealth = Types.BackendHealth
type Host = Types.Host

export type IdleOptions = {
  backend: Types.IdleBackend,
  timeoutS: number,
  onSignal: (signal: "idle" | "active", atS: number) -> (),
}

export type IdleMonitor = {
  health: () -> BackendHealth,
  -- "swayidle" when the user should be told to install it (auto backend).
  hint: () -> string?,
  tick: () -> (),
  stop: () -> (),
}

local Idle = {}

local DEBOUNCE_MS = 2000

local HEALTH: { [string]: BackendHealth } = { running = "ok", restarting = "ok", failed = "error", stopped = "off" }

function Idle.start(host: Host, options: IdleOptions): IdleMonitor
  local monitor = {} :: IdleMonitor
  local backend = options.backend
  local hasSwayidle = backend ~= "off" and backend ~= "external" and host.commandExists("swayidle")
  local stream: Stream.Stream? = nil
  local heldActiveMs: number? = nil -- an `active` waiting for the debounce delay

  if hasSwayidle then
    -- The timeout is an integer clamped by the settings: the only interpolated value.
    local timeout = math.max(1, math.floor(options.timeoutS))
    local command = string.format("swayidle -w timeout %d 'echo idle' resume 'echo active'", timeout)
    stream = Stream.start(host, "idle", command, function(line)
      local now = host.nowMs()
      if line == "active" then
        heldActiveMs = now
      elseif line == "idle" then
        if heldActiveMs and now - heldActiveMs < DEBOUNCE_MS then
          heldActiveMs = nil -- a flap: the user is still away since the earlier idle
        else
          heldActiveMs = nil
          options.onSignal("idle", now // 1000)
        end
      end
    end)
  end

  function monitor.health(): BackendHealth
    if stream then
      return HEALTH[stream.state()]
    elseif backend == "off" then
      return "off"
    elseif backend == "external" then
      return "external"
    end
    return "unavailable"
  end

  function monitor.hint(): string?
    if backend == "auto" and not hasSwayidle then
      return "swayidle"
    end
    return nil
  end

  function monitor.tick()
    if heldActiveMs and host.nowMs() - heldActiveMs >= DEBOUNCE_MS then
      local atS = heldActiveMs // 1000
      heldActiveMs = nil
      options.onSignal("active", atS)
    end
    if stream then
      stream.tick()
    end
  end

  function monitor.stop()
    if stream then
      stream.stop()
    end
  end

  return monitor
end

return Idle
