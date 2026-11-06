--!nonstrict

local TITLE = "Auto Clicker"

local DEFAULT_INTERVAL = 100 -- ms between runs
local MIN_INTERVAL = 10
local IDLE_INTERVAL = 1000 -- update() poll rate while stopped
local DEFAULT_ARGS = { "click", "0xC0" } -- left click, used when no command is given

local CANCEL_POLL_INTERVAL = 25 -- update() poll rate while waiting to terminate a command
local KILL_ESCALATE_MS = 1000 -- send SIGKILL if SIGTERM did not end the command by then

-- Runs "ydotool <args>" after recording its PID. The shell replaces itself
-- with ydotool (exec), so the recorded PID is ydotool's own and stop() can
-- terminate exactly that process.
local WRAPPER = 'echo $$ > "$1" && shift && exec "$@"'

local running = false
local runId = 0 -- bumped on every start; ties callbacks to the run that spawned them
local inflight = nil -- the single outstanding ydotool command, until its callback fires
local seq = 0
local interval = DEFAULT_INTERVAL
local args = DEFAULT_ARGS

-- noctalia.state outlives a service restart, so always begin from "stopped".
noctalia.state.set("running", false)
noctalia.setUpdateInterval(IDLE_INTERVAL)

-- Splits a payload into words like a minimal shell: whitespace separates,
-- '...' and "..." group, and backslash escapes the next character.
-- Returns the token list, or nil plus an error message.
local function tokenize(s)
  local tokens, cur = {}, {}
  local has, quote = false, nil
  local i, n = 1, #s

  while i <= n do
    local c = string.sub(s, i, i)
    if quote then
      if c == quote then
        quote = nil
      elseif c == "\\" and quote == '"' and i < n then
        i = i + 1
        table.insert(cur, string.sub(s, i, i))
      else
        table.insert(cur, c)
      end
    elseif c == "'" or c == '"' then
      quote = c
      has = true
    elseif c == "\\" and i < n then
      i = i + 1
      table.insert(cur, string.sub(s, i, i))
      has = true
    elseif string.match(c, "%s") then
      if has then
        table.insert(tokens, table.concat(cur))
        cur, has = {}, false
      end
    else
      table.insert(cur, c)
      has = true
    end
    i = i + 1
  end

  if quote then
    return nil, "unterminated " .. quote .. " quote"
  end
  if has then
    table.insert(tokens, table.concat(cur))
  end
  return tokens
end

-- Parses "[-i <ms>] [ydotool args...]".
-- Returns interval, args (both nil on error) and an error message.
local function parse(payload)
  local tokens, err = tokenize(tostring(payload or ""))
  if not tokens then
    return nil, nil, err
  end

  local ms = DEFAULT_INTERVAL
  local idx = 1

  while idx <= #tokens do
    local t = tokens[idx]
    local value = string.match(t, "^%-%-interval=(.*)$")
    if t == "-i" or t == "--interval" then
      value = tokens[idx + 1]
      if value == nil then
        return nil, nil, t .. " needs a value in milliseconds"
      end
      idx = idx + 2
    elseif value then
      idx = idx + 1
    else
      break
    end

    local n = tonumber(value)
    if not n or n < MIN_INTERVAL then
      return nil, nil, "interval must be a number of at least " .. MIN_INTERVAL .. " (ms)"
    end
    ms = n
  end

  local rest = {}
  for j = idx, #tokens do
    table.insert(rest, tokens[j])
  end
  if #rest == 0 then
    rest = DEFAULT_ARGS
  end

  return ms, rest
end

local function pidPathFor(id)
  local dir = noctalia.pluginDataDir()
  if not dir then
    dir = noctalia.getenv("XDG_RUNTIME_DIR") or "/tmp"
  end
  return dir .. "/ydotool-" .. noctalia.nowMs() .. "-" .. id .. ".pid"
end

local function readPid(cmd)
  local raw = noctalia.readFile(cmd.pidPath)
  local pid = raw and tonumber(noctalia.string.trim(raw))
  if pid and pid > 1 and pid == math.floor(pid) then
    return pid
  end
  return nil -- not written yet (or unreadable)
end

-- Terminates the in-flight command, if any. Safe to call repeatedly: it is
-- retried from update() until the command's callback confirms it is gone.
-- Single-flight tracking (inflight) is deliberately left in place; only the
-- command's own callback clears it.
local function pollEvery(ms)
  -- While running, the user's interval already paces update(); don't override it.
  if not running then
    noctalia.setUpdateInterval(ms)
  end
end

local function terminateInflight()
  local cmd = inflight
  if not cmd then
    return
  end
  cmd.cancelled = true

  local now = noctalia.nowMs()
  if cmd.termAt and now - cmd.termAt < KILL_ESCALATE_MS then
    return -- SIGTERM already sent; give it time
  end

  local pid = readPid(cmd)
  if not pid then
    pollEvery(CANCEL_POLL_INTERVAL) -- wrapper has not recorded its PID yet
    return
  end

  local signal = "-TERM"
  if cmd.termAt then
    signal = "-KILL"
  end
  cmd.termAt = now
  noctalia.runAsync({ "kill", signal, tostring(pid) })
  pollEvery(KILL_ESCALATE_MS)
end

local function setRunning(value)
  running = value
  noctalia.state.set("running", value)
  if not value then
    noctalia.setUpdateInterval(IDLE_INTERVAL)
    terminateInflight()
  end
end

local function configure(ms, newArgs)
  interval = ms
  args = newArgs
  noctalia.setUpdateInterval(interval)
end

local function start(payload)
  local ms, newArgs, err = parse(payload)
  if not ms then
    noctalia.notifyError(TITLE, err)
    return
  end

  if running then
    -- Already running: a payload replaces the current command live.
    if string.match(tostring(payload or ""), "%S") then
      configure(ms, newArgs)
    end
    return
  end

  if not noctalia.commandExists("ydotool") then
    noctalia.notifyError(TITLE, "ydotool was not found on PATH")
    return
  end

  configure(ms, newArgs)
  runId = runId + 1
  setRunning(true)
end

local function stop()
  if running then
    setRunning(false)
  end
end

-- The bar widget asks us to stop by publishing a fresh value on this key.
-- The value read at load time is stale (state survives restarts), so ignore it.
local lastStopRequest = noctalia.state.get("stop_request")
noctalia.state.watch("stop_request", function(value)
  if value == lastStopRequest then
    return
  end
  lastStopRequest = value
  stop()
end)

function update()
  if not running then
    -- Stopped: only keep working until the cancelled command is really gone.
    if inflight then
      terminateInflight()
    else
      noctalia.setUpdateInterval(IDLE_INTERVAL)
    end
    return
  end

  -- Single-flight: never launch while a command is outstanding, even one
  -- left over from a previous run that is still being terminated.
  if inflight then
    if inflight.cancelled then
      terminateInflight() -- restarted before the old command died: keep trying
    end
    return
  end

  seq = seq + 1
  local cmd = { runId = runId, pidPath = pidPathFor(seq), cancelled = false, termAt = nil }

  local argv = { "/bin/sh", "-c", WRAPPER, "ydotool-run", cmd.pidPath, "ydotool" }
  for _, a in ipairs(args) do
    table.insert(argv, a)
  end

  noctalia.removeFile(cmd.pidPath) -- never read a stale PID from an earlier process
  inflight = cmd
  local accepted = noctalia.runAsync(argv, function(result)
    -- Only this command's own callback releases its slot.
    if inflight == cmd then
      inflight = nil
    end
    noctalia.removeFile(cmd.pidPath)

    -- Ignore results from a command that was cancelled or belongs to an
    -- older run: they must not stop or alter the current run.
    if cmd.cancelled or cmd.runId ~= runId or not running then
      return
    end

    -- If ydotool starts failing (bad args, ydotoold not running), stop
    -- rather than silently spinning forever.
    if result.exitCode ~= 0 then
      setRunning(false)
      local detail = noctalia.string.trim(result.stderr or "")
      noctalia.notifyError(TITLE, "ydotool failed, stopped. " .. detail)
    end
  end)

  if not accepted then
    inflight = nil
    setRunning(false)
    noctalia.notifyError(TITLE, "could not launch ydotool, stopped")
  end
end

function onIpc(event, payload)
  if event == "toggle" then
    if running then
      stop()
    else
      start(payload)
    end
  elseif event == "start" then
    start(payload)
  elseif event == "stop" then
    stop()
  end
end
