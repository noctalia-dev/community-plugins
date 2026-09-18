--!nonstrict
-- Agent Glow watcher — headless [[service]] entry.
--
-- Process *existence* is not activity (claude/opencode sessions linger idle),
-- so each tick runs activity.py: it samples /proc CPU times over a short
-- window and reports per-family CPU percent. Only families at or above the
-- configured CPU threshold count as working. Transitions stay debounced:
-- 2 consecutive hot ticks to light up, 3 cold ticks to go dark.

noctalia.setUpdateInterval(2000)

local active = false
local hits = 0
local misses = 0
local checking = false
local sweepAt = 0 -- os.time() when the in-flight sweep started
local pythonAvailable = noctalia.commandExists("python3")
local probePath = noctalia.pluginDir() .. "/activity.py"

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return value
end

local function threshold()
  local value = tonumber(cfg("activity_threshold", 15)) or 15
  return math.max(1, math.min(200, value))
end

local function heartbeatTimeout()
  local value = tonumber(cfg("heartbeat_timeout", 45)) or 45
  return math.max(5, math.min(300, value))
end

local function splitPatterns(raw)
  local patterns = {}
  for token in string.gmatch(tostring(raw), "([^,]+)") do
    local needle = noctalia.string.trim(token)
    if needle ~= "" then
      table.insert(patterns, needle)
    end
  end
  return patterns
end

local function heartbeatHot(pattern, now, timeout)
  local safe = string.gsub(string.lower(pattern), "[^%w]", "")
  if safe == "" then
    return false
  end
  local runtime = noctalia.getenv("XDG_RUNTIME_DIR") or "/tmp"
  local info, _ = noctalia.fileInfo(runtime .. "/agent-glow." .. safe .. ".hb")
  if type(info) ~= "table" then
    return false
  end
  local mtime = tonumber(info.mtime) or 0
  if mtime > now then
    mtime = mtime / 1000 -- host reports milliseconds; normalize to seconds
  end
  return (now - mtime) < timeout
end

local function contains(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

local function settle(hot, sessions)
  checking = false
  local found = #hot
  if found > 0 then
    hits += 1
    misses = 0
  else
    misses += 1
    hits = 0
  end

  local changed = false
  if not active and hits >= 2 then
    active = true
    changed = true
  elseif active and misses >= 3 then
    active = false
    changed = true
  end

  if changed then
    noctalia.log(`[agent-glow] agents {active and "working" or "idle"} (hot={table.concat(hot, ",")})`)
  end
  if changed and cfg("notify", false) then
    if active then
      noctalia.notify(noctalia.tr("title"), noctalia.tr("started"))
    else
      noctalia.notify(noctalia.tr("title"), noctalia.tr("stopped"))
    end
  end
  noctalia.state.set("status", {
    active = active,
    count = active and found or 0,
    hot = hot,
    sessions = if type(sessions) == "table" then sessions else {},
  })
end

local function skip(reason)
  checking = false
  if reason ~= nil then
    noctalia.log(`[agent-glow] probe skipped: {reason}`)
  end
end

-- Families with real session collectors: CPU never decides hotness for
-- these (unreliable) — only transcript/db freshness or heartbeats do.
-- CPU remains a fallback signal for any other configured family.
local SESSION_FAMILIES = { opencode = true, claude = true }

local function sessionTimeout()
  local value = tonumber(cfg("session_timeout", 120)) or 120
  return math.max(15, math.min(900, value))
end

function onConfigChanged()
  hits = 0
  misses = 0
  checking = false
end

function update()
  local interval = tonumber(cfg("poll_interval", 2)) or 2
  interval = math.max(1, math.min(30, interval))
  noctalia.setUpdateInterval(interval * 1000)

  if checking then
    if os.time() - sweepAt < interval + 8 then
      return -- previous sweep still in flight; skip this tick
    end
    checking = false -- stale sweep; start fresh
  end
  if not pythonAvailable then
    return
  end
  checking = true
  sweepAt = os.time()

  local raw = tostring(cfg("agents", "opencode,claude,codex,gemini,aider,goose"))
  local ok = noctalia.runAsync({
    "python3",
    probePath,
    "--patterns",
    raw,
    "--threshold",
    tostring(threshold()),
    "--session-timeout",
    tostring(sessionTimeout()),
  }, function(result)
    if result.timedOut or result.exitCode ~= 0 then
      skip(result.timedOut and "timed out" or "exit " .. tostring(result.exitCode))
      return
    end
    local decoded = noctalia.json.decode(result.stdout)
    if type(decoded) ~= "table" or type(decoded.hot) ~= "table" then
      skip("unparseable output")
      return
    end
    local sessions = {}
    if type(decoded.sessions) == "table" then
      sessions = decoded.sessions
    end
    -- Union: session-hot families, agent-reported heartbeats, and CPU-hot
    -- families that have no session collector (CPU fallback only).
    local now = os.time()
    local timeout = heartbeatTimeout()
    local hot = {}
    for _, session in ipairs(sessions) do
      if type(session) == "table" and session.is_hot == true then
        local family = tostring(session.family or "")
        if family ~= "" and not contains(hot, family) then
          table.insert(hot, family)
        end
      end
    end
    for _, pattern in ipairs(splitPatterns(raw)) do
      local key = string.lower(pattern) -- probe reports lowercased families
      if not contains(hot, key) then
        if heartbeatHot(pattern, now, timeout) then
          table.insert(hot, key)
        elseif SESSION_FAMILIES[key] ~= true and contains(decoded.hot, key) then
          table.insert(hot, key)
        end
      end
    end
    settle(hot, sessions)
  end, 10000)
  if not ok then
    skip("could not spawn probe")
  end
end
