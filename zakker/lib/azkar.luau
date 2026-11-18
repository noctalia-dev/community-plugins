-- Online azkar from nawafalqari/azkar-api (azkar.json), with time-based
-- category: morning (4:00–18:00) vs evening (18:00–04:00).
-- Cached in memory, refreshed every few hours; bundled reminders stay
-- as the offline fallback.

local M = {}

M.URL = "https://raw.githubusercontent.com/nawafalqari/azkar-api/56df51279ab6eb86dc2f6202c7de26c8948331c1/azkar.json"
M.MORNING_KEY = "أذكار الصباح"
M.EVENING_KEY = "أذكار المساء"

local cache = nil
local cursors = {}

--- Flatten one level: most items are dicts, but a category may hold
--- grouped entries (arrays of items), e.g. morning[1] in azkar.json.
---@param raw table
---@return table flat array of item dicts
local function flatList(raw)
  local out = {}
  if type(raw) ~= "table" then
    return out
  end
  for _, x in ipairs(raw) do
    if type(x) == "table" and x.content ~= nil then
      table.insert(out, x)
    elseif type(x) == "table" then
      for _, y in ipairs(x) do
        if type(y) == "table" and y.content ~= nil then
          table.insert(out, y)
        end
      end
    end
  end
  return out
end

--- Fetch (or refresh) the remote pool. Calls cb(true) on success.
---@param cb fun(ok:boolean)|nil
function M.refresh(cb)
  local accepted = noctalia.http({ url = M.URL }, function(res)
    if not res.ok or res.status ~= 200 then
      noctalia.log("zakker azkar fetch failed: ok=" .. tostring(res.ok) .. " status=" .. tostring(res.status))
      if cb then
        cb(false)
      end
      return
    end
    local data, err = noctalia.json.decode(res.body)
    if type(data) ~= "table" then
      noctalia.log("zakker azkar decode failed: " .. tostring(err))
      if cb then
        cb(false)
      end
      return
    end
    local morn = flatList(data[M.MORNING_KEY])
    local even = flatList(data[M.EVENING_KEY])
    if #morn == 0 or #even == 0 then
      noctalia.log("zakker azkar shape unexpected (missing morning/evening lists)")
      if cb then
        cb(false)
      end
      return
    end
    cache = {}
    cache[M.MORNING_KEY] = morn
    cache[M.EVENING_KEY] = even
    noctalia.log("zakker azkar loaded: morning=" .. #morn .. " evening=" .. #even)
    if cb then
      cb(true)
    end
  end)
  if not accepted then
    noctalia.log("zakker azkar fetch not accepted")
    if cb then
      cb(false)
    end
  end
end

---@return boolean
function M.hasItems()
  return cache ~= nil
end

---@return integer|nil local hour 0..23
function M.hour()
  local ok, h = pcall(noctalia.formatTime, "{:%H}")
  if not ok then
    return nil
  end
  return tonumber(h)
end

--- Time-based category: 04:00–18:00 morning, else evening.
---@return string key, string label
function M.category()
  local h = M.hour()
  if h ~= nil and h >= 4 and h < 18 then
    return M.MORNING_KEY, "أذكار الصباح"
  elseif h ~= nil then
    return M.EVENING_KEY, "أذكار المساء"
  end
  noctalia.log("zakker azkar hour unknown, defaulting to morning")
  return M.MORNING_KEY, "أذكار الصباح"
end

--- Take n items from a category with rotation (no repeat before cycle).
---@param key string
---@param n integer
---@return table array of items
function M.take(key, n)
  if cache == nil or type(cache[key]) ~= "table" then
    return {}
  end
  local list = cache[key]
  if #list == 0 then
    return {}
  end
  if type(n) ~= "number" or n < 1 then
    n = 3
  end
  local out = {}
  local cur = cursors[key] or 0
  for _ = 1, math.min(n, #list) do
    cur = (cur % #list) + 1
    table.insert(out, list[cur])
  end
  cursors[key] = cur
  return out
end

---@param items table
---@return string numbered body
function M.format(items)
  local lines = {}
  for i, item in ipairs(items) do
    local line = tostring(i) .. ". " .. tostring(item.content or "")
    local times = tonumber(item.count)
    if times ~= nil and times > 1 then
      line = line .. "  (" .. tostring(times) .. " مرات)"
    end
    if item.description ~= nil and item.description ~= "" then
      line = line .. "\n   ↳ " .. tostring(item.description)
    end
    table.insert(lines, line)
  end
  return table.concat(lines, "\n\n")
end

return M
