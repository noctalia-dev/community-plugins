-- tests/writer_apply_malformed_request_test.lua
local stateValues = {}
local watchers = {}

noctalia = {
  getConfig = function(key)
    if key == "hyprland_config" then return "/tmp/hdc-test-malformed/hyprland.lua" end
    return nil
  end,
  expandPath = function(path) return path end,
  readFile = function(path) return nil end,
  writeFile = function(path, content) return true end,
  fileExists = function(path) return false end,
  commandExists = function(name) return false end,
  runAsync = function(command, callback) return true end,
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

-- Test case 1: monitors field is not a table
noctalia.state.set("hypr-display-config.apply_request", {
  request_id = "req-bad-monitors",
  monitors = "not-a-table"
})

local result = stateValues["hypr-display-config.apply_result"]
assert(type(result) == "table", "no result published for malformed monitors")
assert(result.request_id == "req-bad-monitors", "request_id mismatch for bad monitors")
assert(result.status == "error", "expected error status for malformed monitors, got " .. tostring(result.status))
assert(result.message == "malformed apply request", "expected correct error message")

-- Test case 2: request itself is not a table
noctalia.state.set("hypr-display-config.apply_request", "not-a-table-at-all")

result = stateValues["hypr-display-config.apply_result"]
assert(type(result) == "table", "no result published for non-table request")
assert(result.status == "error", "expected error status for non-table request")
assert(result.message == "malformed apply request", "expected correct error message for non-table request")
assert(result.request_id == "", "request_id should be empty string for non-table request")

-- Test case 3: request is nil
noctalia.state.set("hypr-display-config.apply_request", nil)

result = stateValues["hypr-display-config.apply_result"]
assert(type(result) == "table", "no result published for nil request")
assert(result.status == "error", "expected error status for nil request")
assert(result.request_id == "", "request_id should be empty string for nil request")

-- Test case 4: request is a table but monitors field is missing
noctalia.state.set("hypr-display-config.apply_request", {
  request_id = "req-no-monitors"
})

result = stateValues["hypr-display-config.apply_result"]
assert(type(result) == "table", "no result published for request without monitors")
assert(result.request_id == "req-no-monitors", "request_id should be preserved")
assert(result.status == "error", "expected error status for request without monitors")

print("writer_apply_malformed_request_test: ok")
