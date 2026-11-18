local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[clone(key)] = clone(item) end
  return result
end

local values = {}
local watchers = {}
local pending = {}
local config = {}
local intervals = {}
local streamCommands = {}
local streamCallback = nil

local decoded = {
  INFO = {
    default_sink_name = "sink.main",
    default_source_name = "source.main",
    server_name = "PulseAudio (on PipeWire 1.6.8)",
  },
  SINKS = {
    {
      name = "sink.main",
      description = "Main output",
      mute = false,
      volume = { front_left = { value_percent = "42%" } },
      properties = {},
    },
  },
  SOURCES = {
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
  UNMUTED = { mute = false },
}

noctalia = {
  pluginDataDir = function() return nil end,
  getConfig = function(key) return config[key] end,
  commandExists = function(command) return command == "pactl" end,
  readFile = function() return nil end,
  writeFile = function() return true end,
  setUpdateInterval = function(ms) intervals[#intervals + 1] = ms end,
  runAsync = function(command, callback)
    pending[#pending + 1] = { command = command, callback = callback }
    return true
  end,
  runStream = function(command, callback)
    streamCommands[#streamCommands + 1] = command
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

local function completeFullRefresh()
  complete("'info'", "INFO")
  complete("'list' 'short' 'modules'", "")
  complete("'list' 'sinks'", "SINKS")
  complete("'list' 'sources'", "SOURCES")
end

local function lastInterval()
  return intervals[#intervals]
end

local serviceFile = assert(io.open("service.luau", "r"))
local serviceSource = serviceFile:read("*a")
serviceFile:close()
serviceSource = serviceSource:gsub("([%w_%.]+)%s*%+=%s*([^\n]+)", "%1 = %1 + %2")
serviceSource = serviceSource:gsub("([%w_%.]+)%s*%-=%s*([^\n]+)", "%1 = %1 - %2")
assert(load(serviceSource, "@service.luau"))()
assert(type(streamCallback) == "function", "pactl subscription was not started")
assert(#streamCommands == 1, "service started more than one pactl subscription")
assert(streamCommands[1]:find("pactl subscribe", 1, true) ~= nil, "unexpected stream command: " .. streamCommands[1])

assert(#intervals == 1 and lastInterval() == 60000, "background refresh interval is not 60 seconds")
completeFullRefresh()
assert(#pending == 0, "initial refresh left commands pending")

noctalia.state.set("audio_switcher_panel_open", true)
assert(lastInterval() == 5000, "open panel did not switch to the 5 second interval")
noctalia.state.set("audio_switcher_panel_open", true)
assert(#intervals == 2, "unchanged panel state reset the update interval")
noctalia.state.set("audio_switcher_panel_open", false)
assert(lastInterval() == 60000, "closed panel did not restore the background interval")

config.refresh_interval_seconds = 120
config.panel_refresh_interval_seconds = 2
onConfigChanged()
assert(lastInterval() == 120000, "background interval setting was ignored")
noctalia.state.set("audio_switcher_panel_open", true)
assert(lastInterval() == 2000, "panel interval setting was ignored")
noctalia.state.set("audio_switcher_panel_open", false)
config.refresh_interval_seconds = 0
onConfigChanged()
assert(lastInterval() == 1000, "interval below one second was not clamped")
config.refresh_interval_seconds = nil
config.panel_refresh_interval_seconds = nil
onConfigChanged()
assert(lastInterval() == 60000, "missing setting did not fall back to the default")

streamCallback("Event 'change' on card #47")
completeFullRefresh()
assert(#pending == 0, "card event started more than one refresh")

streamCallback("Event 'change' on card #47")
streamCallback("Event 'new' on sink #80")
streamCallback("Event 'new' on source #81")
completeFullRefresh()
completeFullRefresh()
assert(#pending == 0, "an event burst was not coalesced into one follow-up refresh")

streamCallback("Event 'change' on sink #80")
complete("'get-sink-volume'", "OUTPUT_VOLUME")
complete("'get-sink-mute'", "UNMUTED")
assert(#pending == 0, "sink change event started a full device refresh")

streamCallback("Event 'change' on client #12")
assert(#pending == 0, "client event started a refresh")

update()
assert(#streamCommands == 1, "update() restarted a running subscription")
completeFullRefresh()

streamCallback("audio-switcher: pactl subscribe ended")
completeFullRefresh()
assert(#streamCommands == 1, "ended subscription restarted before the next update")
update()
assert(#streamCommands == 2, "update() did not restart the ended subscription")
completeFullRefresh()
update()
assert(#streamCommands == 2, "update() restarted the subscription twice")
completeFullRefresh()
assert(#pending == 0, "refresh left commands pending")

print("audio-switcher refresh event tests: ok")
