--!nonstrict

-- Service state
local isAvailable = noctalia.commandExists("swaymsg")
local isStreaming = false

-- Published state
local mode = nil
local isPango = false
local hasError = false

-- Helpers
local function publish()
  noctalia.state.set("sway-mode", {
    mode = mode,
    isPango = isPango,
    hasError = hasError,
  })
end

local function fail(message)
  hasError = true
  noctalia.log(message)
  publish()
end

-- Initial state
local function getInitialMode()
  local isAccepted = noctalia.runAsync({ "swaymsg", "--type", "get_binding_state" }, function(result)
    if result.exitCode ~= 0 then
      fail(noctalia.tr("error.initial_state_failed"))
      return
    end

    local decoded = noctalia.json.decode(result.stdout)

    if type(decoded) ~= "table" then
      fail(noctalia.tr("error.decode_failed"))
      return
    end

    if type(decoded.name) ~= "string" then
      fail(noctalia.tr("error.invalid_data"))
      return
    end

    mode = decoded.name
    publish()
  end)

  if not isAccepted then
    fail(noctalia.tr("error.initial_state_failed"))
  end
end

-- Sway event stream
local function onLine(line)
  local decoded = noctalia.json.decode(line)

  if type(decoded) ~= "table" then
    fail(noctalia.tr("error.decode_failed"))
    return
  end

  if type(decoded.change) ~= "string" or type(decoded.pango_markup) ~= "boolean" then
    fail(noctalia.tr("error.invalid_data"))
    return
  end

  -- Skip processing for sway shutdown events
  if decoded.change == "exit" then
    return
  end

  mode = decoded.change
  isPango = decoded.pango_markup
  hasError = false

  publish()
end

local function subscribe()
  if not isAvailable or isStreaming then
    return
  end

  isStreaming = noctalia.runStream(
    'swaymsg --monitor --type subscribe \'["mode"]\'',
    onLine
  )

  if not isStreaming then
    fail(noctalia.tr("error.stream_failed"))
  end
end

-- Get initial state, since subscribe only logs changes
getInitialMode()
subscribe()
