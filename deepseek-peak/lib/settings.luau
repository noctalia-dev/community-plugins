--!nonstrict
-- Settings overlay for the DeepSeek Peak Hours v5 port.
--
-- Noctalia v5 gives plugins no API to write their declared settings, so
-- runtime changes (the panel's provider switch) are persisted to a JSON file
-- in the plugin data dir and overlaid on top of the declared values. All
-- entries read through this module so an override applies everywhere.
--
-- Change propagation: writers call `M.setOverride(key, value)`, which saves
-- the file and publishes `deepseek-peak.settings` on the in-memory state
-- channel; other entries watch that key and re-read.

local M = {}

local FILE_NAME = "overrides.json"
local CHANNEL = "deepseek-peak.settings"

local cache = nil

local function overridesPath()
  local dir = noctalia.pluginDataDir()
  if not dir then
    return nil
  end
  return dir .. "/" .. FILE_NAME
end

local function readOverrides()
  local path = overridesPath()
  if not path then
    return {}
  end
  local raw = noctalia.readFile(path)
  if not raw then
    return {}
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    return {}
  end
  return decoded
end

function M.all()
  if cache == nil then
    cache = readOverrides()
  end
  return cache
end

function M.get(key, fallback)
  local value = M.all()[key]
  if value == nil then
    value = noctalia.getConfig(key)
  end
  if value == nil then
    return fallback
  end
  return value
end

function M.provider()
  if M.get("provider", "deepseek") == "ollama" then
    return "ollama"
  end
  return "deepseek"
end

function M.setOverride(key, value)
  local overrides = {}
  for k, v in pairs(M.all()) do
    overrides[k] = v
  end
  overrides[key] = value
  cache = overrides
  local path = overridesPath()
  if path then
    noctalia.writeFile(path, noctalia.json.encode(overrides))
  end
  noctalia.state.set(CHANNEL, noctalia.nowMs())
  return true
end

function M.toggleProvider()
  local nextProvider = M.provider() == "ollama" and "deepseek" or "ollama"
  M.setOverride("provider", nextProvider)
  return nextProvider
end

-- Re-read the file when another entry saved overrides.
function M.watch(onChange)
  noctalia.state.watch(CHANNEL, function()
    cache = readOverrides()
    if onChange then
      onChange()
    end
  end)
end

return M
