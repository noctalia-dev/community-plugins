--!nonstrict
-- Ping — round-trip time to a host, live in the bar.
--
-- A single [[widget]] entry: it spawns `ping` itself on the update interval
-- instead of going through a [[service]] and the state channel. One host, one
-- reader, so the extra hop would only add latency to the latency display.
--
-- Three bands, all user-configurable: below threshold_good green, below
-- threshold_warn yellow, above that red. No reply within the timeout reads
-- "offline" in the red color.
--
-- The dot breathes one full sine cycle per ping interval: brightest the moment
-- a reply lands, darkest halfway to the next check. Brightness therefore says
-- how fresh the number next to it is. A stalled connection drifts out of step
-- before it turns red.

local rtt = nil -- milliseconds shown: the last successful ping, or the average of the last n
local rttHistory = {} -- last successful ping values, oldest first, trimmed to avg_count
local offline = false -- true once a ping has failed; stays until one succeeds
local checkedAt = nil -- formatted clock time of the last completed ping
local pending = false -- a ping is in flight; do not start a second one

-- The bar has no frame tick (panels and desktop widgets only), so the sine
-- rides the update interval. Every timing decision reads nowMs() rather than
-- counting ticks: setUpdateInterval only takes effect on the *next* tick, so
-- an assumed step size drifts away from the clock immediately.
local TICK_MS = 50 -- 20 redraws per second while breathing
local DIM_ALPHA = 0.55 -- darkest point, halfway between two pings
local PEAK_ALPHA = 1.0 -- brightest point, the instant a reply lands

local beatAt = nil -- nowMs() of the last answered ping, nil = never
local nextPingAt = 0 -- nowMs() at which the next ping is due

-- `ping` writes the host straight onto a shell command line, so anything the
-- user typed into the setting has to be quoted. Single quotes with the usual
-- escape for an embedded one.
local function shq(value)
  local quoted = tostring(value or ""):gsub("'", "'\\''")
  return `'{quoted}'`
end

local function config(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil or value == "" then
    return fallback
  end
  return value
end

-- Settings come back as whatever the shell stored; a value that does not read
-- as a number falls back rather than turning into a nil arithmetic error.
local function configNumber(key, fallback)
  return tonumber(config(key, fallback)) or fallback
end

local function host()
  return noctalia.string.trim(tostring(config("host", "1.1.1.1")))
end

local function intervalMs()
  return configNumber("interval_seconds", 5) * 1000
end

local function animated()
  return config("animate", true) ~= false
end

local function avgCount()
  return math.max(1, math.floor(configNumber("avg_count", 1)))
end

-- A single failed ping drops the whole history (see offline handling in the
-- callback), so this is only ever asked to average a run of successes.
local function averageRtt()
  if #rttHistory == 0 then
    return nil
  end
  local sum = 0
  for _, value in rttHistory do
    sum += value
  end
  return sum / #rttHistory
end

-- Prefer the summary line: `rtt min/avg/max/mdev = 17.162/…` carries three
-- decimals, while the per-packet `time=17.2 ms` is already rounded. The
-- summary is also what stays correct if the ping ever sends more than one
-- packet. Fall back to the packet line when there is no summary.
local function parseRtt(stdout)
  local avg = stdout:match("rtt%s+[%w/]+%s*=%s*[%d%.]+/([%d%.]+)/")
  if avg then
    return tonumber(avg)
  end
  local time = stdout:match("time[=<]([%d%.]+)%s*ms")
  return time and tonumber(time) or nil
end

local function color()
  if offline or rtt == nil then
    return config("color_bad", "#E4887A")
  end
  if rtt < configNumber("threshold_good", 20) then
    return config("color_good", "#66BA83")
  end
  if rtt < configNumber("threshold_warn", 100) then
    return config("color_warn", "#C79E47")
  end
  return config("color_bad", "#E4887A")
end

-- How bright the dot is right now. One full sine cycle per ping interval,
-- phased so the peak lands on the reply: brightness is the age of the number
-- beside it, brightest when it was just measured, darkest just before the next
-- check. Offline holds at full - a dead link is a steady red dot, not a
-- breathing one.
local function pulseAlpha()
  if offline or not animated() or beatAt == nil then
    return PEAK_ALPHA
  end
  local period = intervalMs()
  -- cos(0) = 1 puts the peak on the reply; the cycle bottoms out at period/2
  -- and comes back up as the next ping falls due. A late reply simply restarts
  -- the phase, so a stalling connection visibly loses its rhythm.
  local phase = ((noctalia.nowMs() - beatAt) % period) / period
  local wave = (math.cos(phase * 2 * math.pi) + 1) / 2
  return DIM_ALPHA + (PEAK_ALPHA - DIM_ALPHA) * wave
end

-- Colors take an alpha suffix (#RRGGBB + AA). Applied to the fill rather than
-- the node's `opacity`, which is a group opacity and would fade the number
-- alongside the dot.
local function withAlpha(hex, alpha)
  return string.format("%s%02X", hex, math.floor(math.clamp(alpha, 0, 1) * 255 + 0.5))
end

local function formatRtt(value)
  return string.format("%dms", value + 0.5)
end

local function text()
  if offline then
    return noctalia.tr("widget.offline")
  end
  if rtt == nil then
    return noctalia.tr("widget.waiting")
  end
  return formatRtt(rtt)
end

local function render()
  local fg = color()
  local size = configNumber("dot_size", 8)
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, {
    ui.box({
      width = size,
      height = size,
      radius = size / 2,
      fill = withAlpha(fg, pulseAlpha()),
    }),
    ui.label({ text = text(), color = fg, fontWeight = "bold" }),
  }))

  local rows = {
    { key = noctalia.tr("widget.tooltip_host"), value = host() },
    {
      key = noctalia.tr("widget.tooltip_latency"),
      value = (not offline and rtt ~= nil) and formatRtt(rtt) or noctalia.tr("widget.offline"),
    },
  }
  if checkedAt then
    table.insert(rows, { key = noctalia.tr("widget.tooltip_checked"), value = checkedAt })
  end
  barWidget.setTooltip(rows)
end

local function ping()
  if pending then
    return
  end
  pending = true
  -- Arm the next check from the moment this one starts, so a slow reply does
  -- not push the cadence out; the callback re-arms from its own clock reading.
  nextPingAt = noctalia.nowMs() + intervalMs()

  local timeout = configNumber("timeout_seconds", 2)
  local cmd = `ping -n -c 1 -W {timeout} {shq(host())}`

  -- The kill timeout is the ping timeout plus a second: `ping -W` already
  -- bounds the wait, so the outer one only catches a process that never
  -- returns at all.
  local launched = noctalia.runAsync(cmd, function(result)
    pending = false
    checkedAt = noctalia.formatTime("%H:%M:%S")
    local value = result.exitCode == 0 and parseRtt(result.stdout) or nil
    if value then
      table.insert(rttHistory, value)
      while #rttHistory > avgCount() do
        table.remove(rttHistory, 1)
      end
      rtt = averageRtt()
      offline = false
      -- The cycle is phased on the arrival of *this* reply, not on where the
      -- ping was sent: what the dot tracks is the answer, not the ask.
      beatAt = noctalia.nowMs()
    else
      offline = true
      rttHistory = {}
      rtt = nil
      beatAt = nil
    end
    -- The reply is the anchor for the next check too, so the sine always has a
    -- whole interval to run through.
    nextPingAt = noctalia.nowMs() + intervalMs()
    noctalia.setUpdateInterval(TICK_MS)
    render()
  end, (timeout + 1) * 1000)

  if not launched then
    pending = false
    offline = true
    beatAt = nil
    checkedAt = noctalia.formatTime("%H:%M:%S")
    render()
  end
end
function update()
  -- Breathing needs a steady fast tick; a resting dot only needs to wake up
  -- when the next ping is due. Both branches re-arm from nowMs(), never from
  -- an assumed step, because setUpdateInterval only lands on the next tick.
  local now = noctalia.nowMs()

  if now >= nextPingAt then
    ping()
    return -- ping() re-arms nextPingAt and renders from its own callback
  end

  if animated() and not offline and beatAt ~= nil then
    noctalia.setUpdateInterval(TICK_MS)
    render()
  else
    -- Nothing moves: sleep until the ping is due, with a floor so a pathological
    -- clock cannot spin the entry.
    noctalia.setUpdateInterval(math.max(nextPingAt - now, TICK_MS))
  end
end
