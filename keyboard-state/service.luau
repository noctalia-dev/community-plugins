--!nonstrict

-- Service state
local hasCommands = noctalia.commandExists("evsieve") and noctalia.commandExists("evtest")
local isStreaming = false

-- Published state
local hasError = false
local capsLocked = false
local numLocked = false
local scrollLocked = false

-- Settings
local inputDevice = noctalia.getConfig("input_device")

-- Constants
local evtest = {
  caps = "LED_CAPSL",
  num = "LED_NUML",
  scroll = "LED_SCROLLL",
}

local evsieve = {
  caps = "led:capsl",
  num = "led:numl",
  scroll = "led:scrolll",
}

-- Helpers
local function publish()
  noctalia.state.set("keyboard-state", {
    hasError = hasError,
    capsLocked = capsLocked,
    numLocked = numLocked,
    scrollLocked = scrollLocked,
  })
end

local function fail(message)
  hasError = true
  noctalia.log(message)
  publish()
end

-- Quote value so it's treated as a single string argument by the shell
local function shellQuote(str)
  return "'" .. str:gsub("'", "'\\''") .. "'"
end

-- Get initial state
local function queryLedState(key, callback)
  local isAccepted = noctalia.runAsync(
    { "evtest", "--query", inputDevice, "EV_LED", key },
    function(result)
      -- with evtest 0 is inactive and 10 is active
      if result.exitCode ~= 0 and result.exitCode ~= 10 then
        callback(nil)
        return
      end

      callback(result.exitCode == 10)
    end
  )

  if not isAccepted then
    callback(nil)
  end
end

local function getInitialState()
  local keys = { evtest.caps, evtest.num, evtest.scroll }
  local completed = 0

  for _, key in ipairs(keys) do
    queryLedState(key, function(state)
      if state == nil then
        fail(noctalia.tr("error.failed_initial_query"))
        return
      end

      if key == evtest.caps then
        capsLocked = state
      elseif key == evtest.num then
        numLocked = state
      elseif key == evtest.scroll then
        scrollLocked = state
      end

      completed = completed + 1

      if completed == #keys then
        hasError = false
        publish()
      end
    end)
  end
end

-- Ensure that we don't try to monitor an invalid path
local function isValidInputDevice()
  if type(inputDevice) ~= "string" or inputDevice == "" then
    return false
  end

  local isValidPath = inputDevice:match("^/dev/input/event") ~= nil
    or inputDevice:match("^/dev/input/by%-id/") ~= nil
    or inputDevice:match("^/dev/input/by%-path/") ~= nil

  if not isValidPath then
    return false
  end

  return noctalia.fileExists(inputDevice)
end

-- Keyboard event stream
local function onLine(line)
  local ledcode = line:match("type:code = (led:%a+)")
  if not ledcode then
    return
  end

  local value = line:match("value = (%d+)")
  if not value then
    return
  end

  -- with evsieve 0 is inactive and 1 is active
  local state = value == "1"
  if ledcode == evsieve.caps then
    capsLocked = state
  elseif ledcode == evsieve.num then
    numLocked = state
  elseif ledcode == evsieve.scroll then
    scrollLocked = state
  else
    return
  end

  hasError = false
  publish()
end

local function subscribe()
  if not hasCommands or isStreaming then
    return
  end

  if not isValidInputDevice() then
    fail(noctalia.tr("error.invalid_input_device"))
    return
  end

  local leds = table.concat({
    evsieve.num,
    evsieve.caps,
    evsieve.scroll,
  }, " ")

  isStreaming = noctalia.runStream(
    "evsieve --input " .. shellQuote(inputDevice) .. " --print " .. leds,
    onLine
  )

  if not isStreaming then
    fail(noctalia.tr("error.stream_failed"))
  end
end

-- Start service
subscribe()

if isStreaming then
  getInitialState()
end
