-- tests/service_poll_missing_hyprctl_test.lua
-- Covers Fix 7(b): when hyprctl isn't on PATH, poll() must notify the user
-- (instead of silently leaving the snapshot stuck at status = "loading"
-- forever with no diagnosis), but must not spam a notification on every
-- ~2s poll tick.
local notifyErrorCalls = {}

noctalia = {
  json = { decode = function() return {} end },
  commandExists = function(name) return false end,
  runAsync = function() error("runAsync should not be called when hyprctl is missing") end,
  getConfig = function() return nil end,
  state = { set = function() end, get = function() end, watch = function() end },
  setUpdateInterval = function() end,
  notifyError = function(title, message)
    notifyErrorCalls[#notifyErrorCalls + 1] = { title = title, message = message }
  end,
  tr = function(key) return key end,
}

assert(loadfile("service.luau"))()

assert(#notifyErrorCalls == 1, "expected exactly one notifyError call after initial poll(), got " .. #notifyErrorCalls)

-- Simulate further poll ticks (the plugin's `update()` runs on the
-- noctalia.setUpdateInterval(2000) timer) and confirm we don't spam.
update()
update()
update()

assert(#notifyErrorCalls == 1,
  "notifyError must only fire once for a persistently-missing hyprctl, got " .. #notifyErrorCalls .. " calls")

print("service_poll_missing_hyprctl_test: ok")
