-- Last-played tracking shared by both panels and the /g provider.
--
-- Each entry runs in its own VM, so this module's cache is per entry:
-- the file under pluginDataDir() is the durable copy (survives restarts),
-- the state key is how the entries share fresh launches live.
local FILE = "recent.json"
local STATE_KEY = "recent"
local MAX_ENTRIES = 30

local M = {}

local cache = nil

local function dataFile()
  local ok, dir = pcall(noctalia.pluginDataDir)
  if not ok or type(dir) ~= "string" or dir == "" then return nil end
  return dir .. "/" .. FILE
end

local function readRecent()
  local path = dataFile()
  if path == nil then return {} end
  local content = noctalia.readFile(path)
  if type(content) ~= "string" or content == "" then return {} end
  local ok, decoded = pcall(noctalia.json.decode, content)
  if not ok or type(decoded) ~= "table" then return {} end
  local map = {}
  for id, ts in pairs(decoded) do
    if type(id) == "string" and type(ts) == "number" then map[id] = ts end
  end
  return map
end

local function writeRecent(map)
  local path = dataFile()
  if path == nil then return false end
  local ok, encoded = pcall(noctalia.json.encode, map)
  if not ok or encoded == nil then return false end
  return noctalia.writeFile(path, encoded)
end

-- id -> timestamp of the last launch. Shared state wins when it holds a
-- table (a sibling entry just recorded a launch); the file is read once
-- per VM, after a reload.
function M.get()
  local ok, shared = pcall(noctalia.state.get, STATE_KEY)
  if ok and type(shared) == "table" then
    cache = shared
    return cache
  end
  if cache == nil then cache = readRecent() end
  pcall(noctalia.state.set, STATE_KEY, cache)
  return cache
end

-- Records a launch now. Publishes a fresh table so whoever holds the old
-- copy keeps a consistent snapshot.
function M.record(id)
  if type(id) ~= "string" or id == "" then return end
  local current = M.get()
  local updated = {}
  for k, v in pairs(current) do updated[k] = v end
  updated[id] = os.time()
  local count = 0
  for _ in pairs(updated) do count = count + 1 end
  if count > MAX_ENTRIES then
    local keys = {}
    for k in pairs(updated) do table.insert(keys, k) end
    table.sort(keys, function(a, b) return (updated[a] or 0) < (updated[b] or 0) end)
    for i = 1, count - MAX_ENTRIES do updated[keys[i]] = nil end
  end
  cache = updated
  pcall(noctalia.state.set, STATE_KEY, updated)
  writeRecent(updated)
end

-- The id with the newest launch timestamp, or nil when nothing launched yet.
function M.lastId()
  local recent = M.get()
  local best, bestTs = nil, 0
  for id, ts in pairs(recent) do
    if ts > bestTs then
      best, bestTs = id, ts
    end
  end
  return best
end

-- In place: played games first (newest first), everything else keeps its
-- relative order. Unplayed ids sort as timestamp 0.
function M.sortByRecent(list)
  local recent = M.get()
  local decorated = {}
  for i, g in ipairs(list) do
    decorated[i] = { game = g, pos = i, ts = recent[g.id] or 0 }
  end
  table.sort(decorated, function(a, b)
    if a.ts ~= b.ts then return a.ts > b.ts end
    return a.pos < b.pos
  end)
  for i, d in ipairs(decorated) do list[i] = d.game end
  return list
end

return M
