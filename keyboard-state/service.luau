--!nonstrict

-- ============================================================
-- State and configuration
-- ============================================================

-- Required commands
local hasCommands = noctalia.commandExists("evsieve") and noctalia.commandExists("evtest")

-- Published state
local hasError = false
local capsLocked = false
local numLocked = false
local scrollLocked = false

-- Service state and configuration
local isStreaming = false
local inputDevice = noctalia.getConfig("input_device")

-- LED identifiers used by evtest
local evtest = {
  caps = "LED_CAPSL",
  num = "LED_NUML",
  scroll = "LED_SCROLLL",
}

-- LED identifiers used by evsieve
local evsieve = {
  caps = "led:capsl",
  num = "led:numl",
  scroll = "led:scrolll",
}

-- ============================================================
-- Helpers
-- ============================================================

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

local function shellQuote(str)
  return "'" .. str:gsub("'", "'\\''") .. "'"
end

-- ============================================================
-- Initial state
-- ============================================================

local function queryLedState(key, callback)
  local isAccepted = noctalia.runAsync(
    { "evtest", "--query", inputDevice, "EV_LED", key },
    function(result)
      -- evtest: 0 = inactive, 10 = active
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

-- ============================================================
-- Input device validation
-- ============================================================

local function isAllowedDeviceByte(byte)
  return (byte >= 48 and byte <= 57) -- 0-9
    or (byte >= 65 and byte <= 90) -- A-Z
    or (byte >= 97 and byte <= 122) -- a-z
    or byte == 47 -- /
    or byte == 46 -- .
    or byte == 95 -- _
    or byte == 45 -- -
    or byte == 58 -- :
    or byte == 43 -- +
end

local function isAllowedDevicePath(path)
  return path:match("^/dev/input/event") ~= nil
    or path:match("^/dev/input/by%-id/") ~= nil
    or path:match("^/dev/input/by%-path/") ~= nil
end

local function isValidInputDevice()
  -- Must be a non empty string
  if type(inputDevice) ~= "string" or inputDevice == "" then
    return false
  end

  -- Must use an allowed device path
  if not isAllowedDevicePath(inputDevice) then
    return false
  end

  -- Must not contain path traversal
  if inputDevice:find("..", 1, true) ~= nil then
    return false
  end

  -- Must not use disallowed characters
  for i = 1, #inputDevice do
    if not isAllowedDeviceByte(inputDevice:byte(i)) then
      return false
    end
  end

  -- Must be an existing device
  return noctalia.fileExists(inputDevice)
end

-- ============================================================
-- Keyboard event stream
-- ============================================================

local function onLine(line)
  local ledcode = line:match("type:code = (led:%a+)")
  if not ledcode then
    return
  end

  local value = line:match("value = (%d+)")
  if not value then
    return
  end

  -- evsieve: 0 = inactive, 1 = active
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
  -- Only monitor these leds
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

-- ============================================================
-- Start service
-- ============================================================

if not hasCommands then
  fail(noctalia.tr("error.required_command_missing"))
  return
end

if not isValidInputDevice() then
  fail(noctalia.tr("error.invalid_input_device"))
  return
end

subscribe()

if isStreaming then
  getInitialState()
end
