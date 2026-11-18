local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[clone(key)] = clone(item) end
  return result
end

local values = {}
local watchers = {}
local pending = {}

local decoded = {
  INFO_PHYSICAL = {
    default_sink_name = "sink.a",
    default_source_name = "source.main",
    server_name = "PulseAudio (on PipeWire 1.6.8)",
  },
  INFO_GROUPED = {
    default_sink_name = "noctalia_group_123_1",
    default_source_name = "source.main",
    server_name = "PulseAudio (on PipeWire 1.6.8)",
  },
  SINKS_PHYSICAL = {
    {
      name = "sink.a",
      description = "Speakers",
      mute = false,
      volume = { front_left = { value_percent = "40%" } },
      properties = {},
    },
    {
      name = "sink.b",
      description = "Headphones",
      mute = false,
      volume = { front_left = { value_percent = "40%" } },
      properties = {},
    },
  },
  SINKS_GROUPED = {
    {
      name = "sink.a",
      description = "Speakers",
      mute = false,
      volume = { front_left = { value_percent = "40%" } },
      properties = {},
    },
    {
      name = "sink.b",
      description = "Headphones",
      mute = false,
      volume = { front_left = { value_percent = "40%" } },
      properties = {},
    },
    {
      name = "noctalia_group_123_1",
      description = "Noctalia Output Group",
      mute = false,
      volume = { front_left = { value_percent = "40%" } },
      properties = {},
    },
  },
  SOURCES = {
    {
      name = "source.main",
      description = "Microphone",
      mute = false,
      volume = { front_left = { value_percent = "30%" } },
      properties = {},
    },
  },
  STREAMS_EMPTY = {},
}

local fakeTime = 123

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
  runStream = function() return true end,
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

local function completeRefresh(info, modules, sinks)
  complete("'info'", info)
  complete("'list' 'short' 'modules'", modules)
  complete("'list' 'sinks'", sinks)
  complete("'list' 'sources'", "SOURCES")
end

local originalTime = os.time
os.time = function() return fakeTime end

local serviceFile = assert(io.open("service.luau", "r"))
local serviceSource = serviceFile:read("*a")
serviceFile:close()
serviceSource = serviceSource:gsub("([%w_%.]+)%s*%+=%s*([^\n]+)", "%1 = %1 + %2")
serviceSource = serviceSource:gsub("([%w_%.]+)%s*%-=%s*([^\n]+)", "%1 = %1 - %2")
assert(load(serviceSource, "@service.luau"))()

completeRefresh("INFO_PHYSICAL", "", "SINKS_PHYSICAL")

noctalia.state.set("audio_switcher_command", {
  requestId = "create-group",
  action = "create_output_group",
  ids = { "sink.a", "sink.b" },
})
assert(pending[1].command:find("'sinks=sink.a,sink.b'", 1, true), "PipeWire must use the sinks module option")
complete("'load-module' 'module-combine-sink'", "77\n")
complete("'set-default-sink' 'noctalia_group_123_1'")
complete("'list' 'sink-inputs'", "STREAMS_EMPTY")
completeRefresh(
  "INFO_GROUPED",
  "77\tmodule-combine-sink\tsink_name=noctalia_group_123_1 sinks=sink.a,sink.b sink_properties=device.description=Noctalia_Output_Group\t\n",
  "SINKS_GROUPED"
)

local snapshot = values["audio_switcher_snapshot"]
local group = nil
for _, output in ipairs(snapshot.outputs) do
  if output.group then group = output end
end
assert(group ~= nil, "plugin-created combine sink was not detected")
assert(group.active == true, "new output group is not active")
assert(group.groupModuleId == 77, "module index was not retained")
assert(#group.groupMembers == 2, "group members were not parsed")

noctalia.state.set("audio_switcher_command", {
  requestId = "remove-group",
  action = "remove_output_group",
  id = group.id,
})
complete("'set-default-sink' 'sink.a'")
complete("'list' 'sink-inputs'", "STREAMS_EMPTY")
complete("'unload-module' '77'")
completeRefresh("INFO_PHYSICAL", "", "SINKS_PHYSICAL")

snapshot = values["audio_switcher_snapshot"]
for _, output in ipairs(snapshot.outputs) do
  assert(output.group ~= true, "removed group remained in the snapshot")
end

decoded.INFO_PHYSICAL.server_name = "pulseaudio"
noctalia.state.set("audio_switcher_command", {
  requestId = "refresh-pulseaudio",
  action = "refresh",
})
completeRefresh("INFO_PHYSICAL", "", "SINKS_PHYSICAL")
noctalia.state.set("audio_switcher_command", {
  requestId = "create-pulseaudio-group",
  action = "create_output_group",
  ids = { "sink.a", "sink.b" },
})
assert(pending[1].command:find("'slaves=sink.a,sink.b'", 1, true), "PulseAudio must use the slaves module option")
complete("'load-module' 'module-combine-sink'", "", 1)
completeRefresh("INFO_PHYSICAL", "", "SINKS_PHYSICAL")

assert(#pending == 0, "unexpected commands remain pending")

os.time = originalTime
print("audio-switcher output group tests: ok")
