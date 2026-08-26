-- tests/writer_apply_live_failure_test.lua
-- Covers Fix 4: a failing `hyprctl eval` live-apply call must not be silently
-- swallowed. The overall commit can still succeed (the managed file write and
-- Hyprland reload are independent of the live hyprctl eval calls), but the
-- published result must surface that at least one live-apply call failed.
local stateValues = {}
local watchers = {}
local writtenFiles = {}
local ranCommands = {}
local hyprlandConfigPath = "/tmp/hdc-test-live-fail/hyprland.lua"
local managedFilePath = "/tmp/hdc-test-live-fail/hypr-display-config.lua"

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
    if command:find("hyprctl eval", 1, true) and command:find("hl.monitor(", 1, true) then
      -- Simulate Hyprland rejecting this particular live-apply call.
      callback({ exitCode = 1, stdout = "", stderr = "invalid mode" })
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
  request_id = "req-live-fail",
  monitors = {
    { name = "eDP-1", width = 1920, mode = "preferred", scale = 1, transform = 0,
      disabled = false, workspaces = { 1 } },
  },
})

local result = stateValues["hypr-display-config.apply_result"]
assert(type(result) == "table", "no result published (liveApply must still call onComplete/continue the pipeline)")
assert(result.request_id == "req-live-fail")

-- The file-commit path is independent of the live hyprctl eval calls, so the
-- overall request should still succeed...
assert(result.status == "ok", "expected ok status even when a live-apply call fails, got "
  .. tostring(result.status) .. " message=" .. tostring(result.message))

-- ...but the failure must not be silently swallowed: it should show up in the message.
assert(type(result.message) == "string" and result.message:find("1", 1, true) ~= nil,
  "expected result.message to mention the live-apply failure count, got " .. tostring(result.message))

-- The managed file should still have been written/committed.
assert(writtenFiles[managedFilePath] ~= nil, "managed file should still be committed despite live-apply failure")

print("writer_apply_live_failure_test: ok")
