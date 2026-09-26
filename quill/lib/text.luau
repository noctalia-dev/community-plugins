--!nonstrict
local M = {}

local STOPWORDS = {
  ["the"] = true, ["a"] = true, ["an"] = true, ["and"] = true, ["or"] = true,
  ["of"] = true, ["to"] = true, ["in"] = true, ["on"] = true, ["for"] = true,
  ["is"] = true, ["are"] = true, ["was"] = true, ["were"] = true,
  ["with"] = true, ["that"] = true, ["this"] = true, ["it"] = true, ["its"] = true,
  ["as"] = true, ["at"] = true, ["by"] = true, ["be"] = true, ["from"] = true,
  ["i"] = true, ["my"] = true, ["me"] = true, ["mine"] = true,
  ["you"] = true, ["your"] = true, ["we"] = true, ["our"] = true,
  ["do"] = true, ["does"] = true, ["did"] = true,
  ["how"] = true, ["what"] = true, ["when"] = true, ["where"] = true,
  ["which"] = true, ["who"] = true, ["why"] = true,
  ["can"] = true, ["could"] = true, ["should"] = true, ["would"] = true,
  ["will"] = true, ["about"] = true, ["into"] = true, ["over"] = true,
  ["just"] = true, ["not"] = true, ["no"] = true, ["yes"] = true,
  ["have"] = true, ["has"] = true, ["had"] = true, ["there"] = true,
  ["then"] = true, ["than"] = true, ["so"] = true, ["if"] = true,
  ["but"] = true, ["all"] = true, ["any"] = true, ["some"] = true,
  ["need"] = true, ["want"] = true, ["get"] = true, ["got"] = true,
  ["make"] = true, ["made"] = true,
}

function M.trim(s)
  if s == nil then
    return ""
  end
  s = tostring(s)
  s = string.gsub(s, "^%s+", "")
  s = string.gsub(s, "%s+$", "")
  return s
end

function M.payloadField(payload, field)
  if type(payload) == "table" then
    local value = payload[field]
    if value ~= nil then
      return tostring(value)
    end
    return ""
  end
  if type(payload) == "string" then
    local trimmed = M.trim(payload)
    if string.sub(trimmed, 1, 1) == "{" then
      local data = M.extractJson(trimmed)
      if type(data) == "table" and data[field] ~= nil then
        return tostring(data[field])
      end
      return ""
    end
    return trimmed
  end
  return ""
end

function M.splitLines(s)
  local lines = {}
  if s == nil or s == "" then
    return lines
  end
  local start = 1
  while true do
    local nl = string.find(s, "\n", start, true)
    if nl == nil then
      table.insert(lines, string.sub(s, start))
      break
    end
    table.insert(lines, string.sub(s, start, nl - 1))
    start = nl + 1
  end
  return lines
end

function M.joinLines(lines)
  return table.concat(lines, "\n")
end

function M.slugify(s)
  local out = string.lower(s or "")
  out = string.gsub(out, "[^%w]+", "-")
  out = string.gsub(out, "^-+", "")
  out = string.gsub(out, "-+$", "")
  if #out > 60 then
    out = string.sub(out, 1, 60)
    out = string.gsub(out, "-+$", "")
  end
  return out
end

function M.yamlString(s)
  s = tostring(s or "")
  if s == "" then
    return '""'
  end
  if string.find(s, "^[%w%s%-_%.%(%)%,:/']+$") ~= nil then
    return s
  end
  return '"' .. string.gsub(s, '"', '\\"') .. '"'
end

function M.stripMarkdown(s)
  local out = tostring(s or "")
  out = string.gsub(out, "!%[([^%]]*)%]%([^%)]*%)", "%1")
  out = string.gsub(out, "%[%[([^%]]*)%]%]", "%1")
  out = string.gsub(out, "%[([^%]]*)%]%([^%)]*%)", "%1")
  out = string.gsub(out, "`([^`]*)`", "%1")
  out = string.gsub(out, "%*%*([^%*]*)%*%*", "%1")
  out = string.gsub(out, "__([^_]*)__", "%1")
  out = string.gsub(out, "^%s*#+%s*", "")
  out = string.gsub(out, "^%s*[%-%*%+]%s+", "")
  out = string.gsub(out, "%s+", " ")
  return M.trim(out)
end

function M.truncate(s, n)
  s = tostring(s or "")
  if #s <= n then
    return s
  end
  return string.sub(s, 1, math.max(1, n - 1)) .. "…"
end

function M.firstLine(s)
  s = tostring(s or "")
  local nl = string.find(s, "\n", 1, true)
  if nl == nil then
    return M.trim(s)
  end
  return M.trim(string.sub(s, 1, nl - 1))
end

function M.collapseSpaces(s)
  return M.trim(string.gsub(tostring(s or ""), "%s+", " "))
end

function M.extractJson(s)
  if type(s) ~= "string" then
    return nil
  end
  local fenced = string.match(s, "```[Jj][Ss][Oo][Nn]%s*(.-)%s*```")
  if fenced ~= nil then
    s = fenced
  end
  local body = string.match(s, "({.*})")
  if body == nil then
    local arr = string.match(s, "%[(.*)%]")
    if arr ~= nil then
      body = "[" .. arr .. "]"
    end
  end
  if body == nil then
    return nil
  end
  local data = noctalia.json.decode(body)
  if type(data) == "table" then
    return data
  end
  return nil
end

function M.keywords(s)
  local out, seen = {}, {}
  for word in string.gmatch(string.lower(tostring(s or "")), "[%w_]+") do
    if #word >= 3 and not STOPWORDS[word] and not seen[word] then
      seen[word] = true
      table.insert(out, word)
    end
  end
  return out
end

function M.todayIso()
  return os.date("%Y-%m-%d")
end

function M.isoEpoch(iso, hour)
  if iso == nil or iso == "" then
    return nil
  end
  local y, mo, d = string.match(iso, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y == nil then
    return nil
  end
  return os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = hour or 12,
  })
end

function M.daysUntil(iso)
  local target = M.isoEpoch(iso)
  if target == nil then
    return nil
  end
  local now = os.time()
  local midnight = os.time({
    year = tonumber(os.date("%Y", now)),
    month = tonumber(os.date("%m", now)),
    day = tonumber(os.date("%d", now)),
    hour = 12,
  })
  return math.floor((target - midnight) / 86400)
end

function M.safeTime(value)
  if type(value) ~= "string" then
    return nil
  end
  local hour, minute = string.match(value, "^(%d%d?):(%d%d)$")
  hour = tonumber(hour)
  minute = tonumber(minute)
  if hour == nil or minute == nil or hour < 0 or hour > 23 or minute < 0 or minute > 59 then
    return nil
  end
  return string.format("%02d:%02d", hour, minute)
end

function M.nowTime()
  return os.date("%H:%M")
end

function M.isOverdue(due, time)
  return M.overdueOn(due, time, M.todayIso(), M.nowTime())
end

function M.overdueOn(due, time, today, nowTime)
  if due == nil or due == "" then
    return false
  end
  if due < today then
    return true
  end
  if due > today or time == nil or time == "" then
    return false
  end
  local cleanTime = M.safeTime(time)
  return cleanTime ~= nil and cleanTime < nowTime
end

function M.fmtDue(iso, time)
  local diff = M.daysUntil(iso)
  if diff == nil then
    return nil
  end
  local label
  if diff == 0 then
    label = "today"
  elseif diff == 1 then
    label = "tomorrow"
  elseif diff == -1 then
    label = "yesterday"
  elseif diff < 0 then
    label = tostring(-diff) .. "d overdue"
  elseif diff <= 7 then
    label = "in " .. tostring(diff) .. "d"
  else
    label = os.date("%b %d", M.isoEpoch(iso))
  end
  local cleanTime = M.safeTime(time)
  if cleanTime ~= nil then
    label = label .. " " .. cleanTime
  end
  return label
end

function M.relTime(seconds)
  if seconds == nil then
    return ""
  end
  if seconds < 45 then
    return "just now"
  end
  if seconds < 3600 then
    return tostring(math.floor(seconds / 60)) .. "m ago"
  end
  if seconds < 86400 then
    return tostring(math.floor(seconds / 3600)) .. "h ago"
  end
  if seconds < 86400 * 30 then
    return tostring(math.floor(seconds / 86400)) .. "d ago"
  end
  return os.date("%b %d", os.time() - seconds)
end

function M.addDays(iso, n)
  local epoch = M.isoEpoch(iso)
  if epoch == nil then
    return nil
  end
  local t = os.date("*t", epoch + n * 86400)
  return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
end

function M.addMonths(iso, n)
  local y, mo, d = string.match(tostring(iso or ""), "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y == nil then
    return nil
  end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  mo = mo + n
  while mo > 12 do
    mo = mo - 12
    y = y + 1
  end
  local dim = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) then
    dim[2] = 29
  end
  if d > dim[mo] then
    d = dim[mo]
  end
  return string.format("%04d-%02d-%02d", y, mo, d)
end

function M.nextRecurrence(iso, rule)
  local base = iso
  if base == nil or base == "" then
    base = M.todayIso()
  end
  if rule == "daily" then
    return M.addDays(base, 1)
  end
  if rule == "weekly" then
    return M.addDays(base, 7)
  end
  if rule == "monthly" then
    return M.addMonths(base, 1)
  end
  return nil
end

-- Rolls a past recurring due date forward to the next occurrence that is not
-- before `from`. Times are stepped as whole days, not by the recurrence unit,
-- so a monthly todo does not drift a day each month.
-- Unix epoch milliseconds for a due date plus optional "HH:MM", or nil.
-- Without a time, the date is anchored to local midnight.
function M.dueEpochMs(iso, time)
  if iso == nil or iso == "" then
    return nil
  end
  local y, mo, d = string.match(iso, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y == nil then
    return nil
  end
  local cleanTime = M.safeTime(time)
  local hour, minute = 0, 0
  if cleanTime ~= nil then
    hour = tonumber(string.match(cleanTime, "^(%d%d)"))
    minute = tonumber(string.match(cleanTime, ":(%d%d)$"))
  end
  local epoch = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = hour,
    min = minute,
  })
  if epoch == nil then
    return nil
  end
  return epoch * 1000
end

-- Monthly recurrence is capped: stepping is required for correct month-end
-- clamping, which is linear in the number of months skipped. A todo that has
-- not been touched in years would otherwise burn hundreds of iterations on
-- every snapshot build, so past this horizon the date is left alone and shown
-- as-is instead.
local MAX_MONTHLY_ROLL = 240

function M.rollRecurrence(due, rule, from)
  from = from or M.todayIso()
  if due == nil or due == "" or rule == nil then
    return due
  end
  if due >= from then
    return due
  end
  local step = rule == "weekly" and 7 or 1
  if rule ~= "daily" and rule ~= "weekly" and rule ~= "monthly" then
    return due
  end
  -- Jump straight to the first occurrence on or after `from` instead of
  -- walking day by day: a years-old @daily todo would otherwise cost hundreds
  -- of iterations on every snapshot build.
  local days = M.daysUntil(due)
  local target = M.daysUntil(from)
  if days == nil or target == nil or days > target then
    return due
  end
  local advance = target - days
  if rule == "monthly" then
    if advance > MAX_MONTHLY_ROLL * 31 then
      return due
    end
    -- Must step month by month: clamping is not associative, so no jump of
    -- whole months or years is safe. Skipping a February means a 31st is never
    -- clamped (2025-01-31 + 12 months is 2026-01-31, not 2026-02-28).
    local probe = due
    local guard = 0
    while probe < from and guard < MAX_MONTHLY_ROLL do
      local stepped = M.addMonths(probe, 1)
      if stepped == nil then
        return due
      end
      probe = stepped
      guard = guard + 1
    end
    return probe >= from and probe or due
  end
  local jumps = math.floor(advance / step)
  local candidate = M.addDays(due, jumps * step)
  while candidate < from do
    candidate = M.addDays(candidate, step)
  end
  return candidate
end

local WEEKDAYS = {
  sunday = 7, monday = 1, tuesday = 2, wednesday = 3, thursday = 4, friday = 5, saturday = 6,
}

local MONTHS = {
  january = 1, february = 2, march = 3, april = 4, may = 5, june = 6,
  july = 7, august = 8, september = 9, october = 10, november = 11, december = 12,
}

local function word(text, token)
  return string.find(text, "%f[%w]" .. token .. "%f[%W]") ~= nil
end

local function clockTime(text)
  local hh, mm = string.match(text, "(%d%d?):(%d%d)")
  if hh ~= nil then
    local h, m = tonumber(hh), tonumber(mm)
    if h <= 23 and m <= 59 then
      return string.format("%02d:%02d", h, m)
    end
    return nil
  end
  local h, meridiem = string.match(text, "(%d%d?)%s*am")
  if h ~= nil then
    meridiem = "am"
  else
    h, meridiem = string.match(text, "(%d%d?)%s*pm")
    if h ~= nil then
      meridiem = "pm"
    else
      meridiem, h = string.match(text, "(am|pm)%s*(%d%d?)")
    end
  end
  if h ~= nil then
    local hour = tonumber(h)
    if hour >= 1 and hour <= 12 then
      if meridiem == "pm" and hour < 12 then
        hour = hour + 12
      elseif meridiem == "am" and hour == 12 then
        hour = 0
      end
      return string.format("%02d:00", hour)
    end
  end
  return nil
end

-- Deterministic date/time extraction, used when AI structuring is off or
-- unavailable. Returns "YYYY-MM-DD" and "HH:MM", either of which may be nil.
function M.parseDueHint(text)
  local lower = string.lower(tostring(text or ""))
  local today = M.todayIso()
  local year = tonumber(os.date("%Y"))
  local date

  local y, mo, d = string.match(lower, "(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if d ~= nil then
    date = string.format("%04d-%02d-%02d", tonumber(y), tonumber(mo), tonumber(d))
  end

  if date == nil then
    d, mo = string.match(lower, "(%d%d?)[./](%d%d?)")
    if d ~= nil then
      local month, day = tonumber(mo), tonumber(d)
      if month >= 1 and month <= 12 and day >= 1 and day <= 31 then
        date = string.format("%04d-%02d-%02d", year, month, day)
      end
    end
  end

  if date == nil then
    for name, number in pairs(MONTHS) do
      local short = string.sub(name, 1, 3)
      local before = string.match(lower, "(%d%d?)%s+" .. short)
      local after = string.match(lower, short .. "%a*%s+(%d%d?)%f[%W]")
      local dayNum = tonumber(before or after or "")
      if dayNum ~= nil and dayNum >= 1 and dayNum <= 31 then
        date = string.format("%04d-%02d-%02d", year, number, dayNum)
        break
      end
    end
  end

  if date == nil then
    if word(lower, "today") then
      date = today
    elseif word(lower, "tomorrow") then
      date = M.addDays(today, 1)
    elseif word(lower, "yesterday") then
      date = M.addDays(today, -1)
    elseif word(lower, "week") and word(lower, "next") then
      date = M.addDays(today, 7)
    elseif word(lower, "month") and word(lower, "next") then
      date = M.addMonths(today, 1)
    else
      local n, unit = string.match(lower, "in%s+(%d+)%s*(%a+)")
      if n ~= nil then
        local count = tonumber(n)
        local first = string.sub(unit, 1, 1)
        if first == "d" then
          date = M.addDays(today, count)
        elseif first == "w" then
          date = M.addDays(today, count * 7)
        elseif first == "m" then
          date = M.addMonths(today, count)
        end
      end
    end
  end

  if date == nil then
    local todayWeekday = tonumber(os.date("%w", M.isoEpoch(today)))
    for name, weekday in pairs(WEEKDAYS) do
      local short = string.sub(name, 1, 3)
      if word(lower, short) or word(lower, name) then
        local delta = (weekday - todayWeekday) % 7
        if delta == 0 then
          delta = 7
        end
        if word(lower, "next") and not word(lower, "next" .. short) then
          delta = delta + 7
        end
        date = M.addDays(today, delta)
        break
      end
    end
  end

  return date, clockTime(lower)
end

function M.wikilinks(s)
  local out, seen = {}, {}
  for target in string.gmatch(tostring(s or ""), "%[%[([^%]]+)%]%]") do
    local clean = string.match(target, "^([^|#]+)") or target
    clean = M.trim(clean)
    if clean ~= "" and not seen[clean] then
      seen[clean] = true
      out[#out + 1] = clean
    end
  end
  return out
end

return M