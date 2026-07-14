-- Behavioral tests for bounded trend persistence.

local state = {}
local watchers = {}
local writes = 0
local renames = 0
local writesSucceed = true

noctalia = {
  getConfig = function(key)
    if key == "history_interval_minutes" then return 15 end
    if key == "history_retention_days" then return 1 end
    return nil
  end,
  pluginDataDir = function() return "/mock/plugin-data" end,
  readFile = function(_path) return nil end,
  writeFile = function(_path, _contents) writes = writes + 1 return writesSucceed end,
  renameFile = function(_from, _to) renames = renames + 1 return true end,
  log = function(_message) end,
  state = {
    get = function(key) return state[key] end,
    set = function(key, value) state[key] = value end,
    watch = function(key, callback) watchers[key] = callback end,
  },
  json = {
    decode = function(_raw) return nil end,
    encode = function(_value, _pretty) return "{}" end,
  },
}

local handle = assert(io.open("history.luau", "rb"))
local source = handle:read("*a")
handle:close()
assert(load(source, "@history.luau"))()

local publish = assert(watchers.snapshot, "history service did not watch snapshots")
local function snapshot(epoch, hotspot, life)
  return {
    generated_at_epoch = epoch,
    disks = { {
      id = "SERIAL1", model = "Fixture SSD", display_name = "Fixture SSD", kind = "ssd",
      temperature_c = hotspot - 5, hotspot_temperature_c = hotspot,
      remaining_life_percent = life, storage_usage_percent = 25, data_written_bytes = 1000,
    } },
  }
end

publish(snapshot(100000, 60, 99))
local samples = state.drive_history.drives.SERIAL1.samples
assert(#samples == 1 and samples[1].hotspot_temperature_c == 60, "first history sample was not recorded")
assert(writes == 1 and renames == 1, "history was not committed atomically")

publish(snapshot(100100, 61, 99))
assert(#state.drive_history.drives.SERIAL1.samples == 1, "history ignored its sample interval")
assert(writes == 1, "history rewrote the file without a new sample")

publish(snapshot(100901, 62, 98))
samples = state.drive_history.drives.SERIAL1.samples
assert(#samples == 2 and samples[2].remaining_life_percent == 98, "scheduled history sample was missed")
assert(writes == 2 and renames == 2, "second history sample was not committed")

writesSucceed = false
publish(snapshot(101802, 63, 97))
assert(writes == 3 and renames == 2, "failed history write was not exercised")
writesSucceed = true
publish(snapshot(101900, 63, 97))
assert(writes == 4 and renames == 3, "dirty history was not retried after a transient write failure")

print("history behavior tests passed")
