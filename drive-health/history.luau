--!nonstrict

-- Bounded, low-write-rate drive history. Alert evaluation remains in
-- service.luau; this service only persists trend samples and publishes them.

local HISTORY_FILE = "history.json"
local history = { schema = 1, drives = {} }
local historyDirty = false

local function number(value, fallback)
  local parsed = tonumber(value)
  return parsed ~= nil and parsed or fallback
end

local function historyPath()
  local directory = noctalia.pluginDataDir()
  return directory ~= nil and directory .. "/" .. HISTORY_FILE or nil
end

local function loadHistory()
  local path = historyPath()
  local encoded = path ~= nil and noctalia.readFile(path) or nil
  local decoded = encoded ~= nil and noctalia.json.decode(encoded) or nil
  if type(decoded) == "table" and tonumber(decoded.schema) == 1 then
    history = decoded
    history.drives = type(decoded.drives) == "table" and decoded.drives or {}
  end
end

local function saveHistory()
  local path = historyPath()
  if path == nil then
    return false
  end
  local encoded, encodeError = noctalia.json.encode(history, true)
  if encoded == nil then
    noctalia.log("Unable to encode SMART history: " .. tostring(encodeError))
    return false
  end
  local temporary = path .. ".tmp"
  local written, writeError = noctalia.writeFile(temporary, encoded)
  if not written then
    noctalia.log("Unable to write SMART history: " .. tostring(writeError))
    return false
  end
  local renamed, renameError = noctalia.renameFile(temporary, path)
  if not renamed then
    noctalia.log("Unable to commit SMART history: " .. tostring(renameError))
    return false
  end
  return true
end

local function publishHistory()
  noctalia.state.set("drive_history", history)
end

local function recordSnapshot(snapshot)
  if type(snapshot) ~= "table" or type(snapshot.disks) ~= "table" or snapshot.collector_error ~= nil then
    return
  end
  local epoch = math.floor(number(snapshot.generated_at_epoch, os.time()))
  local interval = math.max(15, math.min(1440,
    number(noctalia.getConfig("history_interval_minutes"), 60))) * 60
  local retention = math.max(1, math.min(365,
    number(noctalia.getConfig("history_retention_days"), 30))) * 86400
  local cutoff = epoch - retention
  local changed = false

  for _, drive in ipairs(snapshot.disks) do
    local id = tostring(drive.id or drive.serial or drive.device or "")
    if id ~= "" then
      local entry = history.drives[id]
      if type(entry) ~= "table" then
        entry = { name = drive.display_name or drive.model or drive.device, samples = {} }
        history.drives[id] = entry
      end
      entry.name = drive.display_name or drive.model or drive.device
      entry.kind = drive.kind
      entry.samples = type(entry.samples) == "table" and entry.samples or {}

      local retained = {}
      for _, sample in ipairs(entry.samples) do
        if type(sample) == "table" and number(sample.epoch, 0) >= cutoff then
          table.insert(retained, sample)
        else
          changed = true
        end
      end
      entry.samples = retained
      local latest = retained[#retained]
      if latest == nil or epoch - number(latest.epoch, 0) >= interval then
        table.insert(retained, {
          epoch = epoch,
          temperature_c = tonumber(drive.temperature_c),
          hotspot_temperature_c = tonumber(drive.hotspot_temperature_c),
          remaining_life_percent = tonumber(drive.remaining_life_percent),
          storage_usage_percent = tonumber(drive.storage_usage_percent),
          data_written_bytes = tonumber(drive.data_written_bytes),
        })
        changed = true
      end
    end
  end

  for id, entry in pairs(history.drives) do
    local samples = type(entry) == "table" and entry.samples or nil
    if type(samples) ~= "table" or (#samples > 0 and number(samples[#samples].epoch, 0) < cutoff) then
      history.drives[id] = nil
      changed = true
    end
  end

  history.updated_at_epoch = epoch
  if changed then
    historyDirty = true
  end
  if historyDirty and saveHistory() then
    historyDirty = false
  end
  publishHistory()
end

loadHistory()
publishHistory()

noctalia.state.watch("snapshot", function(snapshot)
  recordSnapshot(snapshot)
end)

local initial = noctalia.state.get("snapshot")
if initial ~= nil then
  recordSnapshot(initial)
end

function onConfigChanged()
  local snapshot = noctalia.state.get("snapshot")
  if snapshot ~= nil then
    recordSnapshot(snapshot)
  end
end
