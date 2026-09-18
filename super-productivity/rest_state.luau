--!nonstrict
-- pure normalization and local-calendar helpers for REST task state.

local M = {}

local MAX_UPCOMING = 50
local MAX_TITLE_CHARS = 1000
local MAX_NOTES_CHARS = 16000
local MAX_LABEL_CHARS = 200
local MAX_TAGS = 32

local function finite_number(value)
  local number = tonumber(value)
  if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
  return number
end

local function bounded_text(value, maximum)
  local text = value == nil and "" or tostring(value)
  local length = utf8.len(text)
  if length == nil then return "" end
  if length <= maximum then return text end
  local end_byte = utf8.offset(text, maximum)
  if end_byte == nil then return "" end
  return text:sub(1, end_byte - 1) .. "…"
end

local function days_in_month(year, month)
  if month == 2 then
    local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
    return leap and 29 or 28
  end
  return (month == 4 or month == 6 or month == 9 or month == 11) and 30 or 31
end

local function parse_day(day)
  if type(day) ~= "string" then return nil end
  local year, month, day_of_month = day:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  year, month, day_of_month = tonumber(year), tonumber(month), tonumber(day_of_month)
  if year == nil or month == nil or day_of_month == nil or month < 1 or month > 12
    or day_of_month < 1 or day_of_month > days_in_month(year, month) then return nil end
  return year, month, day_of_month
end

local function increment_day(year, month, day_of_month, amount)
  for _ = 1, math.max(0, math.floor(tonumber(amount) or 0)) do
    day_of_month += 1
    if day_of_month > days_in_month(year, month) then
      day_of_month = 1
      month += 1
      if month > 12 then
        month = 1
        year += 1
      end
    end
  end
  return year, month, day_of_month
end

-- os.time and os.date can use different timezone bases in the host, so search
-- by local calendar date to find the first instant even across DST changes.
local function local_midnight_ms(year, month, day_of_month)
  local seed = os.time({ year = year, month = month, day = day_of_month, hour = 0, min = 0, sec = 0 })
  if finite_number(seed) == nil then return nil end
  local target = year * 10000 + month * 100 + day_of_month
  local function date_key(timestamp)
    local value = os.date("*t", timestamp)
    return type(value) == "table" and value.year * 10000 + value.month * 100 + value.day or nil
  end
  local low, high = seed - 36 * 60 * 60, seed + 36 * 60 * 60
  local low_key, high_key = date_key(low), date_key(high)
  if low_key == nil or high_key == nil or low_key >= target or high_key < target then return nil end
  while high - low > 1 do
    local middle = math.floor((low + high) / 2)
    local key = date_key(middle)
    if key == nil then return nil end
    if key >= target then high = middle else low = middle end
  end
  return date_key(high) == target and high * 1000 or nil
end

function M.day_end_ms(day)
  local year, month, day_of_month = parse_day(day)
  if year == nil then return nil end
  year, month, day_of_month = increment_day(year, month, day_of_month, 1)
  local next_midnight = local_midnight_ms(year, month, day_of_month)
  return next_midnight ~= nil and next_midnight - 1 or nil
end

function M.date_after_days(now_ms, days)
  now_ms = finite_number(now_ms)
  if now_ms == nil or now_ms <= 0 then return nil end
  local current = os.date("*t", math.floor(now_ms / 1000))
  if type(current) ~= "table" then return nil end
  local year, month, day_of_month = increment_day(current.year, current.month, current.day, days)
  return string.format("%04d-%02d-%02d", year, month, day_of_month)
end

local function make_labels(values)
  local labels = {}
  if type(values) ~= "table" then return labels end
  for _, value in ipairs(values) do
    if type(value) == "table" and value.id ~= nil then
      labels[tostring(value.id)] = bounded_text(value.title, MAX_LABEL_CHARS)
    end
  end
  return labels
end

local function day_end_for(day, cache)
  if day == nil then return nil end
  local cached = cache[day]
  if cached ~= nil then return cached.value end
  local value = M.day_end_ms(day)
  cache[day] = { value = value }
  return value
end

local function normalize_task(raw, projects, tags, day_end_cache)
  raw = type(raw) == "table" and raw or {}
  local due_with_time = finite_number(raw.dueWithTime)
  local due_day = type(raw.dueDay) == "string" and raw.dueDay or nil
  local task_tags = {}
  if type(raw.tagIds) == "table" then
    for index, id in ipairs(raw.tagIds) do
      if index > MAX_TAGS then break end
      local label = tags[tostring(id)]
      if label ~= nil and label ~= "" then table.insert(task_tags, label) end
    end
  end
  return {
    id = raw.id == nil and "" or tostring(raw.id),
    title = bounded_text(raw.title, MAX_TITLE_CHARS),
    notes = bounded_text(raw.notes, MAX_NOTES_CHARS),
    isDone = raw.isDone == true,
    project = raw.projectId ~= nil and (projects[tostring(raw.projectId)] or "") or "",
    tags = task_tags,
    dueDay = due_day,
    dueAt = due_with_time or day_end_for(due_day, day_end_cache),
    dueKind = due_with_time ~= nil and "time" or due_day ~= nil and "day" or nil,
    timeEstimate = finite_number(raw.timeEstimate) or 0,
    timeSpent = finite_number(raw.timeSpent) or 0,
    created = finite_number(raw.created) or 0,
  }
end

local function compare_due(left, right)
  if left.dueAt ~= right.dueAt then return left.dueAt < right.dueAt end
  if left.dueKind ~= right.dueKind then return left.dueKind == "time" end
  if left.created ~= right.created then return left.created < right.created end
  return left.id < right.id
end

function M.normalize(tasks, projects, tags, status, now_ms)
  tasks = type(tasks) == "table" and tasks or {}
  status = type(status) == "table" and status or {}
  local project_labels = make_labels(projects)
  local tag_labels = make_labels(tags)
  local day_end_cache = {}
  local by_id = {}
  local due = {}
  local active = 0
  local overdue = 0
  now_ms = finite_number(now_ms) or 0

  for _, raw in ipairs(tasks) do
    local task = normalize_task(raw, project_labels, tag_labels, day_end_cache)
    if task.id ~= "" then
      by_id[task.id] = task
      if not task.isDone then
        active += 1
        if task.dueAt ~= nil then
          table.insert(due, task)
          if task.dueAt < now_ms then overdue += 1 end
        end
      end
    end
  end

  table.sort(due, compare_due)
  local upcoming = {}
  for index, task in ipairs(due) do
    if index > MAX_UPCOMING then break end
    table.insert(upcoming, task)
  end

  local current_task = nil
  local current_id = type(status.currentTaskId) == "string" and status.currentTaskId or ""
  if current_id ~= "" then
    current_task = by_id[current_id]
    if current_task == nil and type(status.currentTask) == "table"
      and tostring(status.currentTask.id or "") == current_id then
      current_task = normalize_task(status.currentTask, project_labels, tag_labels, day_end_cache)
    end
  end

  return {
    currentTask = current_task,
    upcoming = upcoming,
    counts = { active = active, due = #due, overdue = overdue },
  }
end

M.compare_due = compare_due
M.constants = { MAX_UPCOMING = MAX_UPCOMING }

return M
