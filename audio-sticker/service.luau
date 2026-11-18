--!nonstrict
-- Playback monitor service.
--
-- Builds bin/noctalia-audio-monitor from native/ the first time the plugin
-- runs, then keeps one copy alive through noctalia.runStream(). The helper
-- prints "active" when an output stream starts running and "idle" once every
-- stream has been stopped for the hysteresis window. This service republishes
-- those transitions as plugin state, so every desktop widget instance follows
-- one process instead of spawning its own.

local ACTIVE_KEY = "audio_sticker.active"
local STATUS_KEY = "audio_sticker.status"
local HELPER = "noctalia-audio-monitor"

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function helperPath()
  return (noctalia.pluginDir() or "") .. "/bin/" .. HELPER
end

local function publishError(message)
  noctalia.state.set(STATUS_KEY, { state = "error", message = message })
  noctalia.log("audio-sticker: " .. message)
end

local function onLine(line)
  if line == "active" then
    noctalia.state.set(ACTIVE_KEY, true)
  elseif line == "idle" then
    noctalia.state.set(ACTIVE_KEY, false)
  elseif line ~= "" then
    -- The helper only writes to stdout for state changes; anything else is a
    -- diagnostic worth keeping in the shell log.
    noctalia.log("audio-sticker: monitor: " .. line)
  end
end

local function hysteresisMs()
  local value = tonumber(noctalia.getConfig("hysteresis_ms")) or 500
  if value < 0 then
    return 0
  end
  if value > 5000 then
    return 5000
  end
  return math.floor(value)
end

local function spawn()
  local command = shellQuote(helperPath()) .. " --hysteresis-ms " .. tostring(hysteresisMs())
  -- runStream has no exit callback or restart policy, so the retry loop lives
  -- in one managed shell process: it re-runs the helper a moment after it
  -- exits (PipeWire restart, a leftover instance holding the pid lock, ...).
  local loop =
    "P=$PPID; while kill -0 \"$P\" 2>/dev/null; do "
    .. command
    .. "; sleep 2; done"

  if noctalia.runStream(loop, onLine) then
    noctalia.state.set(STATUS_KEY, { state = "running" })
    return
  end

  noctalia.log("audio-sticker: could not start " .. loop)
  publishError(noctalia.tr("widget.start_failed"))
end

-- The helper ships as C source under native/, so the first run compiles it
-- into bin/. Only `make` is invoked, inside the plugin's own directory.
local function ensureBuilt(thenSpawn)
  local path = helperPath()
  if noctalia.fileExists(path) then
    thenSpawn()
    return
  end

  local dir = noctalia.pluginDir() or ""
  noctalia.log("audio-sticker: building native helper (make -C native)")
  local started = noctalia.runAsync("make -C " .. shellQuote(dir .. "/native"), function(result)
    if result ~= nil and result.exitCode == 0 then
      thenSpawn()
      return
    end
    if result ~= nil and result.stderr ~= nil and result.stderr ~= "" then
      noctalia.log("audio-sticker: build failed: " .. result.stderr)
    end
    publishError(noctalia.tr("widget.build_failed"))
  end)

  if not started then
    publishError(noctalia.tr("widget.build_failed"))
  end
end

ensureBuilt(spawn)
