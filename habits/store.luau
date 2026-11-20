--!nonstrict
-- Habits storage and calculation utilities.

local M = {}

function M.getDataPath()
  local dir = noctalia.pluginDataDir()
  noctalia.mkdirAll(dir)
  return dir .. "/habits.json"
end

function M.today()
  return noctalia.formatTime("%Y-%m-%d")
end

function M.load()
  local path = M.getDataPath()
  local raw = noctalia.readFile(path)
  if raw and raw ~= "" then
    local ok, data = pcall(function()
      return noctalia.json.decode(raw)
    end)
    if ok and type(data) == "table" and type(data.habits) == "table" then
      return data
    end
  end
  return { habits = {} }
end

function M.save(data)
  local path = M.getDataPath()
  local encoded = noctalia.json.encode(data)
  if encoded then
    noctalia.writeFile(path, encoded)
    noctalia.state.set("habits_updated", os.time())
    local s = M.summary(data, M.today())
    noctalia.state.set("habits_summary", s)
  end
end

-- Calculates current active streak for a habit
function M.calculateStreak(habit, todayStr)
  if not habit or type(habit.history) ~= "table" then
    return 0
  end

  local now = os.time()
  local doneToday = habit.history[todayStr] == true
  local streak = 0
  local offset = doneToday and 0 or 1

  -- Check backwards consecutive days
  for i = 0, 365 do
    local pastTime = now - (offset + i) * 86400 + 3600 -- add 1h buffer against daylight saving shifts
    local d = os.date("%Y-%m-%d", pastTime)
    if habit.history[d] == true then
      streak += 1
    else
      break
    end
  end

  return streak
end

function M.summary(data, todayStr)
  todayStr = todayStr or M.today()
  local habits = (data and type(data.habits) == "table") and data.habits or {}
  local total = #habits
  local completed = 0
  local maxStreak = 0

  for _, h in ipairs(habits) do
    if h.history and h.history[todayStr] == true then
      completed += 1
    end
    local streak = M.calculateStreak(h, todayStr)
    if streak > maxStreak then
      maxStreak = streak
    end
  end

  return {
    total = total,
    completed = completed,
    maxStreak = maxStreak,
    percent = total > 0 and math.floor((completed / total) * 100) or 0,
  }
end

return M

