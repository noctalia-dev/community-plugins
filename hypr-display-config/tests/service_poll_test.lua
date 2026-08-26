-- tests/service_poll_test.lua
local stateValues = {}
local monitorsJson = "monitors-json"
local rulesJson = "rules-json"

noctalia = {
  json = {
    decode = function(text)
      if text == monitorsJson then
        return {
          { name = "eDP-1", width = 1920, height = 1080, x = 0, y = 0,
            scale = 1, transform = 0, refreshRate = 60, disabled = false,
            availableModes = { "1920x1080@60.00Hz" } },
        }
      elseif text == rulesJson then
        return { { workspaceString = "1", monitor = "eDP-1", enabled = true } }
      end
      error("unexpected json.decode input: " .. tostring(text))
    end,
  },
  commandExists = function(name) return name == "hyprctl" end,
  runAsync = function(command, callback)
    if command == "hyprctl monitors all -j" then
      callback({ exitCode = 0, stdout = monitorsJson })
    elseif command == "hyprctl workspacerules -j" then
      callback({ exitCode = 0, stdout = rulesJson })
    else
      error("unexpected command: " .. tostring(command))
    end
    return true
  end,
  getConfig = function(key)
    if key == "workspace_count" then return 3 end
    return nil
  end,
  state = {
    set = function(key, value) stateValues[key] = value end,
    get = function(key) return stateValues[key] end,
    watch = function() end,
  },
  setUpdateInterval = function() end,
  notifyError = function() end,
  tr = function(key) return key end,
}

assert(loadfile("service.luau"))()

local snapshot = stateValues["hypr-display-config.snapshot"]
assert(type(snapshot) == "table", "service did not publish a snapshot")
assert(snapshot.status == "ready", "snapshot status should be ready")
assert(#snapshot.monitors == 1, "expected 1 monitor")
assert(snapshot.monitors[1].name == "eDP-1")
assert(#snapshot.monitors[1].workspaces == 1 and snapshot.monitors[1].workspaces[1] == 1)
assert(#snapshot.unboundWorkspaces == 2, "workspaces 2 and 3 should be unbound")

print("service_poll_test: ok")
