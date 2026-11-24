--!nonstrict
-- Ping Monitor storage: device list and global mute (config.json), per-device history (history.json).
local M = {}

local INTERVALS = { 5, 10, 15, 30, 60, 120, 300 }
M.INTERVALS = INTERVALS

local function path(name)
  local dir = noctalia.pluginDataDir()
  return dir and (dir .. "/" .. name) or nil
end

local function readJson(name)
  local p = path(name)
  if not p then return nil end
  local text = noctalia.readFile(p)
  if not text then return nil end
  local ok, data = pcall(noctalia.json.decode, text)
  if ok and type(data) == "table" then return data end
  return nil
end

local function writeJson(name, data)
  local p = path(name)
  if p then noctalia.writeFile(p, noctalia.json.encode(data)) end
end

function M.loadConfig()
  local cfg = readJson("config.json")
  if cfg == nil or type(cfg.devices) ~= "table" then
    -- first run: start with an empty device list
    cfg = { muted = false, devices = {} }
    writeJson("config.json", cfg)
  end
  return cfg
end

function M.saveConfig(cfg)
  writeJson("config.json", cfg)
end

-- history: { [ip] = { [yyyy-mm-dd] = true } }; a legacy flat map (date -> true) is moved to the first device
function M.loadHistory(cfg)
  local h = readJson("history.json") or {}
  for key, value in h do
    if value == true then
      local first = cfg.devices[1]
      local ip = first and first.ip or "unknown"
      h[ip] = h[ip] or {}
      h[ip][key] = true
      h[key] = nil
    end
  end
  return h
end

function M.saveHistory(h)
  writeJson("history.json", h)
end

function M.intervalIndex(seconds)
  for i, v in INTERVALS do
    if v == seconds then return i end
  end
  return 3
end

return M
