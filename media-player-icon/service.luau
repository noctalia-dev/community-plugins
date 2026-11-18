--!nonstrict

-- ============================================================
-- State and configuration
-- ============================================================

-- Required command
local hasCommand = noctalia.commandExists("playerctl")

-- Published state
local hasError = false
local hasPlayer = false
local status = ""

-- Service state
local isStreaming = false

-- Playerctl statuses
local noPlayerStatus = "No players found"
local hasPlayerStatus = {
  Playing = true,
  Paused = true,
  Stopped = true,
}

-- ============================================================
-- Helpers
-- ============================================================

local function publish()
  noctalia.state.set("media-player-icon", {
    hasError = hasError,
    hasPlayer = hasPlayer,
    status = status,
  })
end

local function fail(message)
  hasError = true
  noctalia.log(message)
  publish()
end

-- ============================================================
-- Initial state
-- ============================================================

local function getInitialState()
  local isAccepted = noctalia.runAsync(
    { "playerctl", "status" },
    function(result)
      local stdout = noctalia.string.trim(result.stdout or "")
      local stderr = noctalia.string.trim(result.stderr or "")

      if stderr == noPlayerStatus then
        hasError = false
        hasPlayer = false
        status = ""
        publish()
        return
      end

      local didSucceed = result.exitCode == 0
      local isValid = hasPlayerStatus[stdout]

      if didSucceed and isValid then
        hasError = false
        hasPlayer = true
        status = stdout
        publish()
        return
      end

      fail(noctalia.tr("error.initial_query_failed"))
    end
  )

  if not isAccepted then
    fail(noctalia.tr("error.initial_query_failed"))
  end
end

-- ============================================================
-- Playerctl event stream
-- ============================================================

local function onLine(line)
  line = noctalia.string.trim(line)

  if line == "" then
    hasError = false
    hasPlayer = false
    status = ""
    publish()
    return
  end

  if hasPlayerStatus[line] then
    hasError = false
    hasPlayer = true
    status = line
    publish()
  end
end

local function subscribe()
  isStreaming = noctalia.runStream(
    "playerctl status --follow",
    onLine
  )

  if not isStreaming then
    fail(noctalia.tr("error.stream_failed"))
  end
end

-- ============================================================
-- Start service
-- ============================================================

if not hasCommand then
  fail(noctalia.tr("error.required_command_missing"))
  return
end

subscribe()

if isStreaming then
  getInitialState()
end
