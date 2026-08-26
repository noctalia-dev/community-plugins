-- tests/writer_apply_validation_failure_test.lua
local stateValues = {}
local watchers = {}
local writtenFiles = {}
local ranCommands = {}
local hyprlandConfigPath = "/tmp/hdc-test-fail/hyprland.lua"

noctalia = {
  getConfig = function(key)
    if key == "hyprland_config" then return hyprlandConfigPath end
    return nil
  end,
  expandPath = function(path) return path end,
  readFile = function(path)
    if path == hyprlandConfigPath then return 'require("config.monitors")\n' end
    return nil
  end,
  writeFile = function(path, content) writtenFiles[path] = content; return true end,
  fileExists = function(path) return writtenFiles[path] ~= nil or path == hyprlandConfigPath end,
  commandExists = function(name) return name == "hyprctl" or name == "Hyprland" end,
  runAsync = function(command, callback)
    ranCommands[#ranCommands + 1] = command
    if command:find("^Hyprland %-%-verify%-config") then
      callback({ exitCode = 1, stdout = "", stderr = "config error: bad value" })
    else
      callback({ exitCode = 0, stdout = "" })
    end
    return true
  end,
  state = {
    set = function(key, value)
      stateValues[key] = value
      if watchers[key] ~= nil then watchers[key](value) end
    end,
    get = function(key) return stateValues[key] end,
    watch = function(key, callback) watchers[key] = callback end,
  },
  notifyError = function() end,
}

assert(loadfile("writer_service.luau"))()

noctalia.state.set("hypr-display-config.apply_request", {
  request_id = "req-2",
  monitors = {
    { name = "eDP-1", width = 1920, mode = "preferred", scale = 1, transform = 0,
      disabled = false, workspaces = {} },
  },
})

local result = stateValues["hypr-display-config.apply_result"]
assert(type(result) == "table", "no result published")
assert(result.status == "error", "expected error status when validation fails")
assert(type(result.message) == "string" and #result.message > 0, "error result should carry a message")
assert(writtenFiles[hyprlandConfigPath] == nil,
  "hyprland.lua must not be rewritten when validation fails")

-- Regression check for the Critical temp-path-extension bug (see
-- writer_apply_test.lua for the full explanation): every
-- `Hyprland --verify-config` target must still end in `.lua`.
local sawVerify = false
for _, command in ipairs(ranCommands) do
  if command:match("^Hyprland %-%-verify%-config") then
    sawVerify = true
    assert(command:match("%.lua'?$") ~= nil,
      "verify-config path must end in .lua, got: " .. command)
  end
end
assert(sawVerify, "expected a Hyprland --verify-config call")

print("writer_apply_validation_failure_test: ok")
