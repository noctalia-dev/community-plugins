--!nonstrict
-- Timed launcher provider.
--
--   /timer 1h5      start a 1 hour 5 minute timer
--   /timer 1s4h     units may appear in any order
--   /timer 3h2s message   use the message in the notification
--   /timer          list running timers; selecting one stops it
--   /timer stop     stop all running timers

local duration = require("./lib/duration.luau")

local lastQuery = nil
local seq = tonumber(noctalia.state.get("timed.lastCommand")) or 0

local function getTimers()
  local state = noctalia.state.get("timed.list")
  if type(state) == "table" and type(state.timers) == "table" then
    return state.timers
  end
  return {}
end

local function emptyRow()
  return {
    id = "none",
    title = noctalia.tr("launcher.no_timers"),
    subtitle = noctalia.tr("launcher.hint"),
    glyph = "clock",
  }
end

local function timerRows()
  local rows = {}
  local now = noctalia.nowMs()
  local timeFormat = noctalia.timeFormat()
  local dateFormat = noctalia.dateFormat()
  for _, timer in ipairs(getTimers()) do
    local remaining = math.max(0, math.ceil((timer.endsAt - now) / 1000))
    local title = noctalia.tr("launcher.stop")
    if timer.message then
      title = title .. " (" .. timer.message .. ")"
    end
    table.insert(rows, {
      id = "stop:" .. timer.id,
      title = title,
      subtitle = noctalia.tr("launcher.ends_at", {
        duration = duration.human(remaining),
        time = noctalia.formatTime(remaining >= 86400 and dateFormat or timeFormat, timer.endsAt // 1000),
      }),
      glyph = "player-stop",
    })
  end
  return rows
end

local function render(text)
  lastQuery = text
  local query = noctalia.string.trim(text)
  local rows

  if query == "" then
    rows = timerRows()
    if #rows == 0 then
      rows = { emptyRow() }
    end
  elseif query == "stop" or query == "stop all" then
    local count = #getTimers()
    if count == 0 then
      rows = { emptyRow() }
    else
      rows = { {
        id = "stop-all",
        title = noctalia.tr("launcher.stop_all"),
        subtitle = noctalia.tr("launcher.running", { count = count }),
        glyph = "player-stop",
      } }
    end
  else
    local seconds, message = duration.split(query)
    if seconds then
      local subtitle
      if message then
        subtitle = noctalia.tr("launcher.message", {
          duration = duration.human(seconds),
          message = message,
        })
      else
        subtitle = duration.human(seconds)
      end
      rows = { {
        id = "start:" .. seconds .. ":" .. (message or ""),
        title = noctalia.tr("launcher.start", { time = duration.clock(seconds) }),
        subtitle = subtitle,
        glyph = "clock",
      } }
    else
      rows = { {
        id = "invalid",
        title = noctalia.tr("launcher.invalid"),
        subtitle = noctalia.tr("launcher.hint"),
        glyph = "alert-triangle",
      } }
    end
  end

  launcher.setResults(text, rows)
end

local function send(command)
  seq = math.max(noctalia.nowMs(), seq + 1)
  command.n = seq
  noctalia.state.set("timed.command", command)
  lastQuery = nil
end

function onQuery(text)
  render(text)
end

function onActivate(id)
  local seconds, message = id:match("^start:(%d+):(.*)$")
  if seconds then
    send({ action = "start", seconds = tonumber(seconds), message = message ~= "" and message or nil })
    return
  end

  if id == "stop-all" then
    send({ action = "stop-all" })
    return
  end

  local timerId = id:match("^stop:(.+)$")
  if timerId then
    send({ action = "stop", id = timerId })
  end
end

noctalia.state.watch("timed.list", function()
  if lastQuery ~= nil then
    render(lastQuery)
  end
end)
