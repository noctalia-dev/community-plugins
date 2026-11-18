--!nonstrict
-- Headless service: remembers the MANUAL geometry of the plugin windows.
-- It only writes `brainGeometry` to store.json; the toggle is written by the panel.
--
-- The hyprctl query follows the same convention as the rest of the plugin
-- (`lib/windows.luau`): `noctalia.runAsync` passes the callback a single
-- `result` with `{ exitCode, stdout, stderr }`.
local storeLib = require("./lib/store.luau")
local outputLib = require("./lib/output.luau")
local brain = require("./lib/brain.luau")

local polling = false
local pending = {}

-- The two settings the service needs, read by key as the panel does
-- (`noctalia.getConfig` has no form without a key): margin and output are the
-- same source of truth used by panel.luau, so an offset saved by the service
-- is reconstructed the same way as one saved by the panel.
local function settings()
  return {
    margin = tonumber(noctalia.getConfig("margin")) or 0,
    output = tostring(noctalia.getConfig("output") or ""),
  }
end

local function imposedMap()
  local state = noctalia.state
  if state == nil then return {} end
  local ok, value = pcall(state.get, "imposed")
  if ok and type(value) == "table" then return value end
  return {}
end

function update()
  if polling then return end
  local stored = storeLib.loadBrain()
  if stored.brain ~= true then return end   -- brain OFF: zero work, zero hyprctl
  polling = true
  local started = noctalia.runAsync({ "hyprctl", "clients", "-j" }, function(result)
    polling = false
    if result.exitCode ~= 0 or type(result.stdout) ~= "string" or result.stdout == "" then
      return
    end
    local decoded, clients = pcall(noctalia.json.decode, result.stdout)
    if not decoded or type(clients) ~= "table" then return end
    local cfg = settings()
    local box = outputLib.outputBox(cfg)
    local capture = brain.capture(clients, box, cfg.margin, stored.brainGeometry, imposedMap(), pending)
    pending = capture.pending
    if capture.changed then
      storeLib.saveBrainGeometry(capture.memory)
    end
  end)
  if not started then
    polling = false
  end
end

noctalia.setUpdateInterval(1000)