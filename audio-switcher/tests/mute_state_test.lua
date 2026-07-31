local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[clone(key)] = clone(item) end
  return result
end

local values = {}
local watchers = {}
local pending = {}
local streamCallback = nil

local decoded = {
  INFO = {
    default_sink_name = "sink.main",
    default_source_name = "source.main",
  },
  SINKS_UNMUTED = {
    {
      name = "sink.main",
      description = "Main output",
      mute = false,
      volume = { front_left = { value_percent = "42%" } },
      properties = {},
    },
  },
  SOURCES_UNMUTED = {
    {
      name = "source.main",
      description = "Main input",
      mute = false,
      volume = { front_left = { value_percent = "37%" } },
      properties = {},
    },
  },
  OUTPUT_VOLUME = {
    volume = { front_left = { value_percent = "42%" } },
  },
  INPUT_VOLUME = {
    volume = { front_left = { value_percent = "37%" } },
  },
  MUTED = { mute = true },
  UNMUTED = { mute = false },
}

noctalia = {
  pluginDataDir = function() return nil end,
  getConfig = function() return nil end,
  commandExists = function(command) return command == "pactl" end,
  readFile = function() return nil end,
  writeFile = function() return true end,
  setUpdateInterval = function() end,
  runAsync = function(command, callback)
    pending[#pending + 1] = { command = command, callback = callback }
    return true
  end,
  runStream = function(_command, callback)
    streamCallback = callback
    return true
  end,
  json = {
    decode = function(value) return clone(decoded[value]) end,
    encode = function() return "PREFERENCES" end,
  },
  string = {
    trim = function(value) return tostring(value or ""):match("^%s*(.-)%s*$") or "" end,
  },
  state = {
    get = function(key) return clone(values[key]) end,
    set = function(key, value)
      values[key] = clone(value)
      if watchers[key] ~= nil then watchers[key](clone(value)) end
    end,
    watch = function(key, callback) watchers[key] = callback end,
  },
  tr = function(key) return key end,
  log = function() end,
  notify = function() end,
  notifyError = function() end,
}

local function complete(expected, stdout, exitCode)
  local call = table.remove(pending, 1)
  assert(call ~= nil, "expected pending command containing " .. expected)
  assert(call.command:find(expected, 1, true) ~= nil, "unexpected command: " .. call.command)
  call.callback({
    exitCode = exitCode or 0,
    stdout = stdout or "",
    stderr = "",
    timedOut = false,
    stdoutTruncated = false,
    stderrTruncated = false,
  })
end

local function snapshot()
  return values["audio_switcher_snapshot"]
end

local serviceFile = assert(io.open("service.luau", "r"))
local serviceSource = serviceFile:read("*a")
serviceFile:close()
serviceSource = serviceSource:gsub("([%w_%.]+)%s*%+=%s*([^\n]+)", "%1 = %1 + %2")
serviceSource = serviceSource:gsub("([%w_%.]+)%s*%-=%s*([^\n]+)", "%1 = %1 - %2")
assert(load(serviceSource, "@service.luau"))()
assert(type(streamCallback) == "function", "pactl subscription was not started")

complete("'info'", "INFO")
complete("'list' 'sinks'", "SINKS_UNMUTED")
complete("'list' 'sources'", "SOURCES_UNMUTED")

assert(snapshot().outputMuted == false, "initial output mute state is incorrect")
assert(snapshot().inputMuted == false, "initial input mute state is incorrect")

noctalia.state.set("audio_switcher_command", {
  requestId = "mute-output",
  action = "toggle_output_mute",
})
streamCallback("Event 'change' on sink #1")
complete("'set-sink-mute'", "")

assert(snapshot().outputMuted == true, "successful output toggle did not update the snapshot immediately")
assert(snapshot().outputs[1].muted == true, "successful output toggle did not update the active device")
complete("'get-sink-volume'", "OUTPUT_VOLUME")
complete("'get-sink-mute'", "MUTED")
complete("'get-sink-volume'", "OUTPUT_VOLUME")
complete("'get-sink-mute'", "MUTED")
assert(snapshot().outputMuted == true, "authoritative output mute refresh lost the toggled state")

noctalia.state.set("audio_switcher_command", {
  requestId = "mute-input",
  action = "toggle_input_mute",
})
complete("'set-source-mute'", "")

assert(snapshot().inputMuted == true, "successful input toggle did not update the snapshot immediately")
assert(snapshot().inputs[1].muted == true, "successful input toggle did not update the active device")
complete("'get-source-volume'", "INPUT_VOLUME")
complete("'get-source-mute'", "MUTED")
assert(snapshot().inputMuted == true, "authoritative input mute refresh lost the toggled state")

noctalia.state.set("audio_switcher_command", {
  requestId = "unmute-output",
  action = "toggle_output_mute",
})
complete("'set-sink-mute'", "")

assert(snapshot().outputMuted == false, "successful output unmute did not update the snapshot immediately")
assert(snapshot().inputMuted == true, "output unmute changed the input mute state")
complete("'get-sink-volume'", "OUTPUT_VOLUME")
complete("'get-sink-mute'", "UNMUTED")
assert(snapshot().outputMuted == false, "authoritative output refresh lost the unmuted state")

assert(#pending == 0, "mute toggles unexpectedly started a full device refresh")

print("audio-switcher mute state tests: ok")
