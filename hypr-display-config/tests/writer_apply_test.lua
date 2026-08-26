-- tests/writer_apply_test.lua
local stateValues = {}
local watchers = {}
local writtenFiles = {}
local ranCommands = {}
local hyprlandConfigPath = "/tmp/hdc-test/hyprland.lua"
local managedFilePath = "/tmp/hdc-test/hypr-display-config.lua"

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
  writeFile = function(path, content)
    writtenFiles[path] = content
    return true
  end,
  fileExists = function(path) return writtenFiles[path] ~= nil or path == hyprlandConfigPath end,
  commandExists = function(name) return name == "hyprctl" or name == "Hyprland" end,
  runAsync = function(command, callback)
    ranCommands[#ranCommands + 1] = command
    if command:find("^Hyprland %-%-verify%-config") then
      callback({ exitCode = 0, stdout = "" })
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
  request_id = "req-1",
  monitors = {
    { name = "eDP-1", width = 1920, mode = "preferred", scale = 1, transform = 0,
      disabled = false, workspaces = { 1 } },
  },
})

local result = stateValues["hypr-display-config.apply_result"]
assert(type(result) == "table", "no result published")
assert(result.request_id == "req-1")
assert(result.status == "ok", "expected ok, got " .. tostring(result.status) .. " message=" .. tostring(result.message))

local managed = writtenFiles[managedFilePath]
assert(managed ~= nil, "managed file was not written to " .. managedFilePath)
assert(managed:find('hl.monitor({ output = "eDP-1"', 1, true) ~= nil, "managed file missing monitor line:\n" .. managed)
assert(managed:find('hl.workspace_rule({ workspace = "1", monitor = "eDP-1" })', 1, true) ~= nil)

local hyprlandConfig = writtenFiles[hyprlandConfigPath]
assert(hyprlandConfig ~= nil, "hyprland.lua was not rewritten with the require line")
assert(hyprlandConfig:find('require("hypr-display-config")', 1, true) ~= nil)

local sawEval = false
local sawVerify = false
local sawReload = false
for _, command in ipairs(ranCommands) do
  if command:find("hyprctl eval", 1, true) then sawEval = true end
  if command:find("Hyprland %-%-verify%-config") then sawVerify = true end
  if command == "hyprctl reload" then sawReload = true end
end
assert(sawEval, "expected at least one hyprctl eval call for live-apply")
assert(sawVerify, "expected a Hyprland --verify-config call")
assert(sawReload, "expected hyprctl reload after a successful commit")

-- Regression check for the Critical temp-path-extension bug: Hyprland 0.56.2
-- selects its config parser purely by file extension. A temp path built as
-- `<path> .. ".tmp"` on a `.lua` path produces `....lua.tmp`, which gets the
-- legacy conf-file parser instead of the Lua parser -- meaning every real
-- apply would fail validation (or worse, silently accept malformed Lua that
-- happens to look like conf syntax). Every `Hyprland --verify-config` target
-- must still end in `.lua`.
for _, command in ipairs(ranCommands) do
  if command:match("^Hyprland %-%-verify%-config") then
    assert(command:match("%.lua'?$") ~= nil,
      "verify-config path must end in .lua, got: " .. command)
  end
end

print("writer_apply_test: ok")
