--!nonstrict

local TITLE = "Auto Clicker"

local DEFAULT_INTERVAL = 100 -- ms between runs
local MIN_INTERVAL = 10
local IDLE_INTERVAL = 1000 -- update() poll rate while stopped
local DEFAULT_ARGS = { "click", "0xC0" } -- left click, used when no command is given

local running = false
local busy = false -- a ydotool call is still in flight
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

local function setRunning(value)
  running = value
  noctalia.state.set("running", value)
  if not value then
    busy = false
    noctalia.setUpdateInterval(IDLE_INTERVAL)
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
  if not running or busy then
    return
  end

  local argv = { "ydotool" }
  for _, a in ipairs(args) do
    table.insert(argv, a)
  end

  busy = true
  noctalia.runAsync(argv, function(result)
    busy = false
    -- If ydotool starts failing (bad args, ydotoold not running), stop
    -- rather than silently spinning forever.
    if result.exitCode ~= 0 and running then
      setRunning(false)
      local detail = noctalia.string.trim(result.stderr or "")
      noctalia.notifyError(TITLE, "ydotool failed, stopped. " .. detail)
    end
  end)
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
